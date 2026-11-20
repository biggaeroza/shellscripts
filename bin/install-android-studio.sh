#!/bin/sh
#
# install-android-studio.sh - install (or update) Android Studio from the
# archive you downloaded from developer.android.com, for the current user,
# with a command and an entry in the applications menu.
#
# Usage:
#   install-android-studio.sh [--file ARCHIVE] [--dir DIR] [--force] [--yes]
#   install-android-studio.sh --check
#   install-android-studio.sh --uninstall [--yes]
#
#   --file ARCHIVE  the android-studio-*-linux.tar.gz to install (default: the
#                   newest one in your Downloads folder)
#   --dir DIR       where to install it (default ~/.local/opt/android-studio)
#   --force         reinstall even if that build is already installed
#   --check         only report: what is installed, which archive would be
#                   used, KVM (the emulator), disk space
#   --yes           don't ask before installing or changing anything
#   --uninstall     remove Android Studio, its command and its menu entry
#
# What it does:
#   - unpacks the archive next to the install folder and checks it is Android
#     Studio, then swaps it in; the previous version is kept as DIR.old until
#     the next update (so a bad update can be undone by hand);
#   - ~/.local/bin/android-studio starts it;
#   - ~/.local/share/applications/android-studio.desktop is the menu entry;
#   - checks that the emulator can use KVM, and offers to add you to the kvm
#     group if you are not in it.
# Your settings (~/.config/Google, ~/.local/share/Google), projects and the
# Android SDK (~/Android/Sdk) are never touched, by installing or uninstalling.
# Nothing needs root, except adding you to the kvm group.

set -eu

