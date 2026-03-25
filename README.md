# λrchietype
A minimal, experimental Arch Linux installer written in Common Lisp.

This project explores a **structured and programmable approach** to system installation using a small step-based execution model and a Lisp DSL.

## Features
- Step-based installation workflow
- Small Lisp DSL for defining installation steps
- Declarative step conditions via `:when`
- Shared configuration state passed between steps
- Interactive execution (retry / skip / quit on failure)
- Optional swap partition

## DSL
Steps are defined using a small macro-based DSL:
```
(step format-root
     (:desc "Format root"
      :when (wants-format-root config))
     (format-root config))
```

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

- `systemd-boot` as the bootloader
- `systemd-networkd` for networking
- `systemd-resolved` for DNS
- `systemd-timesyncd` for time synchronization

Making it easy to customize and extend after installation.

## Usage
```
git clone https://github.com/ivnqc/archietype.git
cd archietype
sbcl --script archietype.lisp
```

## Project Goals
* Learn Common Lisp through a real system tool
* Explore functional patterns in scripting
* Build a simple installer DSL

# Disclaimer
This is an experimental installer. While it is functional, edge cases and unexpected behavior may occur.
Use at your own risk.
