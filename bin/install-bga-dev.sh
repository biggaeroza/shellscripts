#!/bin/sh
#
# install-bga-dev.sh - check for, and install, everything needed to build and
# test the BIG-G Aerospace projects (bga-tcd, bga-booster, bga-orbital,
# bga-comms, bga-lvsc, meridian-rtos, meridian-rtos-r, meridian-ada-spark,
# meridian-ide, meridian-ada-ide), on any Linux distribution.
#
# Usage:
#   install-bga-dev.sh [--check] [--yes] [--only LIST] [--skip LIST] [--arm-toolchain]
#
#   --check          report what is present and missing, change nothing
#                    (exit status 1 if anything is missing)
#   --yes            install without asking
#   --only LIST      comma-separated parts to handle (default: all of them):
#                      go       Go 1.26.8 or a Go that fetches it (all bga-*)
#                      gui      cgo, GTK 3, WebKitGTK 4.1 (the Wails *-gui programs)
#                      audio    libopus, libopusfile (bga-comms)
#                      c        AArch64 C/C++ cross-compiler, binutils, make
#                               (meridian-rtos, bga-lvsc flight code)
#                      rust     rustup, Rust 1.98.1, target
#                               aarch64-unknown-none-softfloat, llvm-tools,
#                               rustfmt, clippy (meridian-rtos-r, bga-lvsc)
#                      test     QEMU, gdb-multiarch, dosfstools, python3 (ktest.py)
#                      ide      Node.js >= 20, Yarn 1.22.22, clangd, native build
#                               libs (meridian-ide, meridian-ada-ide)
#                      ada      Alire, GNAT 16.1.0 for aarch64-elf, gprbuild
#                               26.0.1, GNATprove 16.1.0 (meridian-ada-spark)
#                      tcdtools Python venv with CoolProp and fonttools for
#                               bga-tcd's tools/ (regenerating data tables)
#                      serial   membership of the serial-port group (real boards)
#   --skip LIST      all parts except these
#   --arm-toolchain  use the Arm GNU Toolchain 15.3.rel1 (aarch64-none-elf) in
#                    ~/.meridian/toolchains instead of the distro's
#                    cross-compiler; automatic where the distro has none.
#
# Packages come from the distro's package manager; Rust, Yarn, Alire, the Ada
# toolchain, GNATprove and the Python venv are installed per user, without
# root. Every download is SHA-256 checked against a pinned hash. The Meridian
# parts match meridian-devsetup's install-deps.sh and MeridianIDE's
# toolchain-manifest.ts; change the pinned versions together.

set -eu

SS_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,41p' "$0" | sed 's/^# \{0,1\}//'; }

# --- pinned versions -----------------------------------------------------------

GO_VERSION=1.26.8          # the go line of the bga-* go.mod files
GO_MIN_AUTO=1.21           # oldest Go that can fetch a newer toolchain itself
RUST_VERSION=1.98.1
RUST_TARGET=aarch64-unknown-none-softfloat
RUSTUP_URL=https://static.rust-lang.org/rustup/archive/1.29.1/x86_64-unknown-linux-gnu/rustup-init
RUSTUP_SHA256=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
ARM_TC_VERSION=15.3.rel1
ARM_TC_FILE=arm-gnu-toolchain-$ARM_TC_VERSION-x86_64-aarch64-none-elf.tar.xz
ARM_TC_URL=https://gitlab.arm.com/api/v4/projects/tooling%2Fgnu-toolchains-for-arm/packages/generic/gnu-toolchain/$ARM_TC_VERSION/$ARM_TC_FILE
ARM_TC_SHA256=1b07847728d455f18895f1ebd5d71a40f2ccb7cb3a84ca9a874d7f961a318ce4
ARM_TC_DIR=$HOME/.meridian/toolchains/arm-gnu-toolchain-$ARM_TC_VERSION
YARN_VERSION=1.22.22
NODE_MIN_MAJOR=20
ALR_VERSION=2.1.1
ALR_URL=https://github.com/alire-project/alire/releases/download/v$ALR_VERSION/alr-$ALR_VERSION-bin-x86_64-linux.zip
ALR_SHA256=09c66bcd8c35dd4b97b72c3d9b76e44caa6964a2db35aba069f396f00f1f64c7
GNAT_VERSION=16.1.0
GPRBUILD_VERSION=26.0.1
ALIRE_TOOLCHAINS=$HOME/.local/share/alire/toolchains
GNATPROVE_VERSION=16.1.0
GNATPROVE_FILE=gnatprove-x86_64-linux-$GNATPROVE_VERSION-1.tar.gz
GNATPROVE_URL=https://github.com/alire-project/GNAT-FSF-builds/releases/download/gnatprove-$GNATPROVE_VERSION-1/$GNATPROVE_FILE
GNATPROVE_SHA256=82528bef29857e239373fcc36732837d743f5a00805d502c70455422ffc97191
GNATPROVE_DIR=$HOME/.local/share/gnatprove-$GNATPROVE_VERSION
TCD_VENV=$HOME/.venvs/bga-tcd-tools
TCD_REQS="CoolProp==8.0.0 fonttools==4.68.0"   # bga-tcd/tools/requirements.txt
LOCAL_BIN=$HOME/.local/bin

