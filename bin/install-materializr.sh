#!/bin/sh
#
# install-materializr.sh - get the latest Materializr source
# (https://github.com/materializr-cad/materializr), build it, and install it
# for the current user with an entry in the desktop's applications menu, on
# any Linux distribution. Run it again to update: it rebuilds only when there
# is something new.
#
# Usage:
#   install-materializr.sh [--check] [--yes] [--stable] [--force] [--jobs N]
#   install-materializr.sh --uninstall [--yes]
#
#   --check      only report what is installed and whether an update exists
#   --yes        don't ask before installing packages or building
#   --stable     build the latest published release instead of the newest
#                code on the main branch
#   --force      rebuild even if the installed build is already current
#   --jobs N     parallel build jobs (default: the number of CPUs)
#   --uninstall  remove Materializr, its menu entry and its build files
#
# Everything goes under your home folder; root is used only to install the
# build packages from the distro (apt, dnf/yum, zypper, pacman, apk):
#   ~/.local/src/materializr          the source (managed: local edits are discarded)
#   ~/.local/src/materializr-build-*  the build directory, kept for fast rebuilds
#   ~/.local/opt/occt-*               OpenCASCADE, built once from source at the
#                                     version the project pins in its Dockerfile
#   ~/.local/opt/materializr          the installed program and its fonts
#   ~/.local/bin/materializr          the command
#   ~/.local/share/applications/materializr.desktop  the menu entry
#
# The first build compiles OpenCASCADE: expect 30 minutes or more. Updates
# after that only rebuild Materializr itself.

set -eu

SS_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; }

REPO_URL=https://github.com/materializr-cad/materializr.git
REPO_API=https://api.github.com/repos/materializr-cad/materializr
# Used only if the project's Dockerfile no longer states the pin.
OCCT_TAG_DEFAULT=V7_9_3
OCCT_SHA256_DEFAULT=5ecf094ec6b12d5413dfb851d8c3590c354058aee556e32e408bdfbf8c357d57

