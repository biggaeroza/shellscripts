#!/bin/sh
#
# _template.sh - copy this to start a new script: cp bin/_template.sh bin/NAME.sh
#
# Usage:
#   NAME.sh [--yes] [--help]
#
# Describe here what the script does and what it needs.

set -eu

SS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; }

ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

info "distro: $(os_id) (like: $(os_like)), package manager: $(pkg_manager)"
