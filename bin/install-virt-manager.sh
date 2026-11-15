#!/bin/sh
#
# install-virt-manager.sh - install QEMU/KVM, libvirt and virt-manager with
# everything a desktop virtual-machine setup needs, on any Linux
# distribution: UEFI firmware, a software TPM (Windows 11), virt-install,
# virt-viewer and the NAT network. Then starts libvirt, turns on its
# "default" network and adds you to the libvirt and kvm groups.
#
# Usage:
#   install-virt-manager.sh [--check] [--yes] [--user NAME]
#
#   --check        only report what is installed and set up
#   --yes          don't ask before changing anything
#   --user NAME    add NAME to the groups instead of the user running this
#
# Package managers: apt, dnf/yum, zypper, pacman, apk, xbps.
# Init systems: systemd, OpenRC, runit. Hosts: x86_64 and aarch64.

set -eu

SS_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; }

CHECK_ONLY=0
ASSUME_YES=0
USER_NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        --user) [ $# -ge 2 ] || die "--user needs a name"; USER_NAME=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
done
[ -n "$USER_NAME" ] || USER_NAME=$(invoking_user)

PM=$(pkg_manager)
INIT=$(init_system)
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) QEMU_BIN=qemu-system-x86_64 ;;
    aarch64|arm64) ARCH=aarch64; QEMU_BIN=qemu-system-aarch64 ;;
    *) die "unsupported host architecture: $ARCH (x86_64 and aarch64 only)" ;;
esac

# Packages per package manager and host architecture. The UEFI firmware and
# the QEMU system emulator are the parts that differ by architecture.
packages() {
    case "$PM:$ARCH" in
        apt:x86_64)  _a="qemu-system-x86 ovmf" ;;
        apt:aarch64) _a="qemu-system-arm qemu-efi-aarch64" ;;
        dnf:x86_64|yum:x86_64) _a="edk2-ovmf" ;;
        dnf:aarch64|yum:aarch64) _a="edk2-aarch64" ;;
        pacman:x86_64) _a="edk2-ovmf" ;;
        pacman:aarch64) _a="edk2-aarch64" ;;
        zypper:x86_64) _a="qemu-x86 qemu-ovmf-x86_64" ;;
        zypper:aarch64) _a="qemu-arm qemu-uefi-aarch64" ;;
        apk:x86_64)  _a="qemu-system-x86_64 ovmf" ;;
        apk:aarch64) _a="qemu-system-aarch64 aavmf" ;;
        xbps:*)      _a="edk2-ovmf" ;;
        *) _a="" ;;
    esac
    case "$PM" in
        apt)     echo "$_a qemu-utils libvirt-daemon-system libvirt-clients virt-manager virtinst virt-viewer swtpm swtpm-tools dnsmasq-base" ;;
        dnf|yum) echo "$_a qemu-kvm qemu-img libvirt virt-install virt-manager virt-viewer swtpm swtpm-tools" ;;
        pacman)  echo "$_a qemu-desktop libvirt virt-manager virt-install virt-viewer swtpm dnsmasq dmidecode" ;;
        zypper)  echo "$_a qemu-kvm qemu-tools libvirt virt-manager virt-install virt-viewer swtpm" ;;
        apk)     echo "$_a qemu-img libvirt-daemon libvirt-qemu virt-manager virt-install virt-viewer swtpm dnsmasq dbus polkit" ;;
        xbps)    echo "$_a qemu libvirt virt-manager virt-manager-tools virt-viewer swtpm dnsmasq dbus polkit" ;;
        *)       echo "" ;;
    esac
}

# A systemd unit file exists (installed, whether enabled or not).
unit_exists() { systemctl list-unit-files "$1" 2>/dev/null | grep -q "^$1"; }
unit_enabled() { systemctl is-enabled "$1" >/dev/null 2>&1; }

virsh_sys() { as_root virsh -c qemu:///system "$@"; }

# --- checks --------------------------------------------------------------------------

MISSING=0
report() { # ok|missing|warn LABEL [NOTE]
    case "$1" in
        ok) ok "$2${3:+ - $3}" ;;
        warn) warn "$2${3:+ - $3}" ;;
        *) MISSING=1; printf '%s[missing]%s %s%s\n' "$SS_C_RED" "$SS_C_OFF" "$2" "${3:+ - $3}" >&2 ;;
    esac
}

info "QEMU/KVM + virt-manager - distro: $(os_id) (like: $(os_like)), package manager: $PM, init: $INIT, arch: $ARCH"
info ""

if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null || [ "$ARCH" = aarch64 ]; then
    if [ -e /dev/kvm ]; then report ok "/dev/kvm" "hardware virtualization available"
    else report warn "/dev/kvm missing" "the CPU supports virtualization; check that the kvm_intel/kvm_amd module is loaded"; fi
else
    report warn "no vmx/svm CPU flag" "turn on VT-x/AMD-V in the firmware setup; without it VMs run very slowly (no KVM)"
fi

PKGS_NEEDED=0
for _c in "$QEMU_BIN" qemu-img virsh virt-install virt-manager virt-viewer swtpm; do
    if have_cmd "$_c"; then report ok "$_c"
    else report missing "$_c"; PKGS_NEEDED=1; fi
done

SERVICE_OK=0
if have_cmd virsh && virsh -c qemu:///system version >/dev/null 2>&1; then
    report ok "libvirt is running"; SERVICE_OK=1
elif have_cmd virsh && [ "$(id -u)" -ne 0 ] && ! user_in_group "$(id -un)" libvirt; then
    report warn "can't ask libvirt whether it is running" "not in the libvirt group yet; it is checked again during setup"
