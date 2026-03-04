#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import random
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
from typing import Callable


if (orig_pwd := os.environ.get("NW_ORIG_PWD")) and Path(orig_pwd).is_dir():
    os.chdir(orig_pwd)

PROG_NAME = Path(os.environ.get("NW_PROG_NAME") or sys.argv[0]).name
DEFAULT_BASE_DIR = Path("/tmp")
SCRIPT_MODE = False
KEEP_MODE = False
OUTPUT_ENABLED = True
SIZE_UNITS = {
    "": 1,
    "B": 1,
    "K": 1024,
    "KB": 1024,
    "M": 1024 * 1024,
    "MB": 1024 * 1024,
    "G": 1024 * 1024 * 1024,
    "GB": 1024 * 1024 * 1024,
}


class MountLoopError(Exception):
    pass


class UserError(MountLoopError):
    pass


class CommandError(MountLoopError):
    pass


class MountLoopArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise UserError(message)


def format_fields(fields: dict[str, object]) -> str:
    parts = []
    for key, value in fields.items():
        if value is None:
            continue
        parts.append(f"{key}={shlex.quote(str(value))}")
    return " ".join(parts)


def log_event(prefix: str, action: str, **fields: object) -> None:
    if not OUTPUT_ENABLED:
        return
    payload = format_fields(fields)
    message = f"[{prefix}] {action}"
    if payload:
        message = f"{message} {payload}"
    stream = sys.stderr if prefix in {"!", "x"} else sys.stdout
    print(message, file=stream)


def log_info(action: str, **fields: object) -> None:
    log_event("+", action, **fields)


def log_warn(action: str, **fields: object) -> None:
    log_event("!", action, **fields)


def log_err(action: str, **fields: object) -> None:
    log_event("x", action, **fields)


def quoted(cmd: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in cmd)


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def run_checked(cmd: list[str], *, input_text: str | None = None) -> str:
    try:
        result = subprocess.run(
            cmd,
            input=input_text,
            text=True,
            capture_output=True,
            check=False,
        )
    except FileNotFoundError as exc:
        raise UserError(f"Missing required command: {cmd[0]}") from exc

    if result.returncode != 0:
        details = (result.stderr or result.stdout).strip()
        suffix = f": {details}" if details else f" (exit code {result.returncode})"
        raise CommandError(f"{quoted(cmd)}{suffix}")

    return result.stdout.strip()


def run_cleanup(cmd: list[str], *, action: str, **fields: object) -> None:
    try:
        result = subprocess.run(cmd, text=True, capture_output=True, check=False)
    except FileNotFoundError:
        log_warn("cleanup-skipped", reason="missing-command", command=cmd[0], action=action)
        return

    if result.returncode != 0:
        details = (result.stderr or result.stdout).strip() or f"exit={result.returncode}"
        log_warn("cleanup-failed", action=action, command=quoted(cmd), detail=details, **fields)
        return

    log_info(action, **fields)


def require_cmds(*cmds: str) -> None:
    missing = [cmd for cmd in cmds if not command_exists(cmd)]
    if missing:
        raise UserError(f"Missing required command(s): {', '.join(missing)}")


def ensure_root(argv: list[str]) -> None:
    if os.geteuid() == 0:
        return

    script_path = Path(__file__).resolve()
    env = os.environ.copy()
    env["NW_ORIG_PWD"] = os.getcwd()
    env["NW_PROG_NAME"] = PROG_NAME

    if command_exists("pkexec"):
        os.execvpe(
            "pkexec",
            [
                "pkexec",
                "/usr/bin/env",
                f"NW_ORIG_PWD={os.getcwd()}",
                f"NW_PROG_NAME={PROG_NAME}",
                sys.executable,
                str(script_path),
                *argv,
            ],
            env,
        )

    if command_exists("sudo"):
        os.execvpe(
            "sudo",
            [
                "sudo",
                "/usr/bin/env",
                f"NW_ORIG_PWD={os.getcwd()}",
                f"NW_PROG_NAME={PROG_NAME}",
                sys.executable,
                str(script_path),
                *argv,
            ],
            env,
        )

    raise UserError(
        "This script requires elevated privileges, but neither pkexec nor sudo is available."
    )


