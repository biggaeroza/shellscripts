# shellscripts

Helper scripts for setting up machines and running everyday tasks. Every
script must work on any Linux distribution, not only the one it was
written on.

## Scripts

| Script | What it does |
|---|---|
| `bin/add-to-dialout.sh` | Adds you to the serial-port group (`dialout`, or `uucp` on Arch) so you can use USB-serial adapters without root. `--check` only reports. |
| `bin/install-virt-manager.sh` | Installs QEMU/KVM, libvirt and virt-manager with UEFI firmware, a software TPM, virt-install and virt-viewer; starts libvirt, turns on the `default` NAT network and adds you to the `libvirt` and `kvm` groups. `--check` only reports. |
| `bin/install-lamp.sh` | Installs and configures Apache, MariaDB, PHP and phpMyAdmin. Asks for every name and password first (MariaDB root, an admin user for phpMyAdmin, server name, whether phpMyAdmin and MariaDB are reachable from the LAN, firewall), then sets everything up with nothing more to answer: secured MariaDB listening on 127.0.0.1 or, if asked, the LAN (that subnet only, root never), phpMyAdmin from phpmyadmin.net (SHA-256 checked) with its configuration storage, and a final check that it all answers. `--check` only reports. |
| `bin/install-materializr.sh` | Gets the latest [Materializr](https://github.com/materializr-cad/materializr) source (main, or `--stable` for the latest release), builds it with OpenCASCADE at the version the project pins, installs it under `~/.local` and adds it to the applications menu with its icon. Run it again to update; it rebuilds only when there is something new. `--check` reports, `--uninstall` removes it. |
| `bin/mkwebdir.sh` | Creates a web project directory (under the web root, or any path) that you can create, copy and delete in at once without sudo, and that the web server can use: yours and a shared group's (`webdev`, created with you and the web server's user in it), setgid directories, default ACLs so new files get group write whatever your umask. `--fix` takes over an existing directory, `--no-web-write` makes it read-only for the web server, `--check` only reports. Derived from the UserSpice maintainer's `fixperms.sh`. |

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