CHECK_ONLY=0
ASSUME_YES=0
STABLE=0
FORCE=0
UNINSTALL=0
JOBS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --stable) STABLE=1 ;;
        --force) FORCE=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --jobs) [ $# -ge 2 ] || die "--jobs needs a number"; JOBS=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done
[ -z "$JOBS" ] && JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
printf '%s' "$JOBS" | grep -Eq '^[1-9][0-9]*$' || die "--jobs needs a positive number"

[ "$(id -u)" -ne 0 ] || die "run this as your normal user: it installs into your home folder"

SRC_DIR=$HOME/.local/src/materializr
OPT_DIR=$HOME/.local/opt
APP_DIR=$OPT_DIR/materializr
BIN_LINK=$HOME/.local/bin/materializr
DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
DESKTOP_FILE=$DATA_HOME/applications/materializr.desktop
ICON_THEME_DIR=$DATA_HOME/icons/hicolor
METAINFO_FILE=$DATA_HOME/metainfo/com.materializr.app.metainfo.xml
PM=$(pkg_manager)

TMP=""
cleanup() { [ -n "$TMP" ] && rm -r "$TMP" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- desktop integration -------------------------------------------------------

refresh_desktop_caches() {
    have_cmd update-desktop-database && update-desktop-database "$DATA_HOME/applications" >/dev/null 2>&1 || true
    have_cmd gtk-update-icon-cache && gtk-update-icon-cache -q -t "$ICON_THEME_DIR" >/dev/null 2>&1 || true
    have_cmd kbuildsycoca6 && kbuildsycoca6 >/dev/null 2>&1 || true
    have_cmd kbuildsycoca5 && kbuildsycoca5 >/dev/null 2>&1 || true
}

remove_desktop_entry() {
    rm -f "$DESKTOP_FILE" "$METAINFO_FILE"
    for _s in 64 128 256 512; do rm -f "$ICON_THEME_DIR/${_s}x${_s}/apps/materializr.png"; done
    refresh_desktop_caches
}

# --- uninstall ----------------------------------------------------------------------

if [ "$UNINSTALL" = 1 ]; then
    info "Removes: $APP_DIR, $BIN_LINK, the menu entry and icons,"
    info "         $SRC_DIR, its build directories and the OpenCASCADE builds in $OPT_DIR/occt-*"
    confirm "Uninstall Materializr?" || { info "Nothing changed."; exit 1; }
    rm -rf "$APP_DIR" "$APP_DIR.new" "$APP_DIR.prev" "$SRC_DIR"
    for _d in "$SRC_DIR"-build-* "$OPT_DIR"/occt-*; do [ -e "$_d" ] && rm -rf "$_d"; done
    [ -L "$BIN_LINK" ] || [ -f "$BIN_LINK" ] && rm -f "$BIN_LINK"
    remove_desktop_entry
    ok "Materializr uninstalled (the build packages from $PM stay installed)"
    exit 0
fi

# --- what to build ----------------------------------------------------------------------

need_cmd git

# The commit to build: the newest on main, or the latest release's tag.
if [ "$STABLE" = 1 ]; then
    have_cmd curl || die "--stable needs curl"
    TARGET_REF=$(curl -fsSL "$REPO_API/releases/latest" | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$TARGET_REF" ] || die "couldn't find the latest release on GitHub"
    TARGET_COMMIT=$(git ls-remote "$REPO_URL" "refs/tags/$TARGET_REF^{}" "refs/tags/$TARGET_REF" | awk 'NR==1 {print $1}')
else
    TARGET_REF=main
    TARGET_COMMIT=$(git ls-remote "$REPO_URL" refs/heads/main | awk '{print $1}')
fi
[ -n "$TARGET_COMMIT" ] || die "couldn't reach $REPO_URL"

INSTALLED_COMMIT=""
[ -r "$APP_DIR/VERSION" ] && INSTALLED_COMMIT=$(sed -n 's/^commit=//p' "$APP_DIR/VERSION")
INSTALLED_DESC=""
[ -r "$APP_DIR/VERSION" ] && INSTALLED_DESC=$(sed -n 's/^version=//p' "$APP_DIR/VERSION")

short() { printf '%s' "$1" | cut -c1-7; }

info "Materializr - distro: $(os_id) (like: $(os_like)), package manager: $PM"
if [ -n "$INSTALLED_COMMIT" ]; then
    info "installed: ${INSTALLED_DESC:-?} ($(short "$INSTALLED_COMMIT"))"
else
    info "installed: nothing yet"
fi
info "latest:    $TARGET_REF ($(short "$TARGET_COMMIT"))"

UP_TO_DATE=0
[ "$INSTALLED_COMMIT" = "$TARGET_COMMIT" ] && [ -x "$APP_DIR/bin/materializr" ] && UP_TO_DATE=1

# --- build dependencies ---------------------------------------------------------------------
# What OpenCASCADE and Materializr (with the SDL3 it builds itself, for X11
# and Wayland) need, per package manager: the list mirrors the project's
# Dockerfile, which is its reference Linux build.

packages() {
    case "$PM" in
        apt) echo "build-essential cmake git pkg-config curl ca-certificates libfreetype-dev libfontconfig1-dev libgl-dev libglu1-mesa-dev libegl-dev libx11-dev libxext-dev libxmu-dev libxt-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libxfixes-dev libxkbcommon-dev libwayland-dev libwayland-bin libdecor-0-dev libudev-dev libdbus-1-dev libcurl4-openssl-dev zlib1g-dev" ;;
        dnf|yum) echo "gcc gcc-c++ make cmake git pkgconf-pkg-config curl freetype-devel fontconfig-devel mesa-libGL-devel mesa-libGLU-devel mesa-libEGL-devel libX11-devel libXext-devel libXmu-devel libXt-devel libXrandr-devel libXinerama-devel libXcursor-devel libXi-devel libXfixes-devel libxkbcommon-devel wayland-devel libdecor-devel systemd-devel dbus-devel libcurl-devel zlib-devel" ;;
        zypper) echo "gcc gcc-c++ make cmake git pkg-config curl freetype2-devel fontconfig-devel Mesa-libGL-devel glu-devel Mesa-libEGL-devel libX11-devel libXext-devel libXmu-devel libXt-devel libXrandr-devel libXinerama-devel libXcursor-devel libXi-devel libXfixes-devel libxkbcommon-devel wayland-devel libdecor-devel systemd-devel dbus-1-devel libcurl-devel zlib-devel" ;;
        pacman) echo "base-devel cmake git pkgconf curl freetype2 fontconfig mesa glu libx11 libxext libxmu libxt libxrandr libxinerama libxcursor libxi libxfixes libxkbcommon wayland libdecor systemd-libs dbus zlib" ;;
        apk) echo "build-base cmake git pkgconf curl linux-headers freetype-dev fontconfig-dev mesa-dev glu-dev libx11-dev libxext-dev libxmu-dev libxt-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libxfixes-dev libxkbcommon-dev wayland-dev libdecor-dev eudev-dev dbus-dev curl-dev zlib-dev" ;;
        *) echo "" ;;
    esac
}

