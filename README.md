# λrchietype
Archietype follows the ArchWiki philosophy while experimenting with a more structured and extensible approach using a small DSL (Domain Specific Language).

# Features
* Interactive installation (prompts + defaults)
* Structured configuration object (plist-based)
* Step-based execution engine
* Conditional steps (:when)
* Retry / skip / quit on failure
* UEFI + swap support

# Example (DSL)
```
(make-step :format-root
  :desc "Format root"
  :when #'wants-format-root
  :run  #'format-root)
```

# Requirements
This installer assumes:
* You are running from the Arch Linux live ISO
* You have a working internet connection
* sbcl and git are installed
* Your disk is already partitioned

You must manually create partitions before running this tool (e.g. using fdisk, cfdisk, or parted).

Typical setup:
* Root partition (e.g. /dev/sda2)
* EFI partition (for UEFI systems)
* Optional swap partition

# Usage
```
git clone https://github.com/ivnqc/archietype.git
cd archietype
chmod +x archietype.lisp
sbcl --script ./archietype.lisp
```

# Project Goals
* Learn Common Lisp through a real system tool
* Explore functional patterns in scripting
* Build a simple installer DSL

# Disclaimer
This is an experimental installer.
Use at your own risk.