# --- options ------------------------------------------------------------------

ALL_PARTS=go,gui,audio,c,rust,test,ide,ada,tcdtools,serial
CHECK_ONLY=0
ASSUME_YES=0
ONLY=$ALL_PARTS
SKIP=""
ARM_TC=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --only) [ $# -ge 2 ] || die "--only needs a list"; ONLY=$2; shift ;;
        --only=*) ONLY=${1#--only=} ;;
        --skip) [ $# -ge 2 ] || die "--skip needs a list"; SKIP=$2; shift ;;
        --skip=*) SKIP=${1#--skip=} ;;
        --arm-toolchain) ARM_TC=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

for _p in $(printf '%s,%s' "$ONLY" "$SKIP" | tr ',' ' '); do
    case ",$ALL_PARTS," in *",$_p,"*) ;; *) die "unknown part: $_p (see --help)" ;; esac
done
want() {
    case ",$SKIP," in *",$1,"*) return 1 ;; esac
    case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

PM=$(pkg_manager)
ARCH=$(uname -m)
USE_ARM=$ARM_TC

# --- small helpers -------------------------------------------------------------

# A command that may live in an sbin directory not on a normal user's PATH.
have_sbin() { have_cmd "$1" || [ -x "/usr/sbin/$1" ] || [ -x "/sbin/$1" ]; }

on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

download() { # URL FILE
    if have_cmd curl; then curl -fL --proto '=https' -o "$2" "$1"
    elif have_cmd wget; then wget -O "$2" "$1"
    else warn "need curl or wget to download $1"; return 1; fi
}

sha256_of() {
    if have_cmd sha256sum; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch_checked URL FILE SHA256 - download and verify; removes FILE on mismatch.
fetch_checked() {
    download "$1" "$2" || return 1
    if [ "$(sha256_of "$2")" != "$3" ]; then
        warn "SHA-256 of $(basename "$2") doesn't match the pinned one; not used"
        rm -f "$2"; return 1
    fi
}

# ver_ge A B - true if dotted version A >= B.
ver_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, "."); if (m > n) n = m
        for (i = 1; i <= n; i++) {
            if (x[i] + 0 > y[i] + 0) exit 0
            if (x[i] + 0 < y[i] + 0) exit 1
        }
        exit 0 }'
}

go_version() { go version 2>/dev/null | sed -n 's/^go version go\([0-9.]*\).*/\1/p'; }

# A gdb that can debug AArch64: `set architecture aarch64` only works in
# gdbs built with that target (gdb-multiarch, Arch's and Fedora's gdb, cross gdbs).
gdb_knows_aarch64() {
    "$1" -batch -nx -ex 'set architecture aarch64' 2>&1 | grep -q 'set to "aarch64"'
}

node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }

# The group that owns serial ports: dialout on most distros, uucp on Arch.
serial_group() {
    for _g in dialout uucp; do
        group_exists "$_g" && { echo "$_g"; return 0; }
    done
    return 1
}

alr_path() {
    command -v alr 2>/dev/null || { [ -x "$LOCAL_BIN/alr" ] && echo "$LOCAL_BIN/alr"; } || true
}
rustup_path() {
    command -v rustup 2>/dev/null || { [ -x "$HOME/.cargo/bin/rustup" ] && echo "$HOME/.cargo/bin/rustup"; } || true
}
# first_match GLOB - the first existing path the glob expands to.
first_match() {
    for _m in $1; do [ -e "$_m" ] && { echo "$_m"; return 0; }; done
    return 1
}

