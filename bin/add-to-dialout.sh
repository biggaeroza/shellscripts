#!/bin/sh
#
# add-to-dialout.sh - give the user who runs this access to serial ports
# (USB-serial adapters, /dev/ttyUSB*, /dev/ttyACM*, /dev/ttyS*) by adding
# them to the serial-port group, on any Linux distribution.
#
# Usage:
#   add-to-dialout.sh [--check] [--yes] [--user NAME] [--group NAME]
#
#   --check        only report whether the user is already in the group
#   --yes          don't ask before changing anything
#   --user NAME    add NAME instead of the user running the script
#                  (default: you, also when run through sudo or doas)
#   --group NAME   use this group instead of the detected one
#
# The group is the one owning an existing serial device if there is one,
# else dialout (Debian, Ubuntu, Fedora, openSUSE, Alpine, Void) or uucp
# (Arch, Manjaro). Log out and back in afterwards for it to apply.

set -eu

SS_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; }

CHECK_ONLY=0
ASSUME_YES=0
USER_NAME=""
GROUP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --user) [ $# -ge 2 ] || die "--user needs a name"; USER_NAME=$2; shift ;;
        --group) [ $# -ge 2 ] || die "--group needs a name"; GROUP=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

[ -n "$USER_NAME" ] || USER_NAME=$(invoking_user)
[ "$USER_NAME" != root ] || die "run this as your normal user (or pass --user NAME); root already has access"
id "$USER_NAME" >/dev/null 2>&1 || die "no such user: $USER_NAME"

# The group that owns an existing serial device is the right answer
# whatever the distro calls it.
if [ -z "$GROUP" ]; then
    for _dev in /dev/ttyUSB* /dev/ttyACM* /dev/ttyS0; do
        [ -e "$_dev" ] || continue
        GROUP=$(ls -ld "$_dev" | awk '{print $4}')
        [ "$GROUP" = root ] && GROUP="" || break
    done
fi
if [ -z "$GROUP" ]; then
    for _g in dialout uucp; do
        group_exists "$_g" && { GROUP=$_g; break; }
    done
fi
[ -n "$GROUP" ] || die "no dialout or uucp group found; pass --group with the group that owns your serial device"
group_exists "$GROUP" || die "no such group: $GROUP"

if user_in_group "$USER_NAME" "$GROUP"; then
    if id -nG | tr ' ' '\n' | grep -qx "$GROUP" || [ "$(id -un)" != "$USER_NAME" ]; then
        ok "$USER_NAME is in group $GROUP"
    else
        ok "$USER_NAME is in group $GROUP - log out and back in for it to apply to this session"
    fi
    exit 0
fi

info "$USER_NAME is not in group $GROUP (distro: $(os_id))"
[ "$CHECK_ONLY" = 1 ] && exit 1
confirm "Add $USER_NAME to group $GROUP?" || { info "Nothing changed."; exit 1; }

add_user_to_group "$USER_NAME" "$GROUP" || die "could not add $USER_NAME to $GROUP (see the output above)"
user_in_group "$USER_NAME" "$GROUP" || die "the command ran, but $USER_NAME is still not in $GROUP"
ok "added $USER_NAME to $GROUP"
info "Log out and back in (or reboot) for it to apply. To use it in one shell right away: newgrp $GROUP"