def convert_size_to_bytes(size_spec: str) -> int:
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([A-Za-z]{0,2})\s*", size_spec)
    if not match:
        raise UserError(f"Invalid size value: {size_spec}")

    number = Decimal(match.group(1))
    unit = match.group(2).upper()
    if unit not in SIZE_UNITS:
        raise UserError(f"Unknown size unit: {unit}")
    if number <= 0:
        raise UserError(f"Size must be greater than zero: {size_spec}")

    value = (number * SIZE_UNITS[unit]).to_integral_value(rounding=ROUND_HALF_UP)
    return int(value)


def parse_positive_int(raw_value: str, label: str) -> int:
    try:
        value = int(raw_value)
    except ValueError as exc:
        raise UserError(f"{label} must be an integer: {raw_value}") from exc

    if value <= 0:
        raise UserError(f"{label} must be greater than zero: {raw_value}")
    return value


def generate_random_size(min_size_bytes: int, max_size_bytes: int) -> int:
    if min_size_bytes > max_size_bytes:
        raise UserError("Invalid size range.")
    return random.randint(min_size_bytes, max_size_bytes)


def create_sparse_file(path: Path, size_bytes: int) -> None:
    with path.open("wb") as handle:
        handle.truncate(size_bytes)


def wait_for_cleanup() -> None:
    if SCRIPT_MODE:
        return
    try:
        input("Press [Enter] to clean up created resources.")
    except EOFError:
        pass


def remove_file(path: Path) -> None:
    if not path.exists():
        return
    path.unlink()
    log_info("removed", resource="backing-file", path=path)


def remove_dir(path: Path) -> None:
    if not path.exists():
        return
    path.rmdir()
    log_info("removed", resource="directory", path=path)


class CleanupStack:
    def __init__(self) -> None:
        self._callbacks: list[tuple[str, Callable[..., None], tuple[object, ...]]] = []

    def push(self, label: str, callback: Callable[..., None], *args: object) -> None:
        self._callbacks.append((label, callback, args))

    def cleanup(self) -> None:
        while self._callbacks:
            label, callback, args = self._callbacks.pop()
            try:
                callback(*args)
            except Exception as exc:  # noqa: BLE001
                log_warn("cleanup-failed", label=label, detail=exc)


