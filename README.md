# mount-loop.sh

**mount-loop.sh** is a versatile shell script designed to simplify the creation and management of loop devices, filesystems, and ramdisks on Linux systems. It automates the process of setting up loopback devices, creating files of specified or random sizes, and mounting them with or without filesystems. This tool is particularly useful for developers, system administrators, and testers who need to simulate block devices, perform filesystem operations, or test storage-related functionalities without the need for physical hardware.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
  - [Command Synopsis](#command-synopsis)
  - [Options](#options)
  - [Examples](#examples)
- [Use-Case Scenarios](#use-case-scenarios)
  - [Testing Disk Utilities](#testing-disk-utilities)
  - [Simulating Storage Devices](#simulating-storage-devices)
  - [Performance Benchmarking](#performance-benchmarking)
  - [Filesystem Experimentation](#filesystem-experimentation)
- [How It Works](#how-it-works)
- [Cleanup and Safety](#cleanup-and-safety)
- [Contributing](#contributing)
- [License](#license)

## Features

- **Automated Loop Device Setup**: Quickly create and manage loop devices without manual configuration.
- **File Creation**: Generate files of specific or random sizes to act as virtual block devices.
- **Filesystem Support**: Optionally create filesystems (ext4) on loop devices and mount them for immediate use.
- **Multiple Devices**: Create and manage multiple loop devices simultaneously with ease.
- **Ramdisk Creation**: Set up ramdisks as loop devices for high-speed I/O operations.
- **User-Friendly Interface**: Simple command-line options with detailed help and examples.
- **Automatic Cleanup**: Ensures temporary files and mounts are cleaned up after use.

## Requirements

- **Operating System**: Linux
- **Permissions**: Root privileges (run as `root` or use `sudo`)
- **Utilities**:
  - `bash`
  - `losetup`
  - `dd`
  - `mkfs.ext4`
  - `mount`
  - `umount`
  - `awk`
  - `uuidgen`
  - `mktemp`

## Installation

1. **Clone the Repository**:

   ```bash
   git clone https://github.com/yourusername/mount-loop.sh.git
   ```

2. **Navigate to the Directory**:

   ```bash
   cd mount-loop.sh
   ```

3. **Make the Script Executable**:

   ```bash
   chmod +x mount-loop.sh
   ```

## Usage

### Command Synopsis

```bash
./mount-loop.sh [OPTION]... [FILE]
```

Set up loop devices for a given file, create new files of specified or random sizes, or create a ramdisk of specified size.

### Options

- `--help`: Display help and exit.
- `automount <Size>`: Create a file of the specified size and set it up as a loop device.
- `automountfs <Size>`: Same as `automount` but also create a filesystem and mount it.
- `polymount <N> <Size>`: Create `N` files of the specified size and set them up as loop devices.
- `polymountfs <N> <Size>`: Same as `polymount` but also create filesystems and mount them.
- `polymount rand <N> <MinSize> <MaxSize>`: Create `N` files with random sizes between `MinSize` and `MaxSize`, set them up as loop devices.
- `polymountfs rand <N> <MinSize> <MaxSize>`: Same as above but also create filesystems and mount them.
- `tmpfsmount <Size>`: Create a ramdisk of the specified size as a loop device.
- `tmpfsmountfs <Size>`: Same as `tmpfsmount` but also create a filesystem and mount it.
- `<FilePath>`: Path to an existing file to set up as a loop device.

### Examples

#### Basic Loop Device Setup

- **Set up an existing file as a loop device**:

  ```bash
  sudo ./mount-loop.sh /path/to/your/file.img
  ```

#### Automated File Creation and Loop Device Setup

- **Create a 1G file and set it up as a loop device**:

  ```bash
  sudo ./mount-loop.sh automount 1G
  ```

- **Create a 1G file, set it up as a loop device, create a filesystem, and mount it**:

  ```bash
  sudo ./mount-loop.sh automountfs 1G
  ```

#### Multiple Loop Devices

- **Create 5 files of 1G each and set them up as loop devices**:

  ```bash
  sudo ./mount-loop.sh polymount 5 1G
  ```

- **Same as above but also create filesystems and mount them**:

  ```bash
  sudo ./mount-loop.sh polymountfs 5 1G
  ```

#### Random Sized Loop Devices

- **Create 5 files with random sizes between 500M and 2G**:

  ```bash
  sudo ./mount-loop.sh polymount rand 5 500M 2G
  ```

- **Same as above but also create filesystems and mount them**:

  ```bash
  sudo ./mount-loop.sh polymountfs rand 5 500M 2G
  ```

#### Ramdisk as Loop Device

- **Create a 1G ramdisk and set it up as a loop device**:

  ```bash
  sudo ./mount-loop.sh tmpfsmount 1G
  ```

- **Create a 1G ramdisk, set it up as a loop device, create a filesystem, and mount it**:

  ```bash
  sudo ./mount-loop.sh tmpfsmountfs 1G
  ```

## Use-Case Scenarios

### Testing Disk Utilities

Developers working on disk utilities or applications that interact with block devices can use `mount-loop.sh` to simulate disk environments without the need for physical disks.

- **Scenario**: Testing a new disk cloning tool.
- **Solution**: Create multiple loop devices with filesystems to act as source and target disks.

  ```bash
  sudo ./mount-loop.sh automountfs 5G
  sudo ./mount-loop.sh automountfs 5G
  ```

### Simulating Storage Devices

System administrators can simulate various storage devices for training or testing purposes.

- **Scenario**: Setting up a virtual RAID array.
- **Solution**: Create multiple loop devices and assemble them using `mdadm`.

  ```bash
  sudo ./mount-loop.sh polymount 4 1G
  # Assemble RAID after loop devices are created.
  ```

### Performance Benchmarking

Test the performance of filesystems or applications under different storage conditions.

- **Scenario**: Benchmarking application performance on different storage media.
- **Solution**: Use ramdisks and regular loop devices to compare performance.

  ```bash
  # Ramdisk
  sudo ./mount-loop.sh tmpfsmountfs 1G

  # Regular loop device
  sudo ./mount-loop.sh automountfs 1G
  ```

### Filesystem Experimentation

Experiment with different filesystem types and configurations.

- **Scenario**: Testing the features of a new filesystem.
- **Solution**: Modify the script to format loop devices with the desired filesystem.

  ```bash
  # Modify mkfs command in the script to use mkfs.xfs or another filesystem.
  sudo ./mount-loop.sh automountfs 1G
  ```

## How It Works

The script automates the following processes:

1. **File Creation**: Uses `dd` to create a file of the specified size, filled with zeros.
2. **Loop Device Setup**: Utilizes `losetup` to associate the file with a loop device.
3. **Filesystem Creation** (Optional): Formats the loop device with `mkfs.ext4`.
4. **Mounting** (Optional): Mounts the loop device to a temporary directory created with `mktemp`.
5. **User Interaction**: Waits for user input before proceeding to unmount and detach devices.
6. **Cleanup**: Unmounts filesystems, detaches loop devices, deletes temporary files and directories.

## Cleanup and Safety

- **Automatic Cleanup**: The script ensures that all temporary files, loop devices, and mount points are cleaned up after use.
- **User Prompts**: Before unmounting and detaching, the script waits for user confirmation, allowing for any necessary operations to be performed.
- **Error Handling**: Includes checks and error messages for common issues, such as insufficient permissions or invalid input.

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

This project is licensed under the MIT License. See the [COPYING](COPYING) file for details.

---

**Disclaimer**: Use this script at your own risk. Ensure you have backups and understand the operations being performed, especially when running as root.