# --- checks ------------------------------------------------------------------------

MISSING=0
PKGS=""           # distro packages to install
MANUAL=""         # missing things the distro has no package for
TODO_GO=0
TODO_RUST=0
TODO_YARN=0
TODO_ARM=0
TODO_GDBLINK=0
TODO_ALR=0
TODO_GNAT=0
TODO_PROVE=0
TODO_VENV=0
TODO_GROUP=""

report() { # ok|missing LABEL [NOTE]
    if [ "$1" = ok ]; then ok "$2${3:+ - $3}"
    else MISSING=1; printf '%s[missing]%s %s%s\n' "$SS_C_RED" "$SS_C_OFF" "$2" "${3:+ - $3}" >&2; fi
}

# add_pkg LABEL APT DNF PACMAN ZYPPER APK - queue the package for LABEL; a
# "-" for this distro puts LABEL on the manual list instead.
add_pkg() {
    _label=$1; shift
    if _n=$(pkg_name "$@"); then
        case " $PKGS " in *" $_n "*) ;; *) PKGS="$PKGS $_n" ;; esac
    else
        MANUAL="$MANUAL $_label"
    fi
}

# cmd_or_pkg CMD APT DNF PACMAN ZYPPER APK [NOTE] - report CMD, queue its
# package if missing.
cmd_or_pkg() {
    if have_cmd "$1"; then report ok "$1"
    else report missing "$1" "${7:-}"; add_pkg "$1" "$2" "$3" "$4" "$5" "$6"; fi
}

# lib_or_pkg PCNAME LABEL APT DNF PACMAN ZYPPER APK - a library, by its
# pkg-config name.
lib_or_pkg() {
    if have_cmd pkg-config && pkg-config --exists "$1"; then
        report ok "$2" "$(pkg-config --modversion "$1")"
    else
        report missing "$2"; add_pkg "$2" "$3" "$4" "$5" "$6" "$7"
    fi
}

check_go() {
    info ""; info "== Go (bga-tcd, bga-booster, bga-orbital, bga-comms, bga-lvsc)"
    if ! have_cmd go; then
        report missing go "the distro's Go, which then fetches $GO_VERSION itself"
        add_pkg go golang-go golang go go go; TODO_GO=1; return 0
    fi
    _v=$(go_version)
    if ver_ge "$_v" "$GO_VERSION"; then
        report ok go "$_v"
    elif ! ver_ge "$_v" "$GO_MIN_AUTO"; then
        report missing "go >= $GO_MIN_AUTO" "found $_v, too old to fetch $GO_VERSION; install a newer Go from go.dev and re-run"
        MANUAL="$MANUAL go"
    elif [ "$(go env GOTOOLCHAIN 2>/dev/null)" = local ]; then
        report missing "go $GO_VERSION" "found $_v with GOTOOLCHAIN=local; will set GOTOOLCHAIN=auto (per user) so it fetches $GO_VERSION"
        TODO_GO=1
    else
        report ok go "$_v; fetches $GO_VERSION on first build (GOTOOLCHAIN=$(go env GOTOOLCHAIN))"
    fi
}

check_gui() {
    info ""; info "== Desktop windows (Wails: tcd-gui, booster-gui, orb-gui, mseq-gui, bgacomms-desktop)"
    cmd_or_pkg cc build-essential gcc base-devel gcc build-base "C compiler for cgo"
    cmd_or_pkg pkg-config pkg-config pkgconf-pkg-config pkgconf pkg-config pkgconf
    lib_or_pkg gtk+-3.0 "GTK 3 (dev files)" libgtk-3-dev gtk3-devel gtk3 gtk3-devel gtk+3.0-dev
    lib_or_pkg webkit2gtk-4.1 "WebKitGTK 4.1 (dev files)" libwebkit2gtk-4.1-dev webkit2gtk4.1-devel webkit2gtk-4.1 webkit2gtk3-devel webkit2gtk-4.1-dev
}