class ResourceManager:
    def __init__(self) -> None:
        self.cleanup_stack = CleanupStack()
        self.backing_files: list[tuple[Path, int]] = []
        self.loop_devices: list[tuple[str, Path]] = []
        self.dm_devices: list[tuple[str, str, str]] = []
        self.mounts: list[tuple[str, Path]] = []
        self.tmpfs_mounts: list[tuple[Path, int]] = []

    def create_temp_dir(self, prefix: str) -> Path:
        path = Path(tempfile.mkdtemp(prefix=prefix))
        log_info("created", resource="directory", path=path)
        self.cleanup_stack.push(f"remove directory {path}", remove_dir, path)
        return path

    def create_backing_file(self, path: Path, size_bytes: int) -> Path:
        create_sparse_file(path, size_bytes)
        self.backing_files.append((path, size_bytes))
        log_info("created", resource="backing-file", path=path, size=size_bytes)
        self.cleanup_stack.push(f"delete backing file {path}", remove_file, path)
        return path

    def create_tmp_image(self, size_bytes: int, base_dir: Path) -> Path:
        filename = f"{uuid.uuid4()}.img"
        return self.create_backing_file(base_dir / filename, size_bytes)

    def attach_loop(self, file_path: Path) -> str:
        loop_device = run_checked(["losetup", "-fP", "--show", str(file_path)])
        self.loop_devices.append((loop_device, file_path))
        log_info("attached", resource="loop-device", device=loop_device, file=file_path)
        self.cleanup_stack.push(
            f"detach loop device {loop_device}",
            self._detach_loop,
            loop_device,
        )
        return loop_device

    def create_filesystem(self, device: str) -> None:
        run_checked(["mkfs.ext4", "-q", device])
        log_info("formatted", resource="filesystem", type="ext4", device=device)

    def mount_device(self, device: str) -> Path:
        mountpoint = self.create_temp_dir("mount-loop-mnt-")
        run_checked(["mount", device, str(mountpoint)])
        self.mounts.append((device, mountpoint))
        log_info("mounted", resource="filesystem", device=device, path=mountpoint)
        self.cleanup_stack.push(
            f"unmount {mountpoint}",
            self._umount,
            mountpoint,
        )
        return mountpoint

    def mount_tmpfs(self, size_bytes: int) -> Path:
        mountpoint = self.create_temp_dir("mount-loop-tmpfs-")
        run_checked(["mount", "-t", "tmpfs", "-o", f"size={size_bytes}", "tmpfs", str(mountpoint)])
        self.tmpfs_mounts.append((mountpoint, size_bytes))
        log_info("mounted", resource="tmpfs", path=mountpoint, size=size_bytes)
        self.cleanup_stack.push(
            f"unmount tmpfs {mountpoint}",
            self._umount,
            mountpoint,
        )
        return mountpoint

    def create_faulty_mapping(self, loop_device: str, faulty_blocks: str) -> str:
        total_size = int(run_checked(["blockdev", "--getsize64", loop_device]))
        total_blocks = total_size // 512
        ranges = parse_faulty_blocks(faulty_blocks, total_blocks)
        table = create_dm_table(loop_device, total_blocks, ranges)
        dm_name = f"faulty-loop-{Path(loop_device).name}-{uuid.uuid4().hex[:8]}"
        run_checked(["dmsetup", "create", dm_name], input_text=table)
        mapped_device = f"/dev/mapper/{dm_name}"
        self.dm_devices.append((mapped_device, loop_device, faulty_blocks))
        log_info(
            "attached",
            resource="dm-device",
            device=mapped_device,
            backing=loop_device,
            faulty_blocks=faulty_blocks,
        )
        self.cleanup_stack.push(
            f"remove dm device {dm_name}",
            self._remove_dm,
            dm_name,
            mapped_device,
        )
        return mapped_device

    @staticmethod
    def _detach_loop(loop_device: str) -> None:
        run_cleanup(["losetup", "-d", loop_device], action="detached", resource="loop-device", device=loop_device)

    @staticmethod
    def _umount(path: Path) -> None:
        run_cleanup(["umount", str(path)], action="unmounted", resource="mount", path=path)

    @staticmethod
    def _remove_dm(dm_name: str, mapped_device: str) -> None:
        run_cleanup(["dmsetup", "remove", dm_name], action="detached", resource="dm-device", device=mapped_device)


def emit_keep_summary(resources: ResourceManager) -> None:
    for path, size in resources.backing_files:
        print(f"KEPT {format_fields({'resource': 'backing-file', 'path': path, 'size': size})}")
    for device, file_path in resources.loop_devices:
        print(f"KEPT {format_fields({'resource': 'loop-device', 'device': device, 'file': file_path})}")
    for device, backing, faulty_blocks in resources.dm_devices:
        print(
            f"KEPT {format_fields({'resource': 'dm-device', 'device': device, 'backing': backing, 'faulty_blocks': faulty_blocks})}"
        )
    for device, path in resources.mounts:
        print(f"KEPT {format_fields({'resource': 'mount', 'device': device, 'path': path})}")
    for path, size in resources.tmpfs_mounts:
        print(f"KEPT {format_fields({'resource': 'tmpfs', 'path': path, 'size': size})}")


