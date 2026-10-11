#!/usr/bin/env bash
# wifi-fix.sh - keep PCIe root ports out of D3 so the Marvell 88W8897 firmware
# survives suspend/resume on Surface devices (Debian, Ubuntu, Kubuntu, Mint,
# Pop!_OS, ... anything using GRUB and update-grub).
#
# This is a stop-gap equivalent of the linux-surface patch "mwifiex: pcie:
# disable bridge_d3 for Surface gen4+". The complete fix is to run a kernel
# that carries that patch (see docs/WRITEUP.md).
#
#   sudo bash wifi-fix.sh apply [--disable-hooks] [--dry-run]
#   sudo bash wifi-fix.sh revert [--dry-run]
#   bash   wifi-fix.sh status
#
# apply        adds "pcie_port_pm=off" to the kernel command line via a GRUB
#              drop-in (/etc/default/grub.d), leaving /etc/default/grub alone.
# --disable-hooks
#              also moves sleep hooks that mention mwifiex out of the way
#              (they unload/reload the driver; with the fix they are not
#              needed and the remove/rescan variants can make things worse).
#              revert puts them back.
# --dry-run    show what would change, change nothing.
set -eu

DROPIN=/etc/default/grub.d/99-surface-wifi-pcie-port-pm.cfg
STATE=/var/lib/surface-wifi-fix
MANIFEST=$STATE/disabled-hooks

cmd="${1:-}"
shift || true
DRY=0
HOOKS=0
for a in "$@"; do
    case "$a" in
    --dry-run) DRY=1 ;;
    --disable-hooks) HOOKS=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

run() {
    if [ "$DRY" -eq 1 ]; then echo "[dry-run] $*"; else "$@"; fi
}

find_hooks() {
    local h
    for h in /usr/lib/systemd/system-sleep/* /etc/systemd/system-sleep/*; do
        [ -f "$h" ] && grep -qi mwifiex "$h" 2>/dev/null && echo "$h"
    done
    return 0
}

status() {
    echo "kernel        : $(uname -r)"
    if grep -qw 'pcie_port_pm=off' /proc/cmdline; then
        echo "param active  : yes"
    else
        echo "param active  : no"
    fi
    [ -e "$DROPIN" ] && echo "grub drop-in  : present ($DROPIN)" || echo "grub drop-in  : absent"
    local h
    for h in $(find_hooks); do echo "sleep hook    : ENABLED $h"; done
    [ -s "$MANIFEST" ] && echo "disabled hooks: $(wc -l <"$MANIFEST") (restored by revert)"
    return 0
}

require_root() {
    [ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
}

require_grub() {
    if ! command -v update-grub >/dev/null 2>&1 || [ ! -f /etc/default/grub ]; then
        cat >&2 <<'EOF'
This script supports GRUB (update-grub) only. For other boot loaders add
"pcie_port_pm=off" to the kernel command line yourself:
  systemd-boot / kernelstub (Pop!_OS): sudo kernelstub -a pcie_port_pm=off
  systemd-boot (manual): add it to the "options" line in /boot/loader/entries/*.conf
EOF
        exit 1
    fi
}

case "$cmd" in
status)
    status
    ;;
apply)
    require_root
    require_grub
    if ! grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub 2>/dev/null; then
        echo "warning: GRUB_CMDLINE_LINUX_DEFAULT not found in /etc/default/grub" >&2
    fi
    echo "Adding pcie_port_pm=off via $DROPIN"
    if [ "$DRY" -eq 1 ]; then
        echo '[dry-run] write drop-in: GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT pcie_port_pm=off"'
    else
        mkdir -p /etc/default/grub.d
        cat >"$DROPIN" <<'EOF'
# Added by surface-wifi-fix: keep PCIe ports out of D3 (mwifiex firmware crash on resume)
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT pcie_port_pm=off"
EOF
    fi
    if [ "$HOOKS" -eq 1 ]; then
        run mkdir -p "$STATE/hooks"
        for h in $(find_hooks); do
            dest="$STATE/hooks/$(echo "$h" | tr / _)"
            echo "Disabling sleep hook $h"
            if [ "$DRY" -eq 0 ]; then
                mv "$h" "$dest"
                echo "$h|$dest" >>"$MANIFEST"
            fi
        done
    else
        for h in $(find_hooks); do
            echo "note: sleep hook $h still active; consider --disable-hooks" >&2
        done
    fi
    run update-grub
    echo "Done. Reboot, then run: bash $0 status"
    ;;
revert)
    require_root
    run rm -f "$DROPIN"
    if [ -s "$MANIFEST" ]; then
        while IFS='|' read -r orig dest; do
            [ -e "$dest" ] || continue
            echo "Restoring sleep hook $orig"
            run mv "$dest" "$orig"
        done <"$MANIFEST"
        run rm -f "$MANIFEST"
    fi
    run update-grub
    echo "Reverted. Reboot to drop the kernel parameter."
    ;;
*)
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