check_audio() {
    info ""; info "== Audio (bga-comms)"
    lib_or_pkg opus "libopus (dev files)" libopus-dev opus-devel opus libopus-devel opus-dev
    lib_or_pkg opusfile "libopusfile (dev files)" libopusfile-dev opusfile-devel opusfile opusfile-devel opusfile-dev
}

check_c() {
    info ""; info "== AArch64 C cross-compiler (meridian-rtos, bga-lvsc flight code)"
    cmd_or_pkg make make make make make make
    if [ "$USE_ARM" = 1 ]; then
        if [ -x "$ARM_TC_DIR/bin/aarch64-none-elf-gcc" ]; then
            report ok "Arm GNU Toolchain $ARM_TC_VERSION" "make CROSS=$ARM_TC_DIR/bin/aarch64-none-elf-"
        else
            report missing "Arm GNU Toolchain $ARM_TC_VERSION" "goes to $ARM_TC_DIR"
            TODO_ARM=1
        fi
        return 0
    fi
    cmd_or_pkg aarch64-linux-gnu-gcc gcc-aarch64-linux-gnu gcc-aarch64-linux-gnu aarch64-linux-gnu-gcc - -
    cmd_or_pkg aarch64-linux-gnu-g++ g++-aarch64-linux-gnu gcc-c++-aarch64-linux-gnu aarch64-linux-gnu-gcc - -
    cmd_or_pkg aarch64-linux-gnu-objdump binutils-aarch64-linux-gnu binutils-aarch64-linux-gnu aarch64-linux-gnu-binutils - -
}

check_rust() {
    info ""; info "== Rust (meridian-rtos-r, bga-lvsc flight executor)"
    _rustup=$(rustup_path)
    if [ -z "$_rustup" ]; then
        if have_cmd rustc; then
            report missing rustup "rustc $(rustc -V | cut -d' ' -f2) is installed without rustup, which can't add the kernel's target; rustup goes next to it in ~/.cargo"
        else
            report missing rustup "installs Rust $RUST_VERSION into ~/.rustup and ~/.cargo"
        fi
        TODO_RUST=1; return 0
    fi
    report ok rustup "$("$_rustup" --version 2>/dev/null | head -n 1)"
    if "$_rustup" target list --installed 2>/dev/null | grep -qx "$RUST_TARGET"; then
        report ok "target $RUST_TARGET"
    else
        report missing "target $RUST_TARGET"; TODO_RUST=1
    fi
    for _comp in llvm-tools rustfmt clippy; do
        if "$_rustup" component list --installed 2>/dev/null | grep -q "^$_comp"; then
            report ok "component $_comp"
        else
            report missing "component $_comp"; TODO_RUST=1
        fi
    done
}

check_test() {
    info ""; info "== Kernel tests (scripts/ktest.py)"
    cmd_or_pkg qemu-system-aarch64 qemu-system-arm qemu-system-aarch64 qemu-system-aarch64 qemu-arm qemu-system-aarch64
    cmd_or_pkg python3 python3 python3 python python3 python3
    for _c in mkfs.vfat fsck.vfat; do
        if have_sbin "$_c"; then report ok "$_c"
        else report missing "$_c" dosfstools; add_pkg dosfstools dosfstools dosfstools dosfstools dosfstools dosfstools; fi
    done
    if have_cmd gdb-multiarch; then
        report ok gdb-multiarch
    else
        report missing gdb-multiarch "ktest.py calls it by that name"
        have_cmd gdb || add_pkg gdb gdb-multiarch gdb gdb gdb gdb-multiarch
        TODO_GDBLINK=1
    fi
}

