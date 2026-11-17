#!/bin/sh
#
# python-env.sh - make plain "pip install X" just work, without managing venvs
#
# Usage:
#   python-env.sh [--dir DIR] [--check] [--rebuild] [--uninstall] [--yes] [--help]
#
# Distros now mark the system Python "externally managed" (PEP 668), so a
# bare "pip install" fails with "externally-managed-environment". This script
# sets up one personal virtual environment (default ~/.venv) and puts its bin
# first on PATH for every new shell, so "pip", "python" and "python3" are the
# venv's and anything pip installs (including commands like black or jupyter)
# is on PATH. Nothing under /usr is touched and no root is needed.
#
# The venv uses --system-site-packages, so Python libraries installed with the
# distro's package manager stay importable. A project venv you activate still
# takes precedence while it is active.
#
#   --dir DIR    put the venv in DIR instead of ~/.venv
#   --check      only report the current state, change nothing
#   --rebuild    recreate the venv (e.g. after a Python upgrade) and reinstall
#                the packages that were in it; the old one is kept as DIR.old-*
#   --uninstall  remove the PATH lines from the shell startup files and move
#                the venv aside to DIR.old-* (nothing is deleted)
#   --yes        don't ask before changing anything
#
# Run it again any time: it only fixes what is missing. Open a new terminal
# (or run ". ~/.profile") afterwards.

set -eu

SS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; }

ASSUME_YES=0
MODE=setup
VENV="$HOME/.venv"
while [ $# -gt 0 ]; do
    case "$1" in
        --dir) [ $# -ge 2 ] || die "--dir needs a directory"; VENV=$2; shift ;;
        --dir=*) VENV=${1#--dir=} ;;
        --check) MODE=check ;;
        --rebuild) MODE=rebuild ;;
        --uninstall) MODE=uninstall ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done