# Present if these commands and pkg-config modules are; the same check works
# on every distro, whatever its packages are called.
DEP_CMDS="git cmake make cc c++ pkg-config curl"
DEP_PC="gl glu egl x11 xext xmu xt xrandr xinerama xcursor xi xfixes xkbcommon wayland-client wayland-scanner freetype2 fontconfig libcurl zlib libudev dbus-1"
MISSING_DEPS=""
for _c in $DEP_CMDS; do have_cmd "$_c" || MISSING_DEPS="$MISSING_DEPS $_c"; done
if have_cmd pkg-config; then
    for _m in $DEP_PC; do pkg-config --exists "$_m" || MISSING_DEPS="$MISSING_DEPS $_m"; done
else
    MISSING_DEPS="$MISSING_DEPS (pkg-config modules)"
fi

if [ "$CHECK_ONLY" = 1 ]; then
    [ -z "$MISSING_DEPS" ] && ok "build dependencies present" || warn "missing build dependencies:$MISSING_DEPS"
    [ -f "$DESKTOP_FILE" ] && ok "menu entry: $DESKTOP_FILE" || warn "no menu entry"
    if [ "$UP_TO_DATE" = 1 ]; then ok "up to date"; exit 0; fi
    warn "an update is available (run without --check)"; exit 1
fi

if [ "$UP_TO_DATE" = 1 ] && [ "$FORCE" = 0 ]; then
    ok "already up to date"
    INSTALL_ONLY_DESKTOP=1
else
    INSTALL_ONLY_DESKTOP=0
fi

# --- plan -------------------------------------------------------------------------------------

if [ "$INSTALL_ONLY_DESKTOP" = 0 ]; then
    PKG_LIST=""
    if [ -n "$MISSING_DEPS" ]; then
        PKG_LIST=$(packages)
        [ -n "$PKG_LIST" ] || die "missing:$MISSING_DEPS - and no supported package manager to install them; install them by hand"
    fi
    info ""
    info "Planned:"
    [ -n "$PKG_LIST" ] && info "  install with $PM (as root), for:$MISSING_DEPS"
    info "  get $TARGET_REF ($(short "$TARGET_COMMIT")) into $SRC_DIR"
    info "  build OpenCASCADE at the project's pinned version if not built yet (30+ minutes, once)"
    info "  build Materializr with $JOBS jobs, install it into $APP_DIR, command $BIN_LINK"
    info "  add Materializr to the applications menu"
    info ""
    confirm "Go ahead?" || { info "Nothing changed."; exit 1; }
fi
# Scratch space for the OpenCASCADE build (several GB): under ~/.cache, not
# /tmp, which is often a small RAM disk.
mkdir -p "$HOME/.cache"
TMP=$(mktemp -d "$HOME/.cache/materializr-build.XXXXXX")

# --- packages -----------------------------------------------------------------------------------

if [ "$INSTALL_ONLY_DESKTOP" = 0 ] && [ -n "${PKG_LIST:-}" ]; then
    info ""; info "== Installing build packages"
    case "$PM" in
        apt) as_root apt-get update
             # shellcheck disable=SC2086
             as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y $PKG_LIST ;;
        apk) as_root apk update
             # shellcheck disable=SC2086
             pkg_install $PKG_LIST ;;
        *)   # shellcheck disable=SC2086
             pkg_install $PKG_LIST ;;
    esac
fi

if [ "$INSTALL_ONLY_DESKTOP" = 0 ]; then

# --- source -----------------------------------------------------------------------------------------

info ""; info "== Source"
mkdir -p "$(dirname "$SRC_DIR")"
if [ ! -d "$SRC_DIR/.git" ]; then
    git clone --quiet --filter=blob:none "$REPO_URL" "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch --quiet --tags --force origin main
[ "$STABLE" = 1 ] && git -C "$SRC_DIR" fetch --quiet origin "refs/tags/$TARGET_REF:refs/tags/$TARGET_REF"
# A managed checkout: always exactly the commit being built.
git -C "$SRC_DIR" checkout --quiet --force --detach "$TARGET_COMMIT"
git -C "$SRC_DIR" clean --quiet -fd
VERSION_DESC=$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null || short "$TARGET_COMMIT")
ok "source at $VERSION_DESC"

# --- OpenCASCADE ---------------------------------------------------------------------------------------
# The version the project builds its own release with, read from its
# Dockerfile, so a change of pin upstream is followed automatically.