check_ide() {
    info ""; info "== MeridianIDE and the Ada IDE"
    if have_cmd node; then
        _m=$(node_major)
        if [ "$_m" -ge "$NODE_MIN_MAJOR" ]; then report ok node "$(node --version)"
        else report missing "node >= $NODE_MIN_MAJOR" "found $(node --version); install a newer one (e.g. from nodejs.org) and re-run"; MANUAL="$MANUAL node"; fi
    else
        report missing node; add_pkg node nodejs nodejs nodejs nodejs-default nodejs
    fi
    have_cmd npm || have_cmd corepack || add_pkg npm npm npm npm npm-default npm
    if have_cmd yarn && [ "$(yarn --version 2>/dev/null)" = "$YARN_VERSION" ]; then
        report ok "yarn $YARN_VERSION"
    else
        report missing "yarn $YARN_VERSION" "into $LOCAL_BIN, via corepack or npm"; TODO_YARN=1
    fi
    cmd_or_pkg git git git git git git
    cmd_or_pkg clangd clangd clang-tools-extra clang clang-tools clang-extra-tools
    cmd_or_pkg make make make make make make
    cmd_or_pkg c++ build-essential gcc-c++ base-devel gcc-c++ build-base
    cmd_or_pkg pkg-config pkg-config pkgconf-pkg-config pkgconf pkg-config pkgconf
    lib_or_pkg libsecret-1 "libsecret (dev files)" libsecret-1-dev libsecret-devel libsecret libsecret-devel libsecret-dev
    lib_or_pkg xkbfile "libxkbfile (dev files)" libxkbfile-dev libxkbfile-devel libxkbfile libxkbfile-devel libxkbfile-dev
}

check_ada() {
    info ""; info "== Ada/SPARK (meridian-ada-spark)"
    if [ "$ARCH" != x86_64 ]; then
        report missing "Ada toolchain" "the pinned GNATprove and Alire builds here are for x86_64 hosts; install them by hand"
        MANUAL="$MANUAL ada"; return 0
    fi
    _alr=$(alr_path)
    if [ -n "$_alr" ]; then report ok alr "$("$_alr" --version 2>/dev/null | head -n 1)"
    else
        report missing "alr (Alire) $ALR_VERSION" "into $LOCAL_BIN"; TODO_ALR=1
        have_cmd unzip || add_pkg unzip unzip unzip unzip unzip unzip
    fi
    if _d=$(first_match "$ALIRE_TOOLCHAINS/gnat_aarch64_elf_${GNAT_VERSION}_*/bin/aarch64-elf-gcc"); then
        report ok "GNAT $GNAT_VERSION (aarch64-elf)" "$(dirname "$_d")"
    else
        report missing "GNAT $GNAT_VERSION (aarch64-elf)" "via alr, into $ALIRE_TOOLCHAINS"; TODO_GNAT=1
    fi
    if _d=$(first_match "$ALIRE_TOOLCHAINS/gprbuild_${GPRBUILD_VERSION}_*/bin/gprbuild"); then
        report ok "gprbuild $GPRBUILD_VERSION" "$(dirname "$_d")"
    else
        report missing "gprbuild $GPRBUILD_VERSION" "via alr, into $ALIRE_TOOLCHAINS"; TODO_GNAT=1
    fi
    if [ -x "$GNATPROVE_DIR/${GNATPROVE_FILE%.tar.gz}/bin/gnatprove" ]; then
        report ok "GNATprove $GNATPROVE_VERSION" "$GNATPROVE_DIR"
    else
        report missing "GNATprove $GNATPROVE_VERSION" "into $GNATPROVE_DIR"; TODO_PROVE=1
    fi
}

check_tcdtools() {
    info ""; info "== bga-tcd data-table tools (Python)"
    if [ -x "$TCD_VENV/bin/python" ] && "$TCD_VENV/bin/python" -c 'import CoolProp, fontTools' 2>/dev/null; then
        report ok "venv $TCD_VENV" "CoolProp, fonttools; run the tools with $TCD_VENV/bin/python"
        return 0
    fi
    report missing "venv $TCD_VENV" "with $TCD_REQS"
    TODO_VENV=1
    if ! have_cmd python3; then
        add_pkg python3 python3-venv python3 python python3 python3
    elif ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
        add_pkg python3-venv python3-venv python3 python python3 python3
    fi
}

check_serial() {
    info ""; info "== Serial port access (real board on /dev/ttyUSB*)"
    if _g=$(serial_group); then
        if user_in_group "$(id -un)" "$_g"; then report ok "member of group $_g"
        else report missing "member of group $_g" "only needed for a real board; QEMU works without it"; TODO_GROUP=$_g; fi
    else
        warn "no dialout or uucp group on this system; check which group owns /dev/ttyUSB0"
    fi
}

