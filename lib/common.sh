# shellcheck shell=sh
#
# lib/common.sh - shared helpers for the scripts in bin/.
#
# POSIX sh only (no bash-isms), so it runs under dash, busybox ash and bash
# alike. Source it from a script with:
#
#   . "$(dirname "$0")/../lib/common.sh"
#
# Everything here is a function or a variable prefixed with SS_; sourcing it
# has no side effects beyond defining them.

# --- output ----------------------------------------------------------------

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    SS_C_RED=$(printf '\033[31m'); SS_C_YEL=$(printf '\033[33m')
    SS_C_GRN=$(printf '\033[32m'); SS_C_OFF=$(printf '\033[0m')
else
    SS_C_RED=""; SS_C_YEL=""; SS_C_GRN=""; SS_C_OFF=""
fi

info() { printf '%s\n' "$*" >&2; }
ok()   { printf '%s[ok]%s %s\n' "$SS_C_GRN" "$SS_C_OFF" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$SS_C_YEL" "$SS_C_OFF" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$SS_C_RED" "$SS_C_OFF" "$*" >&2; exit 1; }

# --- environment -----------------------------------------------------------

# have_cmd NAME - true if NAME is on PATH.
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# need_cmd NAME... - exit with an error naming every missing command.
need_cmd() {
    _missing=""
    for _c in "$@"; do
        have_cmd "$_c" || _missing="$_missing $_c"
    done
    [ -z "$_missing" ] || die "missing required command(s):$_missing"
}

# os_id - prints the distro id from /etc/os-release (e.g. ubuntu, fedora,
# arch, alpine, opensuse-tumbleweed), or "unknown".
os_id() {
    if [ -r /etc/os-release ]; then
        ( . /etc/os-release && printf '%s\n' "${ID:-unknown}" )
    else
        printf 'unknown\n'
    fi
}

# os_like - prints ID_LIKE from /etc/os-release (e.g. "ubuntu debian"),
# falling back to the id itself. Derivatives (AnduinOS, Mint, Manjaro...)
# are recognised through this.
os_like() {
    if [ -r /etc/os-release ]; then
        ( . /etc/os-release && printf '%s\n' "${ID_LIKE:-${ID:-unknown}}" )
    else
        printf 'unknown\n'
    fi
}

# pkg_manager - prints apt, dnf, yum, zypper, pacman, apk, xbps or brew,
# or "none".
pkg_manager() {
    for _pm in apt-get dnf yum zypper pacman apk xbps-install brew; do
        if have_cmd "$_pm"; then
            case "$_pm" in
                apt-get) printf 'apt\n' ;;
                xbps-install) printf 'xbps\n' ;;
                *) printf '%s\n' "$_pm" ;;
            esac
            return 0
        fi
    done
    printf 'none\n'
}

# as_root CMD... - run CMD as root: directly if already root, else via sudo
# or doas.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have_cmd sudo; then
        sudo "$@"
    elif have_cmd doas; then
        doas "$@"
    else
        die "need root for: $* (no sudo or doas found)"
    fi
}

# pkg_install PKG... - install packages with the detected package manager.
# Package names differ between distros; resolve them first with pkg_name.
pkg_install() {
    case "$(pkg_manager)" in
        apt)    as_root apt-get install -y "$@" ;;
        dnf)    as_root dnf install -y "$@" ;;
        yum)    as_root yum install -y "$@" ;;
        zypper) as_root zypper --non-interactive install "$@" ;;
        pacman) as_root pacman -S --needed --noconfirm "$@" ;;
        apk)    as_root apk add "$@" ;;
        xbps)   as_root xbps-install -y "$@" ;;
        brew)   brew install "$@" ;;
        *)      die "no supported package manager; install manually: $*" ;;
    esac
}

# pkg_name APT DNF PACMAN ZYPPER APK - print the name for the current
# package manager from a row of per-manager names. Use "-" where a distro
# has no package. yum uses the dnf column, xbps and brew the pacman column.
#
#   pkg_install "$(pkg_name qemu-system-arm qemu-system-aarch64 qemu-system-aarch64 qemu-arm qemu-system-aarch64)"
pkg_name() {
    case "$(pkg_manager)" in
        apt)          _n=$1 ;;
        dnf|yum)      _n=$2 ;;
        pacman|xbps|brew) _n=$3 ;;
        zypper)       _n=$4 ;;
        apk)          _n=$5 ;;
        *)            _n=- ;;
    esac
    [ "$_n" = "-" ] && return 1
    printf '%s\n' "$_n"
}

# confirm PROMPT - ask y/N; true on yes. Honours ASSUME_YES=1.
confirm() {
    [ "${ASSUME_YES:-0}" = "1" ] && return 0
    printf '%s [y/N] ' "$1" >&2
    read -r _reply || return 1
    case "$_reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}