def parse_kept_lines(text: str) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    for lineno, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith("KEPT "):
            raise UserError(f"Invalid cleanup input at line {lineno}: expected 'KEPT ...'")

        fields: dict[str, str] = {}
        for token in shlex.split(line[5:]):
            if "=" not in token:
                raise UserError(f"Invalid cleanup input at line {lineno}: malformed token '{token}'")
            key, value = token.split("=", 1)
            fields[key] = value

        resource = fields.get("resource")
        if not resource:
            raise UserError(f"Invalid cleanup input at line {lineno}: missing resource")
        records.append(fields)

    if not records:
        raise UserError("No KEPT resources found in cleanup input.")
    return records


def load_cleanup_records(input_path: str | None) -> list[dict[str, str]]:
    if input_path:
        text = Path(input_path).read_text(encoding="utf-8")
        return parse_kept_lines(text)

    if sys.stdin.isatty():
        raise UserError("cleanup requires a summary file argument or KEPT lines on stdin.")

    return parse_kept_lines(sys.stdin.read())


def parse_faulty_blocks(raw_value: str, total_blocks: int) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    if not raw_value.strip():
        raise UserError("Faulty block list must not be empty.")

    for block_spec in raw_value.split(","):
        token = block_spec.strip()
        if not re.fullmatch(r"\d+(?:-\d+)?", token):
            raise UserError(f"Invalid block specification: {token}")

        if "-" in token:
            start_text, end_text = token.split("-", 1)
            start = int(start_text)
            end = int(end_text)
        else:
            start = end = int(token)

        if start > end:
            raise UserError(f"Invalid block range: {token}")
        if end >= total_blocks:
            raise UserError(f"Invalid block range: {token}")

        ranges.append((start, end))

    ranges.sort()
    for previous, current in zip(ranges, ranges[1:]):
        if current[0] <= previous[1]:
            raise UserError(
                "Overlapping or duplicate faulty block ranges: "
                f"{previous[0]}-{previous[1]} and {current[0]}-{current[1]}"
            )

    return ranges


def create_dm_table(loop_device: str, total_blocks: int, ranges: list[tuple[int, int]]) -> str:
    lines: list[str] = []
    current_block = 0

    for start, end in ranges:
        if current_block < start:
            length = start - current_block
            lines.append(f"{current_block} {length} linear {loop_device} {current_block}")
            current_block = start

        length = end - start + 1
        lines.append(f"{current_block} {length} error")
        current_block = end + 1

    if current_block < total_blocks:
        length = total_blocks - current_block
        lines.append(f"{current_block} {length} linear {loop_device} {current_block}")

    return "\n".join(lines) + "\n"


