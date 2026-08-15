# λrchietype
This is a small installer for setting up a minimal Arch Linux system on a UEFI machine. It uses Common Lisp for the installation logic and generates a small amount of shell code for operations that run inside the target system.

## Features
- Interactive installation
- Optional swap partition
- Custom hostname, locale, and keyboard layout
- Unified Kernel Images (UKIs)

## Required packages
* `git`
* `sbcl`

## Assumptions
- Disk is already partitioned
- UEFI system
- Ext4 file system on `/dev/root_partition`

*You must manually create partitions before running this tool.*

## System design
λrchietype installs a minimal Arch system using only:

- `base`
- `linux`

With a minimal systemd-based setup:

- `systemd-boot`
- `systemd-networkd`
- `systemd-resolved`
- `systemd-timesyncd`

Making it easy to customize and extend after installation.

## Usage
```
git clone https://github.com/ivnqc/archietype.git
cd archietype
sbcl --script archietype.lisp
```

# Disclaimer
This is an experimental installer. While it is functional, edge cases and unexpected behavior may occur.