OCCT_TAG=$(sed -n 's/^ARG OCCT_TAG=\([A-Za-z0-9_.]*\).*/\1/p' "$SRC_DIR/Dockerfile" 2>/dev/null | head -1)
OCCT_SHA256=$(sed -n 's/^ARG OCCT_SHA256=\([0-9a-f]\{64\}\).*/\1/p' "$SRC_DIR/Dockerfile" 2>/dev/null | head -1)
if [ -z "$OCCT_TAG" ] || [ -z "$OCCT_SHA256" ]; then
    warn "the Dockerfile doesn't state the OpenCASCADE pin any more; using $OCCT_TAG_DEFAULT"
    OCCT_TAG=$OCCT_TAG_DEFAULT; OCCT_SHA256=$OCCT_SHA256_DEFAULT
fi
OCCT_PREFIX=$OPT_DIR/occt-$OCCT_TAG
OCCT_CONFIG=$OCCT_PREFIX/lib/cmake/opencascade/OpenCASCADEConfig.cmake

if [ -f "$OCCT_CONFIG" ]; then
    ok "OpenCASCADE $OCCT_TAG already built ($OCCT_PREFIX)"
else
    info ""; info "== OpenCASCADE $OCCT_TAG (built once; this is the long part)"
    curl -fL --proto '=https' -o "$TMP/occt.tar.gz" \
        "https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/$OCCT_TAG.tar.gz"
    _sum=$(if have_cmd sha256sum; then sha256sum "$TMP/occt.tar.gz"; else shasum -a 256 "$TMP/occt.tar.gz"; fi | cut -d' ' -f1)
    [ "$_sum" = "$OCCT_SHA256" ] || die "OpenCASCADE's SHA-256 doesn't match the project's pin; nothing built"
    mkdir -p "$TMP/occt"
    tar -xzf "$TMP/occt.tar.gz" -C "$TMP/occt" --strip-components=1
    rm -f "$TMP/occt.tar.gz"
    # The same options as the project's Dockerfile.
    cmake -S "$TMP/occt" -B "$TMP/occt-build" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$OCCT_PREFIX" -DINSTALL_DIR_LIB=lib \
        -DINSTALL_DIR_CMAKE=lib/cmake/opencascade \
        -DBUILD_LIBRARY_TYPE=Shared \
        -DBUILD_MODULE_Draw=OFF -DBUILD_DOC_Overview=OFF -DBUILD_SAMPLES_QT=OFF \
        -DUSE_FREETYPE=ON -DUSE_TK=OFF -DUSE_TCL=OFF \
        -DUSE_FREEIMAGE=OFF -DUSE_TBB=OFF -DUSE_VTK=OFF -DUSE_RAPIDJSON=OFF \
        -DUSE_OPENVR=OFF -DUSE_DRACO=OFF -DUSE_FFMPEG=OFF >/dev/null
    cmake --build "$TMP/occt-build" --parallel "$JOBS"
    rm -rf "$OCCT_PREFIX"
    cmake --install "$TMP/occt-build" >/dev/null
    rm -rf "$TMP/occt" "$TMP/occt-build"
    [ -f "$OCCT_CONFIG" ] || die "OpenCASCADE installed, but $OCCT_CONFIG is missing"
    ok "OpenCASCADE $OCCT_TAG in $OCCT_PREFIX"
fi

# --- Materializr ------------------------------------------------------------------------------------------
# One build directory per OpenCASCADE version, so a new pin never mixes with
# a cached configuration; otherwise rebuilds are incremental.

BUILD_DIR=$SRC_DIR-build-$OCCT_TAG
info ""; info "== Building Materializr $VERSION_DESC"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF \
    -DMZR_OCCT_PREFIX="$OCCT_PREFIX" >/dev/null
cmake --build "$BUILD_DIR" --parallel "$JOBS"
[ -x "$BUILD_DIR/materializr" ] || die "the build finished without $BUILD_DIR/materializr"

# --- install ----------------------------------------------------------------------------------------------
# Into a new directory first, swapped in only when complete, so a failed
# update leaves the working install alone. The program finds its fonts at
# <exe>/../share/materializr/fonts/; shared libraries the build made itself
# (SDL3) are copied next to it, OpenCASCADE is used from its own prefix.