def normalize_legacy_argv(argv: list[str]) -> list[str]:
    if not argv:
        return argv

    global_args: list[str] = []
    rest = list(argv)
    while rest and rest[0] in {"--script", "--keep", "--help", "-h"}:
        global_args.append(rest.pop(0))

    if not rest:
        return global_args

    if rest[0] in {"attach", "create"}:
        return global_args + rest

    cmd = rest[0]

    if cmd == "automount" and len(rest) == 2:
        return global_args + ["create", "--size", rest[1]]
    if cmd == "automountfs" and len(rest) == 2:
        return global_args + ["create", "--size", rest[1], "--fs"]
    if cmd == "faultymount" and len(rest) == 3:
        return global_args + ["create", "--size", rest[1], "--faulty-blocks", rest[2]]
    if cmd == "faultymountfs" and len(rest) == 3:
        return global_args + ["create", "--size", rest[1], "--faulty-blocks", rest[2], "--fs"]

    if cmd in {"polymount", "polymountfs"}:
        extra = ["--fs"] if cmd.endswith("fs") else []
        if len(rest) == 5 and rest[1] == "rand":
            return global_args + [
                "create",
                "--count",
                rest[2],
                "--min-size",
                rest[3],
                "--max-size",
                rest[4],
                *extra,
            ]
        if len(rest) == 3:
            return global_args + ["create", "--count", rest[1], "--size", rest[2], *extra]

    if cmd in {"custompolymount", "custompolymountfs", "custommount", "custommountfs"}:
        extra = ["--fs"] if cmd.endswith("fs") else []
        if len(rest) == 6 and rest[1] == "rand":
            return global_args + [
                "create",
                "--base-dir",
                rest[2],
                "--count",
                rest[3],
                "--min-size",
                rest[4],
                "--max-size",
                rest[5],
                *extra,
            ]
        if len(rest) == 4:
            return global_args + ["create", "--base-dir", rest[1], "--count", rest[2], "--size", rest[3], *extra]

    if cmd in {"tmpfsmount", "tmpfsmountfs"} and len(rest) == 2:
        extra = ["--fs"] if cmd.endswith("fs") else []
        return global_args + ["create", "--backend", "tmpfs", "--size", rest[1], *extra]

    if cmd in {"tmpfspolymount", "tmpfspolymountfs"}:
        extra = ["--fs"] if cmd.endswith("fs") else []
        if len(rest) == 5 and rest[1] == "rand":
            return global_args + [
                "create",
                "--backend",
                "tmpfs",
                "--count",
                rest[2],
                "--min-size",
                rest[3],
                "--max-size",
                rest[4],
                *extra,
            ]
        if len(rest) == 3:
            return global_args + ["create", "--backend", "tmpfs", "--count", rest[1], "--size", rest[2], *extra]

    if len(rest) == 1:
        return global_args + ["attach", rest[0]]

    return global_args + rest


