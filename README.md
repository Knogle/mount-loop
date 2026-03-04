# mount-loop.py

**mount-loop.py** is a Python-based command line tool for creating and attaching loop devices on Linux. The CLI is centered around two commands:

- `attach`: attach an existing image file
- `create`: create one or more image files and attach them

Behavior such as filesystem creation, `tmpfs` backing, random sizes, custom base directories, and faulty block simulation is expressed through flags instead of separate command families. The tool is aimed at testing block-device operations, filesystem handling, mount flows, and error cases without needing physical hardware. Cleanup is centralized, so `Ctrl+C`, command failures, and partial setup failures all tear down loop devices, mountpoints, mapper devices, and temporary files through one consistent cleanup path.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
  - [Command Synopsis](#command-synopsis)
  - [Commands](#commands)
  - [Key Options](#key-options)
  - [Legacy Aliases](#legacy-aliases)
  - [Examples](#examples)
- [Use-Case Scenarios](#use-case-scenarios)
  - [Testing Disk Utilities](#testing-disk-utilities)
  - [Simulating Faulty Storage Devices](#simulating-faulty-storage-devices)
  - [Performance Benchmarking](#performance-benchmarking)
  - [Filesystem Experimentation](#filesystem-experimentation)
- [How It Works](#how-it-works)
- [Cleanup and Safety](#cleanup-and-safety)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Simple CLI Surface**: Use `attach` for existing files and `create` for everything new.
- **File Creation**: Generate files of specific or random sizes to act as virtual block devices.
- **Filesystem Support**: Optionally create and mount `ext4` filesystems with `--fs`.
- **Multiple Devices**: Create multiple loop devices with `--count`.
- **tmpfs Backing**: Use `--backend tmpfs` for memory-backed images.
- **Faulty Block Simulation**: Use `--faulty-blocks` to create a device-mapper target with injected I/O errors.
- **Consistent Output**: Setup and cleanup use the same structured CLI event style.
- **Automatic Cleanup**: Temporary files, mapper devices, loop devices, and mounts are cleaned up in reverse order.

## Requirements

- **Operating System**: Linux
- **Runtime**: `python3`
- **Permissions**: Root privileges (run as `root` or use `sudo`/`pkexec`)
- **Utilities**:
  - `losetup`
  - `mkfs.ext4`
  - `mount`
  - `umount`
  - `dmsetup`
  - `blockdev`

## Installation

1. **Clone the Repository**:

   ```bash
   git clone https://github.com/yourusername/mount-loop.git
   ```

2. **Navigate to the Directory**:

   ```bash
   cd mount-loop
   ```

3. **Make the Scripts Executable**:

   ```bash
   chmod +x mount-loop.py
   ```

## Usage

### Command Synopsis

```bash
./mount-loop.py <command> [options]
```

Attach an existing image file or create new loop-backed images with optional filesystems, `tmpfs` backing, and faulty block simulation.

### Commands

- `attach <FilePath>`: Attach an existing file as a loop device.
- `create`: Create one or more backing files and attach them as loop devices.
- `cleanup [File]`: Clean up resources listed in `KEPT ...` lines from a previous `--keep` run.

### Key Options

- `--size <Size>`: Fixed size for each image, for example `1G` or `512M`.
- `--min-size <Size> --max-size <Size>`: Random size range.
- `--count <N>`: Number of loop devices to create.
- `--backend file|tmpfs`: Select file-backed or `tmpfs`-backed images.
- `--base-dir <Dir>`: Base directory for file-backed images.
- `--fs`: Create and mount an `ext4` filesystem.
- `--faulty-blocks <Spec>`: Inject faulty blocks, for example `500,1000-1010`.
- `--script`: Non-interactive mode for scripts, with no prompt and success/failure via exit code.
- `--keep`: Skip cleanup on success, keep the created resources, and print a summary of what remains.

### Legacy Aliases

The old commands are still accepted as compatibility aliases:

- `automount`, `automountfs`
- `faultymount`, `faultymountfs`
- `polymount`, `polymountfs`
- `custompolymount`, `custompolymountfs`
- `custommount`, `custommountfs`
- `tmpfsmount`, `tmpfsmountfs`
- `tmpfspolymount`, `tmpfspolymountfs`

### Examples

#### Existing Image

- **Attach an existing file as a loop device**:

  ```bash
  sudo ./mount-loop.py attach /path/to/your/file.img
  ```

#### Create One Image

- **Create a 1G file and attach it**:

  ```bash
  sudo ./mount-loop.py create --size 1G
  ```

- **Create a 1G file, format it, and mount it**:

  ```bash
  sudo ./mount-loop.py create --size 1G --fs
  ```

- **Run in script mode and rely only on the exit code**:

  ```bash
  sudo ./mount-loop.py --script create --size 1G --fs
  echo $?
  ```

- **Keep the created resources instead of cleaning them up immediately**:
  This prints `KEPT ...` lines that can later be fed into `cleanup`.

  ```bash
  sudo ./mount-loop.py --keep create --size 1G --fs
  ```

- **Write kept resources to a file and clean them up later**:

  ```bash
  sudo ./mount-loop.py --keep create --size 1G --fs > kept.txt
  sudo ./mount-loop.py cleanup kept.txt
  ```

- **Clean up directly from stdin**:

  ```bash
  sudo ./mount-loop.py cleanup < kept.txt
  ```

#### Faulty Blocks

- **Create a 1G loop device with blocks 500 and 1000 marked as faulty**:

  ```bash
  sudo ./mount-loop.py create --size 1G --faulty-blocks 500,1000
  ```

- **Create a 1G loop device, format it, mount it, and mark blocks 500 to 510 as faulty**:

  ```bash
  sudo ./mount-loop.py create --size 1G --faulty-blocks 500-510 --fs
  ```

- **Using a combination of single blocks and ranges**:

  ```bash
  sudo ./mount-loop.py create --size 1G --faulty-blocks 500,1000-1010,1500
  ```

#### Multiple Loop Devices

- **Create 5 files of 1G each and set them up as loop devices**:

  ```bash
  sudo ./mount-loop.py create --count 5 --size 1G
  ```

- **Same as above but also create filesystems and mount them**:

  ```bash
  sudo ./mount-loop.py create --count 5 --size 1G --fs
  ```

#### Random Sized Loop Devices

- **Create 5 files with random sizes between 500M and 2G**:

  ```bash
  sudo ./mount-loop.py create --count 5 --min-size 500M --max-size 2G
  ```

- **Same as above but also create filesystems and mount them**:

  ```bash
  sudo ./mount-loop.py create --count 5 --min-size 500M --max-size 2G --fs
  ```

#### Custom Base Directory

- **Create 3 file-backed images under `/workspace`**:

  ```bash
  sudo ./mount-loop.py create --base-dir /workspace --count 3 --size 1G
  ```

#### tmpfs-Backed Images

- **Create a 1G tmpfs-backed image and attach it**:

  ```bash
  sudo ./mount-loop.py create --backend tmpfs --size 1G
  ```

- **Create a 1G tmpfs-backed image, format it, and mount it**:

  ```bash
  sudo ./mount-loop.py create --backend tmpfs --size 1G --fs
  ```

## Use-Case Scenarios

### Testing Disk Utilities

Developers working on disk utilities or applications that interact with block devices can use `mount-loop.py` to simulate disk environments without the need for physical disks.

- **Scenario**: Testing a new disk cloning tool.
- **Solution**: Create multiple loop devices with filesystems to act as source and target disks.

  ```bash
  sudo ./mount-loop.py create --size 5G --fs
  sudo ./mount-loop.py create --size 5G --fs
  ```

### Simulating Faulty Storage Devices

Test how applications handle read/write errors due to bad sectors or faulty blocks.

- **Scenario**: Testing the robustness of backup software when encountering disk errors.
- **Solution**: Create a loop device with faulty blocks to simulate a failing disk.

  ```bash
  sudo ./mount-loop.py create --size 1G --faulty-blocks 500-510 --fs
  ```

- **Testing read error handling**:

  ```bash
  sudo dd if=/dev/mapper/faulty-loop-loop0 of=/dev/null bs=512 skip=500 count=1
  ```

  This should produce an input/output error.

### Performance Benchmarking

Test the performance of filesystems or applications under different storage conditions.

- **Scenario**: Benchmarking application performance on different storage media.
- **Solution**: Use ramdisks and regular loop devices to compare performance.

  ```bash
  # Ramdisk
  sudo ./mount-loop.py create --backend tmpfs --size 1G --fs

  # Regular loop device
  sudo ./mount-loop.py create --size 1G --fs
  ```

### Filesystem Experimentation

Experiment with different filesystem types and configurations.

- **Scenario**: Testing the features of a new filesystem.
- **Solution**: Modify the script to format loop devices with the desired filesystem.

  ```bash
  # Modify mkfs command in the script to use mkfs.xfs or another filesystem.
  sudo ./mount-loop.py create --size 1G --fs
  ```

## How It Works

The tool automates the following processes:

1. **Argument Parsing**: Normalizes both the new subcommand-based CLI and the legacy aliases.
2. **Backing Store Creation**: Creates sparse image files on disk or in a shared `tmpfs`.
3. **Loop Device Setup**: Uses `losetup` to attach each image file to a loop device.
4. **Faulty Block Simulation** (Optional): Uses the Device Mapper with the `error` target to simulate faulty blocks.
5. **Filesystem Creation** (Optional): Formats the device with `mkfs.ext4`.
6. **Mounting** (Optional): Mounts the filesystem to a temporary directory.
7. **Central Cleanup**: A cleanup stack removes resources in reverse order on success, failure, or signal interruption.

## Cleanup and Safety

- **Automatic Cleanup**: The tool tracks temporary files, loop devices, mount points, `tmpfs` mounts, and device-mapper devices centrally and tears them down in reverse order.
- **Consistent Events**: Setup and teardown use the same structured CLI event format, which makes it easier to understand what was created and what was removed.
- **Script Mode**: `--script` suppresses prompts and event output so shell scripts can rely on a simple success/failure exit code.
- **Keep Mode**: `--keep` preserves successfully created resources and prints a concise summary of the remaining files, devices, mounts, and tmpfs paths.
- **Cleanup Command**: `cleanup` consumes the `KEPT ...` summary and tears resources down in dependency order.
- **User Prompt**: Before teardown, the tool waits for confirmation so the created devices can be inspected.
- **Signal Handling**: `Ctrl+C` and `SIGTERM` trigger the same cleanup path as normal exit, which avoids leaving loop devices or mounts behind in common interruption cases.
- **Error Handling**: Invalid arguments and command failures surface as explicit CLI errors instead of partial silent cleanup.
- **Faulty Devices**: When creating devices with faulty blocks, the script uses the Device Mapper to safely simulate errors without affecting the underlying storage.

## Contributing

Contributions are welcome! If you have suggestions, enhancements, or bug fixes, please open an issue or submit a pull request on the GitHub repository.

1. **Fork the Repository**
2. **Create a Feature Branch**

   ```bash
   git checkout -b feature/YourFeature
   ```

3. **Commit Your Changes**

   ```bash
   git commit -m "Add YourFeature"
   ```

4. **Push to Your Branch**

   ```bash
   git push origin feature/YourFeature
   ```

5. **Open a Pull Request**

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

---

**Disclaimer**: Use this script at your own risk. Ensure you have backups and understand the operations being performed, especially when running as root.
