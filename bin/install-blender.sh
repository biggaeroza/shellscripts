#!/bin/sh
#
# install-blender.sh - install (or update) Blender from the archive you
# downloaded from blender.org, for the current user, with a command and an
# entry in the applications menu.
#
# Usage:
#   install-blender.sh [--file ARCHIVE] [--dir DIR] [--force] [--yes]
#   install-blender.sh --check
#   install-blender.sh --uninstall [--yes]
#
#   --file ARCHIVE  the blender-*-linux-*.tar.xz to install (default: the
#                   newest one in your Downloads folder)
#   --dir DIR       where to install it (default ~/.local/opt/blender)
#   --force         reinstall even if that version is already installed
#   --check         only report: what is installed, which archive would be
#                   used, disk space
#   --yes           don't ask before installing or changing anything
#   --uninstall     remove Blender, its command, icon and menu entry
#
# What it does:
#   - unpacks the archive next to the install folder and checks it is
#     Blender, then swaps it in; the previous version is kept as DIR.old
#     until the next update (so a bad update can be undone by hand);
#   - ~/.local/bin/blender starts it;
#   - ~/.local/share/applications/blender.desktop is the menu entry (Blender's
#     own, pointed at the installed copy), with its icon, and .blend files
#     open in it.
# Your settings and add-ons (~/.config/blender) are never touched, by
# installing or uninstalling. Nothing needs root.

set -eu

SS_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; }

ARCHIVE=""
APP_DIR=""
FORCE=0
CHECK_ONLY=0
UNINSTALL=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --file) [ $# -ge 2 ] || die "--file needs an archive"; ARCHIVE=$2; shift ;;
        --dir) [ $# -ge 2 ] || die "--dir needs a folder"; APP_DIR=$2; shift ;;
        --force) FORCE=1 ;;
        --check) CHECK_ONLY=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

[ "$(id -u)" -ne 0 ] || die "run this as your normal user: it installs into your home folder"

DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
[ -n "$APP_DIR" ] || APP_DIR=$HOME/.local/opt/blender
case "$APP_DIR" in /*) ;; *) APP_DIR=$(pwd)/$APP_DIR ;; esac
APP_DIR=${APP_DIR%/}
BIN_LINK=$HOME/.local/bin/blender
DESKTOP_FILE=$DATA_HOME/applications/blender.desktop
ICON_FILE=$DATA_HOME/icons/hicolor/scalable/apps/blender.svg
ICON_SYM=$DATA_HOME/icons/hicolor/symbolic/apps/blender-symbolic.svg

# downloads_dir - the user's Downloads folder (XDG, in their language), else
# ~/Downloads.
downloads_dir() {
    _d=""
    have_cmd xdg-user-dir && _d=$(xdg-user-dir DOWNLOAD 2>/dev/null || true)
    if [ -z "$_d" ] || [ "$_d" = "$HOME" ] || [ ! -d "$_d" ]; then
        _d=$HOME/Downloads
    fi
    printf '%s\n' "$_d"
}

# version_of DIR - the Blender version of an unpacked copy, from its
# version-numbered data folder (e.g. 5.3) and the folder name it came in.
version_of() {
    if [ -f "$1/.bga-version" ]; then
        cat "$1/.bga-version"
        return 0
    fi
    for _v in "$1"/[0-9]*.[0-9]*; do
        [ -d "$_v" ] && { basename "$_v"; return 0; }
    done
    printf 'unknown\n'
}

refresh_menu() {
    have_cmd update-desktop-database && update-desktop-database "$DATA_HOME/applications" >/dev/null 2>&1 || true
    have_cmd gtk-update-icon-cache && gtk-update-icon-cache -q -t "$DATA_HOME/icons/hicolor" >/dev/null 2>&1 || true
}

# --- uninstall -----------------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
    if [ ! -e "$APP_DIR" ] && [ ! -e "$APP_DIR.old" ] && [ ! -e "$DESKTOP_FILE" ] && [ ! -L "$BIN_LINK" ]; then
        ok "Blender is not installed in $APP_DIR"
        exit 0
    fi
    info "Removes: $APP_DIR (and $APP_DIR.old), $BIN_LINK, $DESKTOP_FILE, its icons"
    info "Kept: your settings and add-ons (~/.config/blender)"
    confirm "Uninstall Blender?" || die "nothing changed"
    rm -rf "$APP_DIR" "$APP_DIR.old"
    [ -L "$BIN_LINK" ] && rm -f "$BIN_LINK"
    rm -f "$DESKTOP_FILE" "$ICON_FILE" "$ICON_SYM"
    refresh_menu
    ok "Blender removed"
    exit 0
fi

# --- the archive -----------------------------------------------------------------

DL=$(downloads_dir)
OTHERS=""
if [ -z "$ARCHIVE" ]; then
    # the newest blender-*-linux-*.tar.xz (browsers add " (1)" to repeats)
    for _f in "$DL"/blender-*linux*.tar.xz; do
        [ -f "$_f" ] || continue
        if [ -z "$ARCHIVE" ] || [ "$_f" -nt "$ARCHIVE" ]; then
            [ -n "$ARCHIVE" ] && OTHERS="$OTHERS
$ARCHIVE"
            ARCHIVE=$_f
        else
            OTHERS="$OTHERS
$_f"
        fi
    done
    [ -n "$ARCHIVE" ] || die "no blender-*-linux-*.tar.xz in $DL: download it from https://www.blender.org/download/ (Linux), or give --file"
fi
[ -f "$ARCHIVE" ] || die "$ARCHIVE: no such file"
case "$ARCHIVE" in *.tar.xz) ;; *) die "$ARCHIVE: expected the .tar.xz archive" ;; esac

# the version from the file name, e.g. blender-5.3.0-linux-x64.tar.xz -> 5.3.0
NEW_VERSION=$(basename "$ARCHIVE" | sed -n 's/^blender-\([0-9][0-9.]*[0-9]\)-linux.*/\1/p')