def build_parser() -> MountLoopArgumentParser:
    parser = MountLoopArgumentParser(
        prog=PROG_NAME,
        description=(
            "Create, attach and cleanly tear down loop devices for testing block-device "
            "operations, filesystem workflows, tmpfs-backed images and injected I/O errors."
        ),
        epilog=(
            "Examples:\n"
            f"  {PROG_NAME} attach ./disk.img\n"
            f"  {PROG_NAME} create --size 1G\n"
            f"  {PROG_NAME} create --size 1G --fs\n"
            f"  {PROG_NAME} create --script --size 1G --fs\n"
            f"  {PROG_NAME} --keep create --size 1G --fs\n"
            f"  {PROG_NAME} cleanup kept.txt\n"
            f"  {PROG_NAME} cleanup < kept.txt\n"
            f"  {PROG_NAME} create --count 5 --size 1G\n"
            f"  {PROG_NAME} create --count 5 --min-size 500M --max-size 2G\n"
            f"  {PROG_NAME} create --backend tmpfs --size 1G --fs\n"
            f"  {PROG_NAME} create --base-dir /workspace --count 3 --size 512M\n"
            f"  {PROG_NAME} create --size 1G --faulty-blocks 500-510\n\n"
            "Legacy commands such as automount, polymount and tmpfsmount are still accepted as aliases."
        ),
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument(
        "--script",
        action="store_true",
        help="non-interactive mode for scripts: no prompt, no event output, success via exit code",
    )
    parser.add_argument(
        "--keep",
        action="store_true",
        help="do not clean up on success; keep created devices and print a summary",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    attach_parser = subparsers.add_parser(
        "attach",
        help="attach an existing image file as a loop device",
    )
    attach_parser.add_argument("file", help="path to an existing image file")

    create_parser = subparsers.add_parser(
        "create",
        help="create one or more images and attach them as loop devices",
    )
    create_parser.add_argument("--size", help="fixed size for each image, e.g. 1G or 512M")
    create_parser.add_argument("--min-size", help="minimum size in random mode")
    create_parser.add_argument("--max-size", help="maximum size in random mode")
    create_parser.add_argument(
        "--count",
        default="1",
        help="number of loop devices to create (default: 1)",
    )
    create_parser.add_argument(
        "--backend",
        choices=("file", "tmpfs"),
        default="file",
        help="where backing images live (default: file)",
    )
    create_parser.add_argument(
        "--base-dir",
        default=str(DEFAULT_BASE_DIR),
        help="directory for file-backed images (default: /tmp)",
    )
    create_parser.add_argument("--fs", action="store_true", help="create and mount an ext4 filesystem")
    create_parser.add_argument(
        "--faulty-blocks",
        help="faulty block list like 500,1000-1010; only valid when --count=1",
    )

    cleanup_parser = subparsers.add_parser(
        "cleanup",
        help="clean up resources listed in KEPT summary lines from --keep",
    )
    cleanup_parser.add_argument(
        "input",
        nargs="?",
        help="file containing KEPT lines; if omitted, read from stdin",
    )

    return parser


def validate_create_args(args: argparse.Namespace) -> None:
    args.count = parse_positive_int(args.count, "count")

    fixed_size = args.size is not None
    random_size = args.min_size is not None or args.max_size is not None

    if fixed_size and random_size:
        raise UserError("Use either --size or --min-size/--max-size, not both.")

    if not fixed_size and not random_size:
        raise UserError("create requires either --size or both --min-size and --max-size.")

    if random_size and (args.min_size is None or args.max_size is None):
        raise UserError("Random size mode requires both --min-size and --max-size.")

    if fixed_size:
        convert_size_to_bytes(args.size)
    else:
        convert_size_to_bytes(args.min_size)
        convert_size_to_bytes(args.max_size)

    if args.backend == "tmpfs" and args.base_dir != str(DEFAULT_BASE_DIR):
        raise UserError("--base-dir cannot be used with --backend tmpfs.")

    if args.faulty_blocks and args.count != 1:
        raise UserError("--faulty-blocks is only supported when --count=1.")

    if args.backend == "file":
        base_dir = Path(args.base_dir).resolve()
        if not base_dir.is_dir():
            raise UserError(f"Base directory does not exist or is not a directory: {base_dir}")


def required_commands_for(args: argparse.Namespace) -> tuple[str, ...]:
    if args.command == "attach":
        return ("losetup",)

    if args.command == "cleanup":
        commands: set[str] = set()
        for record in args.cleanup_records:
            resource = record["resource"]
            if resource == "mount":
                commands.add("umount")
            elif resource == "tmpfs":
                commands.add("umount")
            elif resource == "dm-device":
                commands.add("dmsetup")
            elif resource == "loop-device":
                commands.add("losetup")
        return tuple(sorted(commands))

    commands = {"losetup"}
    if args.backend == "tmpfs":
        commands.update({"mount", "umount"})
    if args.fs:
        commands.update({"mkfs.ext4", "mount", "umount"})
    if args.faulty_blocks:
        commands.update({"dmsetup", "blockdev"})
    return tuple(sorted(commands))


def resolve_sizes(args: argparse.Namespace) -> list[int]:
    if args.size is not None:
        size_bytes = convert_size_to_bytes(args.size)
        return [size_bytes] * args.count

    min_size_bytes = convert_size_to_bytes(args.min_size)
    max_size_bytes = convert_size_to_bytes(args.max_size)
    return [generate_random_size(min_size_bytes, max_size_bytes) for _ in range(args.count)]


def run_attach(file_path: Path) -> None:
    if not file_path.exists():
        raise UserError(f"File does not exist: {file_path}")

    resources = ResourceManager()
    success = False
    try:
        resources.attach_loop(file_path.resolve())
        log_info("ready", command="attach", file=file_path.resolve())
        success = True
        if not KEEP_MODE:
            wait_for_cleanup()
    finally:
        if success and KEEP_MODE:
            emit_keep_summary(resources)
        else:
            resources.cleanup_stack.cleanup()


def run_create(args: argparse.Namespace) -> None:
    sizes = resolve_sizes(args)
    resources = ResourceManager()
    success = False

    try:
        if args.backend == "tmpfs":
            working_dir = resources.mount_tmpfs(sum(sizes))
        else:
            working_dir = Path(args.base_dir).resolve()

        for size_bytes in sizes:
            file_path = resources.create_tmp_image(size_bytes, working_dir)
            loop_device = resources.attach_loop(file_path)
            device_for_fs = loop_device

            if args.faulty_blocks:
                device_for_fs = resources.create_faulty_mapping(loop_device, args.faulty_blocks)

            if args.fs:
                resources.create_filesystem(device_for_fs)
                resources.mount_device(device_for_fs)

        log_info(
            "ready",
            command="create",
            count=len(sizes),
            backend=args.backend,
            filesystem="ext4" if args.fs else "none",
            faulty_blocks=args.faulty_blocks or "none",
        )
        success = True
        if not KEEP_MODE:
            wait_for_cleanup()
    finally:
        if success and KEEP_MODE:
            emit_keep_summary(resources)
        else:
            resources.cleanup_stack.cleanup()


def run_cleanup_records(records: list[dict[str, str]]) -> None:
    mounts = [record for record in records if record["resource"] == "mount"]
    dm_devices = [record for record in records if record["resource"] == "dm-device"]
    loop_devices = [record for record in records if record["resource"] == "loop-device"]
    backing_files = [record for record in records if record["resource"] == "backing-file"]
    tmpfs_mounts = [record for record in records if record["resource"] == "tmpfs"]

    for record in reversed(mounts):
        path = Path(record["path"])
        run_cleanup(["umount", str(path)], action="unmounted", resource="mount", path=path)
        remove_dir(path)

    for record in reversed(dm_devices):
        device = record["device"]
        dm_name = Path(device).name
        run_cleanup(["dmsetup", "remove", dm_name], action="detached", resource="dm-device", device=device)

    for record in reversed(loop_devices):
        device = record["device"]
        run_cleanup(["losetup", "-d", device], action="detached", resource="loop-device", device=device)

    for record in reversed(backing_files):
        remove_file(Path(record["path"]))

    for record in reversed(tmpfs_mounts):
        path = Path(record["path"])
        run_cleanup(["umount", str(path)], action="unmounted", resource="tmpfs", path=path)
        remove_dir(path)

    log_info("ready", command="cleanup", resources=len(records))


def install_signal_handlers() -> None:
    def handle_signal(signum: int, _frame: object) -> None:
        signal_name = signal.Signals(signum).name
        raise KeyboardInterrupt(f"received {signal_name}")

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)


def main(argv: list[str]) -> int:
    global OUTPUT_ENABLED
    global KEEP_MODE
    global SCRIPT_MODE

    install_signal_handlers()
    parser = build_parser()
    normalized_argv = normalize_legacy_argv(argv)
    if not normalized_argv or set(normalized_argv).issubset({"--script", "--keep", "--help", "-h"}):
        parser.print_help()
        return 0

    args = parser.parse_args(normalized_argv)
    SCRIPT_MODE = bool(args.script)
    KEEP_MODE = bool(args.keep)
    OUTPUT_ENABLED = not SCRIPT_MODE

    if args.command == "attach":
        file_path = Path(args.file)
        if not file_path.exists():
            raise UserError(f"File does not exist: {file_path}")
    elif args.command == "create":
        validate_create_args(args)
    elif args.command == "cleanup":
        if args.keep:
            raise UserError("--keep is not supported with cleanup.")
        args.cleanup_records = load_cleanup_records(args.input)

    ensure_root(argv)
    require_cmds(*required_commands_for(args))

    if args.command == "attach":
        run_attach(Path(args.file))
        return 0

    if args.command == "create":
        run_create(args)
        return 0

    if args.command == "cleanup":
        run_cleanup_records(args.cleanup_records)
        return 0

    raise UserError(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt as exc:
        log_warn("interrupted", detail=str(exc) or "signal received")
        raise SystemExit(1 if SCRIPT_MODE else 130)
    except UserError as exc:
        log_err("usage", detail=exc)
        raise SystemExit(1)
    except CommandError as exc:
        log_err("command-failed", detail=exc)
        raise SystemExit(1)