else
    report missing "libvirt running"
fi

GROUPS_TODO=""
for _g in libvirt kvm; do
    if user_in_group "$USER_NAME" "$_g"; then report ok "$USER_NAME in group $_g"
    else report missing "$USER_NAME in group $_g"; GROUPS_TODO="$GROUPS_TODO $_g"; fi
done
info ""

if [ "$MISSING" = 0 ] && [ "$SERVICE_OK" = 1 ]; then
    ok "everything is installed and running - start it with: virt-manager"
    [ "$CHECK_ONLY" = 1 ] && exit 0
    confirm "Check the default network and services anyway?" || exit 0
fi
[ "$CHECK_ONLY" = 1 ] && exit 1

PKG_LIST=$(packages)
[ -n "$PKG_LIST" ] || [ "$PKGS_NEEDED" = 0 ] || die "no supported package manager; install QEMU, libvirt and virt-manager by hand"

info "Planned:"
[ "$PKGS_NEEDED" = 1 ] && info "  install with $PM (as root): $PKG_LIST"
info "  enable and start libvirt ($INIT), make its 'default' NAT network start automatically"
[ -n "$GROUPS_TODO" ] && info "  add $USER_NAME to group(s):$GROUPS_TODO (takes effect at next login)"
info ""
confirm "Go ahead?" || { info "Nothing changed."; exit 1; }

FAILED=""

# --- packages ----------------------------------------------------------------------------

if [ "$PKGS_NEEDED" = 1 ]; then
    case "$PM" in
        apt) as_root apt-get update ;;
        apk) as_root apk update ;;
    esac
    # shellcheck disable=SC2086
    if ! pkg_install $PKG_LIST; then
        warn "installing everything at once failed; retrying one package at a time"
        for _p in $PKG_LIST; do pkg_install "$_p" || FAILED="$FAILED $_p"; done
    fi
fi

# --- services ------------------------------------------------------------------------------
# libvirt runs either as one daemon (libvirtd) or as per-driver "modular"
# daemons (virtqemud, virtnetworkd, ...; the default on Fedora and openSUSE).
# Keep whichever the distro enabled on install; if it enabled neither (Arch),
# use libvirtd.

case "$INIT" in
    systemd)
        if unit_enabled virtqemud.socket || unit_enabled virtqemud.service; then
            for _u in virtqemud virtnetworkd virtstoraged virtnodedevd virtsecretd virtinterfaced virtnwfilterd virtproxyd virtlogd; do
                unit_exists "$_u.socket" && { as_root systemctl enable --now "$_u.socket" || FAILED="$FAILED $_u"; }
            done
        elif unit_exists libvirtd.service; then
            service_enable libvirtd.service || FAILED="$FAILED libvirtd"
        else
            warn "no libvirtd or virtqemud unit found"; FAILED="$FAILED libvirtd"
        fi
        ;;
    openrc)
        for _s in dbus virtlogd libvirtd; do
            [ -e "/etc/init.d/$_s" ] && { service_enable "$_s" || FAILED="$FAILED $_s"; }
        done
        ;;
    runit)
        for _s in dbus virtlockd virtlogd libvirtd; do
            [ -d "/etc/sv/$_s" ] && { service_enable "$_s" || FAILED="$FAILED $_s"; }
        done
        sleep 2   # runit starts services asynchronously
        ;;
    *) warn "unknown init system; start libvirtd by hand"; FAILED="$FAILED libvirtd" ;;
esac

# --- default NAT network ----------------------------------------------------------------------

if have_cmd virsh; then
    if ! virsh_sys net-info default >/dev/null 2>&1; then
        for _x in /usr/share/libvirt/networks/default.xml /etc/libvirt/qemu/networks/default.xml; do
            [ -r "$_x" ] && { virsh_sys net-define "$_x" >/dev/null && break; }
        done
    fi
    if virsh_sys net-info default >/dev/null 2>&1; then
        virsh_sys net-autostart default >/dev/null || FAILED="$FAILED network-autostart"
        if virsh_sys net-info default 2>/dev/null | grep -qE '^Active:[[:space:]]+yes'; then
            ok "network 'default' is active and starts automatically"
        elif virsh_sys net-start default >/dev/null; then
            ok "network 'default' started and starts automatically"
        else
            FAILED="$FAILED network-start"
        fi
    else
        warn "no 'default' network definition found"; FAILED="$FAILED network"
    fi
else
    FAILED="$FAILED virsh"
fi

# --- groups ----------------------------------------------------------------------------------

# Groups are looked up only now: installing libvirt is what creates the
# libvirt group. A distro without a kvm group (/dev/kvm open to all) is fine.
for _g in $GROUPS_TODO; do
    if ! group_exists "$_g"; then
        [ "$_g" = kvm ] && continue
        warn "group $_g doesn't exist"; FAILED="$FAILED group-$_g"; continue
    fi
    if add_user_to_group "$USER_NAME" "$_g" && user_in_group "$USER_NAME" "$_g"; then
        ok "added $USER_NAME to $_g"
    else
        FAILED="$FAILED group-$_g"
    fi
done

# --- summary ---------------------------------------------------------------------------------

info ""
if [ -n "$FAILED" ]; then
    warn "not done:$FAILED (see the output above)"
    exit 1
fi
ok "done"
[ -n "$GROUPS_TODO" ] && info "Log out and back in so the group changes apply, then start: virt-manager"
[ -z "$GROUPS_TODO" ] && info "Start it with: virt-manager"
exit 0
