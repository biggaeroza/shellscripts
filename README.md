# shellscripts

Helper scripts for setting up machines and running everyday tasks. Every
script must work on any Linux distribution, not only the one it was
written on.

## Scripts

| Script | What it does |
|---|---|
| `bin/add-to-dialout.sh` | Adds you to the serial-port group (`dialout`, or `uucp` on Arch) so you can use USB-serial adapters without root. `--check` only reports. |
| `bin/install-virt-manager.sh` | Installs QEMU/KVM, libvirt and virt-manager with UEFI firmware, a software TPM, virt-install and virt-viewer; starts libvirt, turns on the `default` NAT network and adds you to the `libvirt` and `kvm` groups. `--check` only reports. |

Every script shows its options with `--help`, asks before changing
anything (`--yes` skips the question) and uses root only for the steps
that need it.

## Layout

```
bin/            the scripts, one task each (NAME.sh, executable)
bin/_template.sh  starting point for a new script
lib/common.sh   shared helpers: output, distro and package-manager
                detection, root via sudo/doas, package installs
```

Run a script from anywhere: `~/shellscripts/bin/NAME.sh`, or put
`~/shellscripts/bin` on `PATH`.

## Rules for scripts

- **POSIX `sh` only.** Start with `#!/bin/sh` and `set -eu`. No bash
  features (arrays, `[[ ]]`, `local`, `$'...'`, `<<<`, `source`,
  `function`), so the script runs under dash, busybox ash and bash alike.
  A script that really needs bash says `#!/usr/bin/env bash` and states why
  in its header.
- **No distro assumptions.** Use `pkg_manager` and `os_like` from
  `lib/common.sh` instead of checking for one distro. Package names
  differ between distros, so give one name per package manager with
  `pkg_name`. Never hard-code `apt`.
- **Portable tool flags.** Use only POSIX options of `sed`, `grep`, `find`,
  `readlink`, etc. (no `sed -i`, `grep -P`, `readlink -f`). If a GNU-only
  option can't be avoided, check for it first.
- **Root only when needed.** Use `as_root` (sudo, else doas), never a bare
  `sudo`. Don't run the whole script as root.
- **Ask before changing the system.** Check first and report. Install or
  change anything only after `confirm`, or when `--yes` was given.
- **`--help` on every script**, printed from the header comment.
- **Check with ShellCheck** before committing:
  `shellcheck -s sh bin/*.sh lib/*.sh` (the ShellCheck package is named
  `shellcheck` on most distros, `ShellCheck` on Fedora).

## License

MIT, see [LICENSE](LICENSE).