# --- report --------------------------------------------------------------------

info "Archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))${NEW_VERSION:+, Blender $NEW_VERSION}"
if [ -n "$OTHERS" ]; then
    printf '%s\n' "$OTHERS" | while IFS= read -r _o; do
        [ -n "$_o" ] && info "  also in Downloads: $_o (older, not used)"
    done
fi
if [ -d "$APP_DIR" ]; then
    INSTALLED=$(version_of "$APP_DIR")
    info "Installed: Blender $INSTALLED in $APP_DIR"
else
    INSTALLED=""
    info "Installed: not yet (it will go to $APP_DIR)"
fi

PARENT=$(dirname "$APP_DIR")
mkdir -p "$PARENT"
# room for the unpacked copy (about 4 times the .tar.xz) while the old one stays
# shellcheck disable=SC2017 # kB first, so the product cannot overflow
NEED_KB=$(( $(wc -c < "$ARCHIVE" | tr -d ' ') / 1024 * 4 ))
FREE_KB=$(df -Pk "$PARENT" | awk 'NR == 2 { print $4 }')
if [ "$FREE_KB" -lt "$NEED_KB" ]; then
    warn "only $((FREE_KB / 1024)) MB free in $PARENT; about $((NEED_KB / 1024)) MB are needed"
    [ "$CHECK_ONLY" -eq 1 ] || die "free some space first"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    exit 0
fi

if [ -n "$INSTALLED" ] && [ -n "$NEW_VERSION" ] && [ "$INSTALLED" = "$NEW_VERSION" ] && [ "$FORCE" -eq 0 ]; then
    ok "Blender $NEW_VERSION is already installed (use --force to reinstall)"
    SKIP_UNPACK=1
else
    SKIP_UNPACK=0
fi

# --- unpack, check, swap in --------------------------------------------------------

if [ "$SKIP_UNPACK" -eq 0 ]; then
    confirm "Install Blender ${NEW_VERSION:-from $(basename "$ARCHIVE")} into $APP_DIR?" || die "nothing changed"
    need_cmd tar xz

    STAGE=$(mktemp -d "$PARENT/.blender-new.XXXXXX")
    trap 'rm -rf "$STAGE"' EXIT INT TERM
    info "Unpacking (about a minute)..."
    xz -dc "$ARCHIVE" | tar -xf - -C "$STAGE" || die "the archive does not unpack: download it again"
    NEW=""
    for _d in "$STAGE"/blender-*; do
        [ -d "$_d" ] && NEW=$_d
    done
    if [ -z "$NEW" ] || [ ! -x "$NEW/blender" ]; then
        die "$ARCHIVE does not contain Blender (no blender-*/blender)"
    fi
    [ -n "$NEW_VERSION" ] || NEW_VERSION=$(version_of "$NEW")
    printf '%s\n' "$NEW_VERSION" > "$NEW/.bga-version"

    if [ -d "$APP_DIR" ]; then
        rm -rf "$APP_DIR.old"
        mv "$APP_DIR" "$APP_DIR.old"
        info "The previous version is kept as $APP_DIR.old until the next update"
    fi
    mv "$NEW" "$APP_DIR"
    rm -rf "$STAGE"
    trap - EXIT INT TERM
    ok "Installed Blender $NEW_VERSION in $APP_DIR"
fi

# --- the command, icon and menu entry ----------------------------------------------------

LAUNCHER=$APP_DIR/blender
mkdir -p "$(dirname "$BIN_LINK")"
if [ -e "$BIN_LINK" ] && [ ! -L "$BIN_LINK" ]; then
    warn "$BIN_LINK exists and is not a link: left alone"
else
    ln -sfn "$LAUNCHER" "$BIN_LINK"
fi

mkdir -p "$(dirname "$ICON_FILE")" "$(dirname "$ICON_SYM")" "$(dirname "$DESKTOP_FILE")"
[ -f "$APP_DIR/blender.svg" ] && cp "$APP_DIR/blender.svg" "$ICON_FILE"
[ -f "$APP_DIR/blender-symbolic.svg" ] && cp "$APP_DIR/blender-symbolic.svg" "$ICON_SYM"

# Blender's own entry (all its translations), with Exec and TryExec pointing
# at the installed copy so it works even without ~/.local/bin on PATH.
if [ -f "$APP_DIR/blender.desktop" ]; then
    sed -e "s|^Exec=.*|Exec=\"$LAUNCHER\" %f|" -e '/^TryExec=/d' "$APP_DIR/blender.desktop" > "$DESKTOP_FILE"
    printf 'TryExec=%s\n' "$LAUNCHER" >> "$DESKTOP_FILE"
else
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Blender
GenericName=3D modeler
Comment=3D modeling, animation, rendering and post-production
Exec="$LAUNCHER" %f
TryExec=$LAUNCHER
Icon=blender
Terminal=false
Categories=Graphics;3DGraphics;
MimeType=application/x-blender;
StartupWMClass=Blender
EOF
fi
have_cmd desktop-file-validate && { desktop-file-validate "$DESKTOP_FILE" || warn "desktop-file-validate reported problems with $DESKTOP_FILE"; }
refresh_menu
ok "Menu entry: Blender (Graphics); command: blender"

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "$HOME/.local/bin is not on your PATH: the blender command needs it (the menu entry works anyway)" ;;
esac

[ -n "$OTHERS" ] && info "Tip: the Downloads folder still has older Blender archive(s), listed above."
info "Start it from the menu or with: blender"