# No aarch64-linux-gnu package on this distro (openSUSE, Alpine): use the Arm
# GNU Toolchain instead.
if [ "$USE_ARM" = 0 ] && ! pkg_name gcc-aarch64-linux-gnu gcc-aarch64-linux-gnu aarch64-linux-gnu-gcc - - >/dev/null; then
    USE_ARM=1
fi

info "BIG-G Aerospace dev dependencies - distro: $(os_id) (like: $(os_like)), package manager: $PM, arch: $ARCH"
want go && check_go
want gui && check_gui
want audio && check_audio
want c && check_c
want rust && check_rust
want test && check_test
want ide && check_ide
want ada && check_ada
want tcdtools && check_tcdtools
want serial && check_serial
info ""

if [ "$MISSING" = 0 ]; then ok "everything is installed"; exit 0; fi
[ "$CHECK_ONLY" = 1 ] && exit 1

# --- plan --------------------------------------------------------------------------

if [ -n "$PKGS" ] && [ "$PM" = none ]; then
    warn "no supported package manager found; install these by hand:$PKGS"
    PKGS=""
fi

info "Planned:"
[ -n "$PKGS" ] && info "  install with $PM (as root):$PKGS"
[ "$TODO_GO" = 1 ] && info "  let Go fetch $GO_VERSION (go env -w GOTOOLCHAIN=auto, per user) and download it now"
[ "$TODO_ARM" = 1 ] && info "  download the Arm GNU Toolchain $ARM_TC_VERSION (~100 MB) to $ARM_TC_DIR"
[ "$TODO_RUST" = 1 ] && info "  install/complete Rust: rustup, target $RUST_TARGET, llvm-tools, rustfmt, clippy (per user)"
[ "$TODO_YARN" = 1 ] && info "  install Yarn $YARN_VERSION into $LOCAL_BIN (per user)"
[ "$TODO_GDBLINK" = 1 ] && info "  link $LOCAL_BIN/gdb-multiarch to an AArch64-capable gdb if the distro has none by that name"
[ "$TODO_ALR" = 1 ] && info "  install Alire $ALR_VERSION as $LOCAL_BIN/alr"
[ "$TODO_GNAT" = 1 ] && info "  alr toolchain --select gnat_aarch64_elf=$GNAT_VERSION gprbuild=$GPRBUILD_VERSION (~300 MB, per user)"
[ "$TODO_PROVE" = 1 ] && info "  download GNATprove $GNATPROVE_VERSION (~250 MB) to $GNATPROVE_DIR"
[ "$TODO_VENV" = 1 ] && info "  create the venv $TCD_VENV with $TCD_REQS"
[ -n "$TODO_GROUP" ] && info "  add $(id -un) to group $TODO_GROUP (as root; takes effect at next login)"
[ -n "$MANUAL" ] && warn "no package on this distro for:$MANUAL - install by hand"
info ""
confirm "Go ahead?" || { info "Nothing changed."; exit 1; }

FAILED=""

# --- distro packages -------------------------------------------------------------

if [ -n "$PKGS" ]; then
    case "$PM" in
        apt) as_root apt-get update ;;
        apk) as_root apk update ;;
    esac
    # One call first; if a single name has no candidate the whole call fails,
    # so then retry one by one and report only the ones that really fail.
    # shellcheck disable=SC2086
    if ! pkg_install $PKGS; then
        warn "installing everything at once failed; retrying one package at a time"
        for _p in $PKGS; do pkg_install "$_p" || FAILED="$FAILED $_p"; done
    fi
fi

# --- Go --------------------------------------------------------------------------------

if [ "$TODO_GO" = 1 ]; then
    if ! have_cmd go; then
        FAILED="$FAILED go"
    else
        _v=$(go_version)
        if ! ver_ge "$_v" "$GO_VERSION"; then
            if ! ver_ge "$_v" "$GO_MIN_AUTO"; then
                warn "Go $_v is too old to fetch $GO_VERSION; install a newer Go from go.dev"
                FAILED="$FAILED go"
            else
                [ "$(go env GOTOOLCHAIN 2>/dev/null)" = local ] && go env -w GOTOOLCHAIN=auto
                if GOTOOLCHAIN=go$GO_VERSION go version >/dev/null; then
                    ok "Go $GO_VERSION downloaded; Go switches to it in the bga-* repos"
                else
                    warn "couldn't download Go $GO_VERSION"; FAILED="$FAILED go"
                fi
            fi
        else
            ok "go $_v"
        fi
    fi