info ""; info "== Installing"
NEW=$APP_DIR.new
rm -rf "$NEW"
mkdir -p "$NEW/bin" "$NEW/lib" "$NEW/share/materializr/fonts"
cp "$BUILD_DIR/materializr" "$NEW/bin/materializr"
cp "$SRC_DIR"/assets/fonts/*.ttf "$NEW/share/materializr/fonts/"
[ -d "$SRC_DIR/assets/fonts/licenses" ] && cp -R "$SRC_DIR/assets/fonts/licenses" "$NEW/share/materializr/fonts/"
cp "$SRC_DIR/icon.png" "$NEW/share/materializr/icon.png"
cp "$SRC_DIR/LICENSE" "$NEW/share/materializr/LICENSE"
LD_LIBRARY_PATH="$OCCT_PREFIX/lib" ldd "$BUILD_DIR/materializr" | awk '/=> \// {print $3}' | while read -r _lib; do
    case "$_lib" in "$BUILD_DIR"/*) cp -L "$_lib" "$NEW/lib/" ;; esac
done
_missing=$(LD_LIBRARY_PATH="$NEW/lib:$OCCT_PREFIX/lib" ldd "$NEW/bin/materializr" | awk '/not found/ {print $1}' | tr '\n' ' ')
[ -z "$_missing" ] || die "the installed program can't find: $_missing"
printf 'commit=%s\nversion=%s\nref=%s\nocct=%s\n' "$TARGET_COMMIT" "$VERSION_DESC" "$TARGET_REF" "$OCCT_TAG" > "$NEW/VERSION"

rm -rf "$APP_DIR.prev"
[ -d "$APP_DIR" ] && mv "$APP_DIR" "$APP_DIR.prev"
mv "$NEW" "$APP_DIR"
rm -rf "$APP_DIR.prev"

# The command: a small launcher that points the program at its libraries.
mkdir -p "$(dirname "$BIN_LINK")"
rm -f "$BIN_LINK"
cat > "$BIN_LINK" <<EOF
#!/bin/sh
# Written by install-materializr.sh - run it again to update Materializr.
LD_LIBRARY_PATH="$APP_DIR/lib:$OCCT_PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
exec "$APP_DIR/bin/materializr" "\$@"
EOF
chmod 755 "$BIN_LINK"

# OpenCASCADE builds for pins no longer used (they are large).
for _d in "$OPT_DIR"/occt-*; do
    [ -d "$_d" ] && [ "$_d" != "$OCCT_PREFIX" ] && { rm -rf "$_d"; info "removed the unused $_d"; }
done
for _d in "$SRC_DIR"-build-*; do
    [ -d "$_d" ] && [ "$_d" != "$BUILD_DIR" ] && rm -rf "$_d"
done
ok "Materializr $VERSION_DESC installed in $APP_DIR"

fi  # INSTALL_ONLY_DESKTOP = 0

# --- applications menu --------------------------------------------------------------------------------------
# A user-level .desktop entry (freedesktop.org standard: GNOME, KDE, XFCE,
# Cinnamon, MATE, LXQt...). The icon goes into the hicolor theme at standard
# square sizes when an image tool can pad it to a square; otherwise the entry
# points at the PNG directly, which the standard also allows.

info ""; info "== Applications menu"
mkdir -p "$(dirname "$DESKTOP_FILE")"
ICON_VALUE=$APP_DIR/share/materializr/icon.png
_im=""
if have_cmd magick; then _im=magick; elif have_cmd convert; then _im=convert; fi
if [ -n "$_im" ]; then
    for _s in 64 128 256 512; do
        mkdir -p "$ICON_THEME_DIR/${_s}x${_s}/apps"
        "$_im" "$APP_DIR/share/materializr/icon.png" -background none -resize "${_s}x${_s}" \
            -gravity center -extent "${_s}x${_s}" "$ICON_THEME_DIR/${_s}x${_s}/apps/materializr.png"
    done
    ICON_VALUE=materializr
fi

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Materializr
GenericName=3D CAD
Comment=Open-source parametric 3D CAD
Exec=$BIN_LINK %F
TryExec=$BIN_LINK
Icon=$ICON_VALUE
Terminal=false
Categories=Graphics;3DGraphics;Engineering;
Keywords=CAD;3D;STL;STEP;sketch;model;
StartupWMClass=Materializr
StartupNotify=true
EOF
chmod 644 "$DESKTOP_FILE"
if [ -f "$SRC_DIR/com.materializr.app.metainfo.xml" ]; then
    mkdir -p "$(dirname "$METAINFO_FILE")"
    cp "$SRC_DIR/com.materializr.app.metainfo.xml" "$METAINFO_FILE"
fi
if have_cmd desktop-file-validate; then
    desktop-file-validate "$DESKTOP_FILE" || warn "desktop-file-validate reported problems with $DESKTOP_FILE"
fi
refresh_desktop_caches
ok "menu entry: $DESKTOP_FILE (icon: $ICON_VALUE)"

case ":$PATH:" in
    *":$(dirname "$BIN_LINK"):"*) ;;
    *) warn "$(dirname "$BIN_LINK") is not on PATH; start it from the menu or run $BIN_LINK" ;;
esac
info ""
ok "done - start Materializr from the applications menu or with: materializr"
exit 0