case "$VENV" in /*) ;; *) VENV="$(pwd)/$VENV" ;; esac
VENV=${VENV%/}

MARK_BEGIN="# >>> shellscripts python-env >>>"
MARK_END="# <<< shellscripts python-env <<<"

# The venv dir as written in the startup files: $HOME-relative when possible.
case "$VENV" in
    "$HOME"/*) VENV_RC="\$HOME/${VENV#"$HOME"/}" ;;
    *) VENV_RC=$VENV ;;
esac

# Startup files to put the PATH line in: ~/.profile (login shells, desktop
# sessions) plus the rc file of each interactive shell that is in use.
rc_files() {
    printf '%s\n' "$HOME/.profile"
    for _f in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$_f" ] && printf '%s\n' "$_f"
    done
    return 0
}

has_block() { [ -f "$1" ] && grep -qF "$MARK_BEGIN" "$1"; }

# remove_block FILE - drop our marked block, rewriting FILE in place (keeps
# its permissions and symlinks; no sed -i).
remove_block() {
    has_block "$1" || return 0
    _tmp=$(mktemp)
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip' "$1" > "$_tmp"
    cat "$_tmp" > "$1"
    rm -f "$_tmp"
}

add_block() {
    remove_block "$1"
    cat >> "$1" <<EOF
$MARK_BEGIN
# Personal Python venv first on PATH, so "pip install X" just works.
# Managed by ~/shellscripts/bin/python-env.sh (--uninstall removes this).
if [ -z "\${VIRTUAL_ENV:-}" ] && [ -d "$VENV_RC/bin" ]; then
    case ":\$PATH:" in
        "$VENV_RC/bin:"*) ;;
        *) PATH="$VENV_RC/bin:\$PATH"; export PATH ;;
    esac
fi
$MARK_END
EOF
}

sys_python() {
    for _p in python3 python; do
        _path=$(command -v "$_p" 2>/dev/null) || continue
        case "$_path" in "$VENV"/*) continue ;; esac
        printf '%s\n' "$_path"; return 0
    done
    return 1
}

venv_ok() { [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c 'import sys' 2>/dev/null; }

venv_has_pip() { "$VENV/bin/python" -m pip --version >/dev/null 2>&1; }

# venv_version_mismatch - true if the venv was made for another Python
# version than the system one (the venv is then broken or stale).
venv_version_mismatch() {
    [ -f "$VENV/pyvenv.cfg" ] || return 1
    _vv=$(awk -F' *= *' '$1 == "version" || $1 == "version_info" { print $2; exit }' "$VENV/pyvenv.cfg" | cut -d. -f1,2)
    _sv=$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    [ -n "$_vv" ] && [ "$_vv" != "$_sv" ]
}

# old_packages DIR - names of the packages installed in venv DIR (read from
# its dist-info folders, so it works even when that venv's Python is gone).
old_packages() {
    for _d in "$1"/lib/python*/site-packages/*.dist-info; do
        [ -d "$_d" ] || continue
        _n=$(basename "$_d" .dist-info)
        printf '%s\n' "${_n%-*}"
    done | grep -viE '^(pip|setuptools|wheel)$' | sort -u
}

aside_name() { printf '%s.old-%s\n' "$VENV" "$(date +%Y%m%d-%H%M%S)"; }

create_venv() {
    info "creating $VENV (Python $("$PY" -c 'import sys; print(sys.version.split()[0])'))"
    mkdir -p "$(dirname "$VENV")"
    if "$PY" -m venv --system-site-packages "$VENV" >/dev/null 2>&1; then
        :
    else
        # Debian/Ubuntu ship venv without ensurepip unless python3-venv is
        # installed. Make the venv without pip and bootstrap pip from the
        # system's pip module, which the venv can see.
        "$PY" -m venv --system-site-packages --without-pip --clear "$VENV"
        if "$VENV/bin/python" -m pip --version >/dev/null 2>&1; then
            info "no ensurepip; bootstrapping pip from the system pip"
            "$VENV/bin/python" -m pip install --quiet --upgrade pip
        else
            _pkg=$(pkg_name python3-venv - - - - 2>/dev/null) || _pkg=""
            [ -n "$_pkg" ] || _pkg=$(pkg_name python3-pip python3-pip python-pip python3-pip py3-pip) \
                || die "this Python has neither ensurepip nor a pip module; install pip for it"
            warn "this Python can't make a venv with pip; the $_pkg package fixes that"
            confirm "install $_pkg now?" || die "not installed; run again after installing $_pkg"
            pkg_install "$_pkg"
            "$PY" -m venv --system-site-packages --clear "$VENV"
        fi
    fi
    venv_has_pip || die "venv created but pip doesn't work in it"
    "$VENV/bin/python" -m pip install --quiet --upgrade pip || warn "could not upgrade pip (offline?)"
    ok "venv ready: $VENV"
}

report() {
    info "system Python: $PY ($("$PY" --version 2>&1))"
    if [ -f "$("$PY" -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')/EXTERNALLY-MANAGED" ]; then
        info "system Python is externally managed (bare pip install is blocked)"
    fi
    if venv_ok; then
        if venv_version_mismatch; then
            warn "$VENV was made for another Python version: run with --rebuild"
        else
            ok "venv: $VENV ($("$VENV/bin/python" --version 2>&1))"
        fi
        if venv_has_pip; then
            ok "pip in venv: $("$VENV/bin/python" -m pip --version | cut -d' ' -f1-2)"
        else
            warn "venv has no working pip"
        fi
    elif [ -e "$VENV" ]; then
        warn "$VENV exists but is broken: run with --rebuild"
    else
        info "venv: $VENV not created yet"
    fi
    for _f in $(rc_files); do
        if has_block "$_f"; then ok "PATH line in $_f"; else info "no PATH line in $_f"; fi
    done
    case ":$PATH:" in
        "$VENV/bin:"*) ok "this shell already uses the venv: pip = $(command -v pip)" ;;
        *) info "this shell does not use the venv yet (open a new terminal after setup)" ;;
    esac
}

PY=$(sys_python) || die "no python3 found; install Python first"

case "$MODE" in
check)
    report
    ;;

setup)
    report
    _todo=""
    if [ -e "$VENV" ] && ! venv_ok; then
        die "$VENV exists but is broken: run with --rebuild"
    fi
    venv_ok || _todo="$_todo create-venv"
    for _f in $(rc_files); do has_block "$_f" || _todo="$_todo rc"; done
    if [ -z "$_todo" ]; then
        ok "nothing to do"
        exit 0
    fi
    info ""
    info "will: create $VENV if missing and add a PATH line to: $(rc_files | tr '\n' ' ')"
    confirm "go ahead?" || die "nothing changed"
    venv_ok || create_venv
    for _f in $(rc_files); do
        has_block "$_f" || { add_block "$_f"; ok "PATH line added to $_f"; }
    done
    info ""
    ok "done. Open a new terminal (or run: . ~/.profile), then just use: pip install NAME"
    ;;

rebuild)
    report
    _old=$(aside_name)
    info ""
    info "will: move $VENV to $_old, create a new one and reinstall its packages"
    confirm "go ahead?" || die "nothing changed"
    _pkgs=""
    if [ -e "$VENV" ]; then
        _pkgs=$(old_packages "$VENV")
        mv "$VENV" "$_old"
        ok "old venv kept as $_old"
    fi
    create_venv
    if [ -n "$_pkgs" ]; then
        info "reinstalling: $(printf '%s\n' "$_pkgs" | tr '\n' ' ')"
        # shellcheck disable=SC2086
        "$VENV/bin/python" -m pip install $_pkgs \
            || warn "some packages failed to install; see above (the list is in $_old)"
    fi
    for _f in $(rc_files); do
        has_block "$_f" || { add_block "$_f"; ok "PATH line added to $_f"; }
    done
    ok "rebuilt. Delete $_old once all is well"
    ;;

uninstall)
    info "will: remove the PATH lines from $(rc_files | tr '\n' ' ')and move $VENV aside"
    confirm "go ahead?" || die "nothing changed"
    for _f in $(rc_files); do
        if has_block "$_f"; then remove_block "$_f"; ok "PATH line removed from $_f"; fi
    done
    if [ -e "$VENV" ]; then
        _old=$(aside_name)
        mv "$VENV" "$_old"
        ok "venv moved to $_old (delete it when you like)"
    fi
    ;;
esac