fi

# --- Arm GNU Toolchain -------------------------------------------------------------

if [ "$TODO_ARM" = 1 ]; then
    if [ "$ARCH" != x86_64 ]; then
        warn "the pinned Arm GNU Toolchain is for x86_64 hosts; install an aarch64-none-elf or aarch64-linux-gnu gcc by hand"
        FAILED="$FAILED arm-gnu-toolchain"
    else
        _tmp=$(mktemp -d)
        info "Downloading $ARM_TC_FILE ..."
        if fetch_checked "$ARM_TC_URL" "$_tmp/$ARM_TC_FILE" "$ARM_TC_SHA256"; then
            mkdir -p "$(dirname "$ARM_TC_DIR")"
            tar -xJf "$_tmp/$ARM_TC_FILE" -C "$_tmp"
            mv "$_tmp/${ARM_TC_FILE%.tar.xz}" "$ARM_TC_DIR"
            ok "Arm GNU Toolchain in $ARM_TC_DIR - build with make CROSS=$ARM_TC_DIR/bin/aarch64-none-elf-"
        else
            FAILED="$FAILED arm-gnu-toolchain"
        fi
        rm -r "$_tmp" 2>/dev/null || true
    fi
fi

# --- Rust ------------------------------------------------------------------------------

if [ "$TODO_RUST" = 1 ]; then
    RUSTUP=$(rustup_path)
    if [ -z "$RUSTUP" ]; then
        _libc=gnu
        { ldd --version 2>&1 || true; } | grep -qi musl && _libc=musl
        _triple=$ARCH-unknown-linux-$_libc
        _tmp=$(mktemp -d)
        if [ "$_triple" = x86_64-unknown-linux-gnu ]; then
            _url=$RUSTUP_URL; _sum=$RUSTUP_SHA256
        else
            _url=https://static.rust-lang.org/rustup/dist/$_triple/rustup-init
            if download "$_url.sha256" "$_tmp/sum"; then _sum=$(cut -d' ' -f1 "$_tmp/sum"); else _sum=none; fi
        fi
        info "Downloading rustup-init for $_triple ..."
        if fetch_checked "$_url" "$_tmp/rustup-init" "$_sum"; then
            chmod +x "$_tmp/rustup-init"
            "$_tmp/rustup-init" -y --profile minimal --default-toolchain "$RUST_VERSION" \
                --target "$RUST_TARGET" --component llvm-tools,rustfmt,clippy \
                && RUSTUP=$HOME/.cargo/bin/rustup
        fi
        rm -r "$_tmp" 2>/dev/null || true
    fi
    if [ -n "$RUSTUP" ]; then
        # Add to the default toolchain: the kernels have no rust-toolchain file.
        if "$RUSTUP" target add "$RUST_TARGET" && "$RUSTUP" component add llvm-tools rustfmt clippy; then
            ok "Rust ready ($("$(dirname "$RUSTUP")/rustc" -V 2>/dev/null))"
        else
            FAILED="$FAILED rust"
        fi
    else
        FAILED="$FAILED rust"
    fi
fi

# --- Yarn --------------------------------------------------------------------------------

if [ "$TODO_YARN" = 1 ]; then
    mkdir -p "$LOCAL_BIN"
    if have_cmd corepack && corepack enable --install-directory "$LOCAL_BIN" \
        && PATH=$LOCAL_BIN:$PATH corepack prepare "yarn@$YARN_VERSION" --activate; then
        ok "Yarn $YARN_VERSION via corepack in $LOCAL_BIN"
    elif have_cmd npm && npm install -g --prefix "$HOME/.local" "yarn@$YARN_VERSION"; then
        ok "Yarn $YARN_VERSION via npm in $LOCAL_BIN"
    else
        warn "couldn't install Yarn (no corepack, no npm)"; FAILED="$FAILED yarn"
    fi
fi

# --- gdb-multiarch name ------------------------------------------------------------------

