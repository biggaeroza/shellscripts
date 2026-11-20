#!/bin/sh
#
# install-appimage.sh - keep AppImage applications in one folder, each with an
# icon and an entry in the applications menu, as if installed.
#
# Usage:
#   install-appimage.sh [--move] [--dir DIR] [--yes] FILE.AppImage...
#   install-appimage.sh --list [--dir DIR]
#   install-appimage.sh --remove NAME... [--dir DIR] [--yes]
#   install-appimage.sh --check [FILE.AppImage...]
#
#   FILE...      AppImages to install (or to update: an app already installed
#                is replaced by the newer file, the previous one kept as .old)
#   --move       move the files instead of copying them (e.g. out of Downloads)
#   --dir DIR    the folder for the apps (default ~/Applications)
#   --list       the apps installed, with their versions
#   --remove     uninstall apps by the name --list shows
#   --check      only report: FUSE (which AppImages need), and what each FILE is
#   --yes        don't ask before changing anything
#
# For each AppImage it:
#   - copies it to DIR/<name>.AppImage (e.g. ~/Applications/ultimaker-cura.AppImage)
#     and makes it executable;
#   - takes its menu entry and icon from inside the file (read without running
#     it), points the entry at the installed file, and writes it to
#     ~/.local/share/applications/appimage-<name>.desktop; the icon goes to
#     DIR/.icons/;
#   - checks that FUSE 2 is installed (AppImages need it to start), and offers
#     to install it.
# Everything is in your home folder; root is only used to install FUSE.

set -eu

SS_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; }

MODE=install
MOVE=0
ASSUME_YES=0
APPS_DIR=""
FILES=""   # newline-separated
add_file() { FILES="$FILES$1
"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --move) MOVE=1 ;;
        --dir) [ $# -ge 2 ] || die "--dir needs a folder"; APPS_DIR=$2; shift ;;
        --list) MODE=list ;;
        --remove) MODE=remove ;;
        --check) MODE=check ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do add_file "$1"; shift; done; break ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) add_file "$1" ;;
    esac
    shift
done

[ "$(id -u)" -ne 0 ] || die "run this as your normal user: it installs into your home folder"

DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
[ -n "$APPS_DIR" ] || APPS_DIR=$HOME/Applications
case "$APPS_DIR" in /*) ;; *) APPS_DIR=$(pwd)/$APPS_DIR ;; esac
APPS_DIR=${APPS_DIR%/}
ICON_DIR=$APPS_DIR/.icons
MENU_DIR=$DATA_HOME/applications
MARK="X-Installed-By=install-appimage.sh"

refresh_menu() {
    have_cmd update-desktop-database && update-desktop-database "$MENU_DIR" >/dev/null 2>&1 || true
}

# --- FUSE ----------------------------------------------------------------------------

have_fuse2() {
    if have_cmd ldconfig || [ -x /sbin/ldconfig ]; then
        { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -q 'libfuse\.so\.2'
        return
    fi
    for _d in /usr/lib /usr/lib64 /lib /lib64 /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu; do
        [ -e "$_d/libfuse.so.2" ] && return 0
    done
    return 1
}

# fuse2_package - the distro's FUSE 2 library package (Debian 13 and Ubuntu
# 24.04 renamed it libfuse2t64).
fuse2_package() {
    if [ "$(pkg_manager)" = apt ]; then
        if apt-cache show libfuse2t64 >/dev/null 2>&1; then echo libfuse2t64; else echo libfuse2; fi
        return 0
    fi
    pkg_name libfuse2 fuse-libs fuse2 libfuse2 fuse
}

check_fuse() {
    if have_fuse2; then
        ok "FUSE 2 is installed (AppImages can start)"
        return 0
    fi
    _p=$(fuse2_package || true)
    warn "FUSE 2 (libfuse.so.2) is missing: AppImages won't start without it${_p:+ (package $_p)}"
    [ "$MODE" = check ] && return 0
    [ -n "$_p" ] || { warn "install FUSE 2 with your package manager"; return 0; }
    if confirm "Install $_p (needs root)?"; then
        pkg_install "$_p" && ok "$_p installed"
    fi
}

# link_target LINK - where a symbolic link points (POSIX: no readlink in it).
link_target() {
    # shellcheck disable=SC2012 # one known link; ls -l is the portable way to its target
    ls -l "$1" | sed 's/.* -> //'
}

# --- reading an AppImage ---------------------------------------------------------------

# appimage_type FILE - 2 (squashfs), 1 (old ISO 9660), or 0 (not an AppImage).
appimage_type() {
    _m=$(od -An -c -j 8 -N 3 "$1" 2>/dev/null | tr -d ' ')
    case "$_m" in
        'AI002') echo 2 ;;
        'AI001') echo 1 ;;
        *) echo 0 ;;
    esac
}

# squashfs_offset FILE - where a type-2 AppImage's file system starts: right
# after its runtime, an ELF file whose size is the end of its section header
# table (e_shoff + e_shentsize * e_shnum; 64-bit little-endian runtimes).
squashfs_offset() {
    [ "$(od -An -t u1 -j 4 -N 1 "$1" | tr -d ' ')" = 2 ] || return 1  # ELFCLASS64
    _shoff=$(od -An -t u8 -j 40 -N 8 "$1" | tr -d ' ')
    _ent=$(od -An -t u2 -j 58 -N 2 "$1" | tr -d ' ')
    _num=$(od -An -t u2 -j 60 -N 2 "$1" | tr -d ' ')
    echo $((_shoff + _ent * _num))
}

# extract_meta FILE DEST - the top-level .desktop file(s), .DirIcon and icon
# files into DEST, read with unsquashfs (the AppImage is not run).
extract_meta() {
    _off=$(squashfs_offset "$1") || return 1
    unsquashfs -q -n -o "$_off" -d "$2" "$1" '*.desktop' .DirIcon '*.png' '*.svg' '*.xpm' >/dev/null 2>&1 || return 1
    # .DirIcon may point deeper into the image: get that file too
    if [ -L "$2/.DirIcon" ]; then
        _t=$(link_target "$2/.DirIcon")
        case "$_t" in
            /*|*..*) ;;
            *) [ -e "$2/$_t" ] || unsquashfs -q -n -f -o "$_off" -d "$2" "$1" "$_t" >/dev/null 2>&1 || true ;;
        esac
    fi
    return 0
}

# desktop_value FILE KEY - a key's value from the [Desktop Entry] group.
desktop_value() {
    awk -v k="$2" '
        /^\[/ { g = ($0 == "[Desktop Entry]") ; next }
        g && index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}

# slug TEXT - lower case, letters, digits and dashes.
slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//'
}

# name_from_file FILE - an app name from a file name: "UltiMaker-Cura-5.14.0-linux-X64.AppImage"
# gives "UltiMaker-Cura" (the parts before the first one with a digit).
name_from_file() {
    basename "$1" | sed 's/\.[Aa]pp[Ii]mage$//' | awk -F'[-_ ]' '{
        n = ""; for (i = 1; i <= NF; i++) { if ($i ~ /[0-9]/) break; n = n (n == "" ? "" : "-") $i }
        print (n == "" ? $1 : n) }'
}

# --- install one ------------------------------------------------------------------------

install_one() {
    _src=$1
    [ -f "$_src" ] || { warn "$_src: no such file"; return 1; }
    _type=$(appimage_type "$_src")
    [ "$_type" != 0 ] || { warn "$_src: not an AppImage (no AppImage signature)"; return 1; }

    _tmp=$(mktemp -d)
    _desk=""
    if [ "$_type" = 2 ] && have_cmd unsquashfs && extract_meta "$_src" "$_tmp/m"; then
        for _d in "$_tmp"/m/*.desktop; do
            [ -f "$_d" ] && { _desk=$_d; break; }
        done
    elif [ "$_type" = 1 ]; then
        warn "$(basename "$_src") is an old type-1 AppImage: installed without its own icon and menu details"
    fi

    _name=""; _ver=""
    if [ -n "$_desk" ]; then
        _name=$(desktop_value "$_desk" Name)
        _ver=$(desktop_value "$_desk" X-AppImage-Version)
    fi
    [ -n "$_name" ] || _name=$(name_from_file "$_src")
    _id=$(slug "$_name")
    [ -n "$_id" ] || _id=app
    _dest=$APPS_DIR/$_id.AppImage
    _entry=$MENU_DIR/appimage-$_id.desktop

    _what="$_name${_ver:+ $_ver}"
    if [ -e "$_dest" ]; then
        _old=$(desktop_value "$_entry" X-AppImage-Version 2>/dev/null || true)
        confirm "Replace the installed $_name${_old:+ $_old} with $(basename "$_src")${_ver:+ ($_ver)}?" \
            || { rm -rf "$_tmp"; info "  $_name: skipped"; return 0; }
    else
        confirm "Install $_what as $_dest?" || { rm -rf "$_tmp"; info "  $_name: skipped"; return 0; }
    fi

    # the file: copied (or moved) in under a temporary name, then swapped in
    mkdir -p "$APPS_DIR" "$ICON_DIR" "$MENU_DIR"
    if [ "$MOVE" -eq 1 ]; then
        mv -f "$_src" "$_dest.new"
    else
        cp -f "$_src" "$_dest.new"
    fi
    chmod 755 "$_dest.new"
    if [ -e "$_dest" ]; then
        mv -f "$_dest" "$_dest.old"
    fi
    mv -f "$_dest.new" "$_dest"

    # the icon: the one the entry names (any extension), else .DirIcon
    _icon=""
    if [ -d "$_tmp/m" ]; then
        _iname=""
        [ -n "$_desk" ] && _iname=$(desktop_value "$_desk" Icon)
        for _c in "$_tmp/m/$_iname" "$_tmp/m/$_iname.svg" "$_tmp/m/$_iname.png" "$_tmp/m/$_iname.xpm" "$_tmp/m/.DirIcon"; do
            [ -n "$_iname" ] || [ "$_c" = "$_tmp/m/.DirIcon" ] || continue
            if [ -f "$_c" ]; then
                # the real file behind a link, and its kind from its contents
                _f=$_c
                if [ -L "$_c" ]; then
                    _t=$(link_target "$_c")
                    [ -f "$_tmp/m/$_t" ] && _f=$_tmp/m/$_t
                fi
                case "$(od -An -c -N 4 "$_f" | tr -d ' ')" in
                    *PNG*) _ext=png ;;
                    *'<'*) _ext=svg ;;
                    *) case "$_f" in *.xpm) _ext=xpm ;; *.svg) _ext=svg ;; *) _ext=png ;; esac ;;
                esac
                rm -f "$ICON_DIR/$_id".*
                cp -f "$_f" "$ICON_DIR/$_id.$_ext"
                _icon=$ICON_DIR/$_id.$_ext
                break
            fi
        done
    fi

    # the menu entry: the app's own, its programs pointed at the installed file
    _exec=$_dest
    case "$_dest" in *' '*) _exec="\"$_dest\"" ;; esac
    if [ -n "$_desk" ]; then
        awk -v exe="$_exec" -v icon="$_icon" -v try="$_dest" -v mark="$MARK" '
            BEGIN { done_try = 0 }
            /^\[/ {
                if (ingroup && !done_try) { print "TryExec=" try; print mark; done_try = 1 }
                ingroup = ($0 == "[Desktop Entry]"); print; next
            }
            /^Exec=/ {
                rest = substr($0, 6); sub(/^[^ ]+/, "", rest)   # keep the arguments (%U, %F ...)
                print "Exec=" exe rest; next
            }
            /^TryExec=/ || /^DBusActivatable=/ || /^X-Installed-By=/ { next }
            /^Icon=/ { if (icon != "") print "Icon=" icon; else print; next }
            { print }
            END { if (ingroup && !done_try) { print "TryExec=" try; print mark } }' "$_desk" > "$_entry.new"
        grep -q '^Exec=' "$_entry.new" || printf 'Exec=%s %%F\n' "$_exec" >> "$_entry.new"
    else
        {
            echo '[Desktop Entry]'
            echo 'Type=Application'
            echo "Name=$_name"
            echo "Exec=$_exec %F"
            echo "TryExec=$_dest"
            [ -n "$_icon" ] && echo "Icon=$_icon"
            echo 'Terminal=false'
            echo 'Categories=Utility;'
            echo "$MARK"
        } > "$_entry.new"
    fi
    mv -f "$_entry.new" "$_entry"
    rm -rf "$_tmp"
    if have_cmd desktop-file-validate; then
        desktop-file-validate "$_entry" >/dev/null 2>&1 || info "  (desktop-file-validate has remarks on $(basename "$_entry"); it works regardless)"
    fi
    ok "$_what: $_dest, menu entry $(basename "$_entry")${_icon:+, icon}"
    [ -e "$_dest.old" ] && info "  the previous version is kept as $_dest.old until the next update"
    return 0
}

# --- list / remove ----------------------------------------------------------------------

list_apps() {
    _n=0
    for _e in "$MENU_DIR"/appimage-*.desktop; do
        if [ ! -f "$_e" ] || ! grep -qx "$MARK" "$_e"; then continue; fi
        _id=${_e##*/appimage-}; _id=${_id%.desktop}
        _file=$(desktop_value "$_e" TryExec)
        _state=""
        [ -f "$_file" ] || _state=" (its file is missing)"
        printf '%-24s %-28s %-12s %s%s\n' "$_id" "$(desktop_value "$_e" Name)" "$(desktop_value "$_e" X-AppImage-Version)" "$_file" "$_state"
        _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] || info "no AppImages installed by this script"
}

