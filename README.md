# shellscripts

Helper scripts for setting up machines and running everyday tasks. Every
script must work on any Linux distribution, not only the one it was
written on.

## Scripts

| Script | What it does |
|---|---|
| `bin/add-to-dialout.sh` | Adds you to the serial-port group (`dialout`, or `uucp` on Arch) so you can use USB-serial adapters without root. `--check` only reports. |
| `bin/install-virt-manager.sh` | Installs QEMU/KVM, libvirt and virt-manager with UEFI firmware, a software TPM, virt-install and virt-viewer; starts libvirt, turns on the `default` NAT network and adds you to the `libvirt` and `kvm` groups. `--check` only reports. |
| `bin/install-bga-dev.sh` | Installs everything needed to build and test the BIG-G Aerospace projects: Go (fetching the 1.26.8 the repos pin), GTK 3 and WebKitGTK 4.1 for the Wails desktop windows, libopus/libopusfile, the AArch64 cross-compiler (or the Arm GNU Toolchain where the distro has none), Rust 1.98.1 with the kernel target, QEMU and gdb-multiarch for `ktest.py`, Node, Yarn 1.22.22 and clangd for the IDEs, Alire with GNAT 16.1.0 (aarch64-elf), gprbuild 26.0.1 and GNATprove 16.1.0, a Python venv for bga-tcd's table generators, and the serial-port group. Per-user tools go in your home without root; every download is SHA-256 checked against a pinned hash. `--only`/`--skip` pick parts, `--check` only reports. |
| `bin/install-lamp.sh` | Installs and configures Apache, MariaDB, PHP and phpMyAdmin. Asks for every name and password first (MariaDB root, an admin user for phpMyAdmin, server name, whether phpMyAdmin and MariaDB are reachable from the LAN, firewall), then sets everything up with nothing more to answer: secured MariaDB listening on 127.0.0.1 or, if asked, the LAN (that subnet only, root never), phpMyAdmin from phpmyadmin.net (SHA-256 checked) with its configuration storage, and a final check that it all answers. `--check` only reports. |
| `bin/install-materializr.sh` | Gets the latest [Materializr](https://github.com/materializr-cad/materializr) source (main, or `--stable` for the latest release), builds it with OpenCASCADE at the version the project pins, installs it under `~/.local` and adds it to the applications menu with its icon. Run it again to update; it rebuilds only when there is something new. `--check` reports, `--uninstall` removes it. |
| `bin/install-android-studio.sh` | Installs or updates Android Studio from the `.tar.gz` you downloaded (the newest in your Downloads folder, or `--file`) into `~/.local/opt/android-studio`, with an `android-studio` command and a menu entry. The previous version is kept as `.old` until the next update; an identical second download is pointed out. Checks that the emulator can use KVM and offers to add you to the `kvm` group. Settings, projects and the SDK are never touched. `--check` only reports, `--uninstall` removes it. |
| `bin/install-blender.sh` | Installs or updates [Blender](https://www.blender.org) from the `.tar.xz` you downloaded (the newest in your Downloads folder, or `--file`) into `~/.local/opt/blender`, with a `blender` command, its icon and Blender's own menu entry (so `.blend` files open in it). The previous version is kept as `.old` until the next update; re-running with the same version only refreshes the menu entry. Your settings and add-ons are never touched. `--check` only reports, `--uninstall` removes it. |
| `bin/install-appimage.sh` | Keeps AppImage apps in one folder (`~/Applications`, `--dir`) with their icon and a menu entry, as if installed: the app's own menu entry and icon are read from inside the file (without running it) and pointed at the installed copy. Installing a newer file of the same app replaces it (the previous one kept as `.old`); `--move` takes the files out of Downloads instead of copying. Checks for FUSE 2, which AppImages need, and offers to install it. `--list`, `--remove NAME`, `--check`. |
| `bin/claude-optimized.sh` | Runs [Claude Code](https://claude.com/claude-code) through a local [Headroom](https://github.com/headroomlabs-ai/headroom) compression proxy: starts `headroom proxy` (port 8787, `--port`), waits until it is healthy, runs `claude` against it with your arguments, and stops the proxy when Claude Code exits. A Headroom proxy left over on the port is stopped after asking; anything else there is left alone. `--check` only reports. |
| `bin/fixperms.sh` | From the UserSpice maintainer, kept as received (bash, plain `sudo`; not held to the rules below): fixes the permissions of a directory under `/var/www/html` (or all of them with `'*'`) for UserSpice: yours and `webdev`'s, 775/664, setgid directories, `.php` files 775; needs the `webdev` group with you and `www-data` in it. `mkwebdir.sh` is the general version. |
| `bin/mkwebdir.sh` | Creates a web project directory (under the web root, or any path) that you can create, copy and delete in at once without sudo, and that the web server can use: yours and a shared group's (`webdev`, created with you and the web server's user in it), setgid directories, default ACLs so new files get group write whatever your umask. `--fix` takes over an existing directory, `--no-web-write` makes it read-only for the web server, `--check` only reports. Derived from the UserSpice maintainer's `fixperms.sh`. |
| `bin/python-env.sh` | Makes a plain `pip install NAME` work again on distros that block it (PEP 668 "externally-managed-environment"), with no venv juggling: creates one personal venv (`~/.venv`, sees the distro's Python packages too) and puts it first on `PATH` in `~/.profile` and your shell rc, so `pip`, `python` and anything pip installs just work. No root needed (bootstraps pip itself if `python3-venv` is missing). `--rebuild` after a Python upgrade reinstalls your packages, `--uninstall` undoes it, `--check` only reports. |

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