SS_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; }

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
[ -n "$APP_DIR" ] || APP_DIR=$HOME/.local/opt/android-studio
case "$APP_DIR" in /*) ;; *) APP_DIR=$(pwd)/$APP_DIR ;; esac
APP_DIR=${APP_DIR%/}
BIN_LINK=$HOME/.local/bin/android-studio
DESKTOP_FILE=$DATA_HOME/applications/android-studio.desktop

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

# json_field FILE KEY - a top-level string value from product-info.json.
json_field() {
    sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -n 1
}

# describe DIR - "Android Studio 2026.2.2 (build ...)" for an installed copy.
describe() {
    _pi=$1/product-info.json
    [ -f "$_pi" ] || { printf 'unknown version\n'; return 0; }
    _dd=$(json_field "$_pi" dataDirectoryName)  # e.g. AndroidStudio2026.2.2
    _bn=$(json_field "$_pi" buildNumber)
    _v=${_dd#AndroidStudio}
    printf 'Android Studio %s (build %s)\n' "${_v:-?}" "${_bn:-?}"
}

refresh_menu() {
    have_cmd update-desktop-database && update-desktop-database "$DATA_HOME/applications" >/dev/null 2>&1 || true
}

# --- uninstall -----------------------------------------------------------------

if [ "$UNINSTALL" -eq 1 ]; then
    if [ ! -e "$APP_DIR" ] && [ ! -e "$APP_DIR.old" ] && [ ! -e "$DESKTOP_FILE" ] && [ ! -L "$BIN_LINK" ]; then
        ok "Android Studio is not installed in $APP_DIR"
        exit 0
    fi
    info "Removes: $APP_DIR (and $APP_DIR.old), $BIN_LINK, $DESKTOP_FILE"
    info "Kept: your settings (~/.config/Google, ~/.local/share/Google), projects and SDK (~/Android/Sdk)"
    confirm "Uninstall Android Studio?" || die "nothing changed"
    rm -rf "$APP_DIR" "$APP_DIR.old"
    [ -L "$BIN_LINK" ] && rm -f "$BIN_LINK"
    rm -f "$DESKTOP_FILE"
    refresh_menu
    ok "Android Studio removed"
    exit 0
fi

# --- the archive -----------------------------------------------------------------

DL=$(downloads_dir)
OTHERS=""
if [ -z "$ARCHIVE" ]; then
    # the newest android-studio-*-linux.tar.gz (browsers add " (1)" to repeats)
    for _f in "$DL"/android-studio-*linux*.tar.gz; do
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
    [ -n "$ARCHIVE" ] || die "no android-studio-*-linux.tar.gz in $DL: download it from https://developer.android.com/studio (Linux .tar.gz), or give --file"
fi
[ -f "$ARCHIVE" ] || die "$ARCHIVE: no such file"
case "$ARCHIVE" in *.tar.gz|*.tgz) ;; *) die "$ARCHIVE: expected the .tar.gz archive" ;; esac

# the same download more than once: say so, so the copies can be deleted
_report_others() {
    _size=$(wc -c < "$ARCHIVE" | tr -d ' ')
    printf '%s\n' "$OTHERS" | while IFS= read -r _o; do
        [ -n "$_o" ] || continue
        if [ "$(wc -c < "$_o" | tr -d ' ')" = "$_size" ] && cmp -s "$_o" "$ARCHIVE"; then
            info "  $_o is the same file again: you can delete it"
        else
            info "  also in Downloads: $_o (older, not used)"
        fi
    done
}

# --- report --------------------------------------------------------------------

info "Archive: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
[ -n "$OTHERS" ] && _report_others
if [ -d "$APP_DIR" ]; then
    INSTALLED=$(describe "$APP_DIR")
    info "Installed: $INSTALLED in $APP_DIR"
else
    INSTALLED=""
    info "Installed: not yet (it will go to $APP_DIR)"
fi

PARENT=$(dirname "$APP_DIR")
mkdir -p "$PARENT"
# room for the unpacked copy (about 2.2 times the archive) while the old one stays
# shellcheck disable=SC2017 # kB first, so the product cannot overflow
NEED_KB=$(( $(wc -c < "$ARCHIVE" | tr -d ' ') / 1024 * 22 / 10 ))
FREE_KB=$(df -Pk "$PARENT" | awk 'NR == 2 { print $4 }')
if [ "$FREE_KB" -lt "$NEED_KB" ]; then
    warn "only $((FREE_KB / 1024)) MB free in $PARENT; about $((NEED_KB / 1024)) MB are needed"
    [ "$CHECK_ONLY" -eq 1 ] || die "free some space first"
fi

# KVM: the emulator is unusably slow without it
KVM_OK=1
if [ ! -e /dev/kvm ]; then
    KVM_OK=0
    warn "no /dev/kvm: the emulator will be very slow (turn on virtualisation (VT-x / AMD-V) in the firmware settings)"
elif ! user_in_group "$(id -un)" kvm && [ ! -w /dev/kvm ]; then
    KVM_OK=0
    warn "you are not in the kvm group: the emulator cannot use hardware acceleration"
else
    info "KVM: available"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    exit 0
fi

# --- unpack, check, swap in --------------------------------------------------------

confirm "Install Android Studio from $(basename "$ARCHIVE") into $APP_DIR?" || die "nothing changed"
need_cmd tar gzip

STAGE=$(mktemp -d "$PARENT/.android-studio-new.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM
info "Unpacking (1-2 minutes)..."
tar -xzf "$ARCHIVE" -C "$STAGE" || die "the archive does not unpack: download it again"
NEW=$STAGE/android-studio
if [ ! -f "$NEW/product-info.json" ] || { [ ! -x "$NEW/bin/studio" ] && [ ! -x "$NEW/bin/studio.sh" ]; }; then
    die "$ARCHIVE does not contain Android Studio (no android-studio/bin/studio)"
fi
NEW_DESC=$(describe "$NEW")
NEW_BUILD=$(json_field "$NEW/product-info.json" buildNumber)

if [ -d "$APP_DIR" ] && [ "$FORCE" -eq 0 ] && [ -n "$NEW_BUILD" ] \
    && [ "$(json_field "$APP_DIR/product-info.json" buildNumber)" = "$NEW_BUILD" ]; then
    ok "$NEW_DESC is already installed (use --force to reinstall); the menu entry is refreshed"
else
    if [ -d "$APP_DIR" ]; then
        rm -rf "$APP_DIR.old"
        mv "$APP_DIR" "$APP_DIR.old"
        info "The previous version is kept as $APP_DIR.old until the next update"
    fi
    mv "$NEW" "$APP_DIR"
    ok "Installed $NEW_DESC in $APP_DIR"
fi
rm -rf "$STAGE"
trap - EXIT INT TERM

# --- the command and the menu entry ----------------------------------------------------

LAUNCHER=$APP_DIR/bin/studio
[ -x "$LAUNCHER" ] || LAUNCHER=$APP_DIR/bin/studio.sh
mkdir -p "$(dirname "$BIN_LINK")"
if [ -e "$BIN_LINK" ] && [ ! -L "$BIN_LINK" ]; then
    warn "$BIN_LINK exists and is not a link: left alone"
else
    ln -sfn "$LAUNCHER" "$BIN_LINK"
fi

ICON=$APP_DIR/bin/studio.svg
[ -f "$ICON" ] || ICON=$APP_DIR/bin/studio.png
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Android Studio
GenericName=Android IDE
Comment=The official IDE for Android app development
Exec="$LAUNCHER" %f
TryExec=$LAUNCHER
Icon=$ICON
Terminal=false
Categories=Development;IDE;
Keywords=android;sdk;ide;kotlin;java;emulator;
StartupWMClass=jetbrains-studio
StartupNotify=true
EOF
have_cmd desktop-file-validate && { desktop-file-validate "$DESKTOP_FILE" || warn "desktop-file-validate reported problems with $DESKTOP_FILE"; }
refresh_menu
ok "Menu entry: Android Studio (Development); command: android-studio"

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "$HOME/.local/bin is not on your PATH: the android-studio command needs it (the menu entry works anyway)" ;;
esac

# --- KVM group ----------------------------------------------------------------------------

if [ "$KVM_OK" -eq 0 ] && [ -e /dev/kvm ] && group_exists kvm; then
    if confirm "Add $(id -un) to the kvm group, so the emulator can use hardware acceleration (needs root)?"; then
        add_user_to_group "$(id -un)" kvm && ok "added to kvm: log out and back in for it to take effect"
    fi
fi

[ -n "$OTHERS" ] && info "Tip: the Downloads folder still has the archive(s) listed above."
info "Start it from the menu or with: android-studio  (the first start downloads the SDK)"