if [ "$TODO_GDBLINK" = 1 ] && ! have_cmd gdb-multiarch; then
    _linked=0
    for _g in gdb aarch64-linux-gnu-gdb "$ARM_TC_DIR/bin/aarch64-none-elf-gdb"; do
        _gp=$(command -v "$_g" 2>/dev/null) || continue
        if gdb_knows_aarch64 "$_gp"; then
            mkdir -p "$LOCAL_BIN"
            ln -sf "$_gp" "$LOCAL_BIN/gdb-multiarch"
            ok "$LOCAL_BIN/gdb-multiarch -> $_gp"
            _linked=1; break
        fi
    done
    [ "$_linked" = 1 ] || { warn "no AArch64-capable gdb found to use as gdb-multiarch"; FAILED="$FAILED gdb-multiarch"; }
fi

# --- Alire and the Ada toolchain -----------------------------------------------------------

if [ "$TODO_ALR" = 1 ]; then
    _tmp=$(mktemp -d)
    info "Downloading Alire $ALR_VERSION ..."
    if fetch_checked "$ALR_URL" "$_tmp/alr.zip" "$ALR_SHA256" && unzip -q "$_tmp/alr.zip" bin/alr -d "$_tmp"; then
        mkdir -p "$LOCAL_BIN"
        mv "$_tmp/bin/alr" "$LOCAL_BIN/alr"
        chmod +x "$LOCAL_BIN/alr"
        ok "Alire $ALR_VERSION in $LOCAL_BIN/alr"
    else
        FAILED="$FAILED alire"
    fi
    rm -r "$_tmp" 2>/dev/null || true
fi

if [ "$TODO_GNAT" = 1 ]; then
    _alr=$(alr_path)
    if [ -z "$_alr" ]; then
        FAILED="$FAILED gnat"
    elif "$_alr" -n toolchain --select "gnat_aarch64_elf=$GNAT_VERSION" "gprbuild=$GPRBUILD_VERSION"; then
        ok "GNAT $GNAT_VERSION (aarch64-elf) and gprbuild $GPRBUILD_VERSION in $ALIRE_TOOLCHAINS"
    else
        FAILED="$FAILED gnat"
    fi
fi

if [ "$TODO_PROVE" = 1 ]; then
    _tmp=$(mktemp -d)
    info "Downloading $GNATPROVE_FILE ..."
    if fetch_checked "$GNATPROVE_URL" "$_tmp/$GNATPROVE_FILE" "$GNATPROVE_SHA256"; then
        mkdir -p "$GNATPROVE_DIR"
        tar -xzf "$_tmp/$GNATPROVE_FILE" -C "$GNATPROVE_DIR"
        ok "GNATprove $GNATPROVE_VERSION in $GNATPROVE_DIR"
    else
        FAILED="$FAILED gnatprove"
    fi
    rm -r "$_tmp" 2>/dev/null || true
fi

# --- bga-tcd tools venv ---------------------------------------------------------------------

if [ "$TODO_VENV" = 1 ]; then
    mkdir -p "$(dirname "$TCD_VENV")"
    # shellcheck disable=SC2086
    if python3 -m venv "$TCD_VENV" && "$TCD_VENV/bin/python" -m pip install --upgrade pip \
        && "$TCD_VENV/bin/python" -m pip install $TCD_REQS; then
        ok "venv $TCD_VENV - run bga-tcd's tools with $TCD_VENV/bin/python tools/NAME.py"
    else
        FAILED="$FAILED tcd-venv"
    fi
fi

# --- serial group ---------------------------------------------------------------------------

if [ -n "$TODO_GROUP" ]; then
    _u=$(id -un)
    if add_user_to_group "$_u" "$TODO_GROUP"; then
        ok "added $_u to $TODO_GROUP - log out and back in for it to apply"
    else
        FAILED="$FAILED group-$TODO_GROUP"
    fi
fi

# --- summary ------------------------------------------------------------------------------------

info ""
on_path "$LOCAL_BIN" || warn "$LOCAL_BIN is not on PATH; add it (e.g. in ~/.profile) to use yarn, alr and gdb-multiarch"
[ "$TODO_RUST" = 1 ] && ! on_path "$HOME/.cargo/bin" && warn "open a new shell (or: . \"\$HOME/.cargo/env\") to get cargo on PATH"
if [ -n "$FAILED" ] || [ -n "$MANUAL" ]; then
    warn "not installed:$FAILED$MANUAL (see the output above)"
    exit 1
fi
ok "done - re-run with --check to verify"