remove_app() {
    _id=$1
    _e=$MENU_DIR/appimage-$_id.desktop
    if [ ! -f "$_e" ] || ! grep -qx "$MARK" "$_e"; then
        warn "$_id: not installed by this script (see --list)"
        return 1
    fi
    _file=$(desktop_value "$_e" TryExec)
    confirm "Remove $(desktop_value "$_e" Name) ($_file and its menu entry)?" || { info "  $_id: kept"; return 0; }
    rm -f "$_file" "$_file.old" "$_e"
    rm -f "$ICON_DIR/$_id".*
    ok "$_id removed (its settings in your home folder are kept)"
}

# --- main ----------------------------------------------------------------------------------

case "$MODE" in
    list)
        list_apps
        ;;
    remove)
        [ -n "$FILES" ] || die "give the name(s) to remove (see --list)"
        _fail=0
        # the names on fd 3, so confirm() still reads the terminal
        while IFS= read -r _a <&3; do
            [ -n "$_a" ] || continue
            remove_app "$_a" || _fail=1
        done 3<<EOF
$FILES
EOF
        refresh_menu
        exit "$_fail"
        ;;
    check)
        check_fuse
        if have_cmd unsquashfs; then
            ok "unsquashfs is installed (menu entries and icons are read from the files)"
        else
            warn "unsquashfs (package squashfs-tools) is missing: apps would get a plain menu entry without their icon"
        fi
        if [ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] \
            && [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)" = 1 ]; then
            warn "AppArmor restricts unprivileged user namespaces: Electron-based AppImages may fail to start (\"sandbox\" errors)"
        fi
        while IFS= read -r _f <&3; do
            [ -n "$_f" ] || continue
            case "$(appimage_type "$_f")" in
                2) info "$_f: AppImage (type 2)" ;;
                1) info "$_f: AppImage (type 1, old)" ;;
                *) warn "$_f: not an AppImage" ;;
            esac
        done 3<<EOF
$FILES
EOF
        info "Apps go to: $APPS_DIR"
        ;;
    install)
        [ -n "$FILES" ] || die "give the AppImage file(s) to install (see --help)"
        if ! have_cmd unsquashfs; then
            _p=$(pkg_name squashfs-tools squashfs-tools squashfs-tools squashfs squashfs-tools || true)
            warn "unsquashfs is missing: without it the apps get a plain menu entry without their icon"
            if [ -n "$_p" ] && confirm "Install $_p first (needs root)?"; then
                pkg_install "$_p"
            fi
        fi
        _fail=0
        # the files on fd 3, so confirm() still reads the terminal
        while IFS= read -r _f <&3; do
            [ -n "$_f" ] || continue
            install_one "$_f" || _fail=1
        done 3<<EOF
$FILES
EOF
        refresh_menu
        check_fuse
        exit "$_fail"
        ;;
esac
