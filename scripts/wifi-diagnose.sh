#!/usr/bin/env bash
# wifi-diagnose.sh - read-only check for the Marvell 88W8897 (mwifiex_pcie)
# "Wi-Fi dead after suspend" problem on Surface devices running Debian-based
# distributions.
#
#   bash wifi-diagnose.sh              # report for this machine
#   bash wifi-diagnose.sh --redact     # same, with MAC addresses, hostname and
#                                      # SSIDs masked so it is safe to paste
#   bash wifi-diagnose.sh --boot -1    # inspect the previous boot's journal
#
# Changes nothing. Works without root, but the journal may need membership of
# the systemd-journal or adm group to show kernel messages.
set -u

REDACT=0
BOOT=0
while [ $# -gt 0 ]; do
    case "$1" in
    --redact) REDACT=1 ;;
    --boot) BOOT="${2:?--boot needs a number, e.g. 0 or -1}"; shift ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

redact() {
    if [ "$REDACT" -eq 1 ]; then
        sed -E \
            -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/XX:XX:XX:XX:XX:XX/g' \
            -e "s/$(hostname)/HOSTNAME/g" \
            -e 's/(UUID=)[0-9a-fA-F-]+/\1REDACTED/g'
    else
        cat
    fi
}

section() { printf '\n== %s ==\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

main() {
    local pci_dev="" driver="" bridge="" cmdline fw_ok=0 score=0

    section "System"
    echo "kernel        : $(uname -r)"
    [ -r /etc/os-release ] && echo "distribution  : $(. /etc/os-release && echo "$PRETTY_NAME")"
    for f in sys_vendor product_name bios_version; do
        [ -r /sys/class/dmi/id/$f ] && echo "$f: $(cat /sys/class/dmi/id/$f)"
    done
    echo "sleep modes   : $(cat /sys/power/mem_sleep 2>/dev/null)"
    cmdline=$(cat /proc/cmdline)
    echo "cmdline       : $cmdline"

    section "Wi-Fi device"
    # Marvell 88W8897 is 11ab:2b38. Fall back to anything bound to mwifiex_pcie.
    for d in /sys/bus/pci/devices/*; do
        if [ "$(cat "$d/vendor" 2>/dev/null):$(cat "$d/device" 2>/dev/null)" = "0x11ab:0x2b38" ] ||
            [ "$(basename "$(readlink "$d/driver" 2>/dev/null)")" = "mwifiex_pcie" ]; then
            pci_dev=$(basename "$d")
            break
        fi
    done
    if [ -z "$pci_dev" ]; then
        echo "No Marvell 88W8897 / mwifiex_pcie device found on the PCI bus."
        echo "If Wi-Fi died after sleep, this itself is a symptom: the card has"
        echo "dropped off the bus; power off completely (not just a reboot) and retry."
    else
        echo "PCI address   : $pci_dev"
        have lspci && lspci -nn -s "$pci_dev" | sed 's/^/                /'
        driver=$(basename "$(readlink "/sys/bus/pci/devices/$pci_dev/driver" 2>/dev/null)" 2>/dev/null)
        echo "driver bound  : ${driver:-none}"
        echo "power state   : $(cat /sys/bus/pci/devices/$pci_dev/power_state 2>/dev/null)"
        echo "d3cold_allowed: $(cat /sys/bus/pci/devices/$pci_dev/d3cold_allowed 2>/dev/null)"
        echo "reset methods : $(cat /sys/bus/pci/devices/$pci_dev/reset_method 2>/dev/null)"
        bridge=$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$pci_dev")")")
        if [ -e "/sys/bus/pci/devices/$bridge/power_state" ]; then
            echo "parent bridge : $bridge"
            echo "  power_state : $(cat /sys/bus/pci/devices/$bridge/power_state)"
            echo "  control     : $(cat /sys/bus/pci/devices/$bridge/power/control 2>/dev/null)"
            echo "  d3cold      : $(cat /sys/bus/pci/devices/$bridge/d3cold_allowed 2>/dev/null)"
        fi
    fi

    section "Kernel module quirks"
    local ko
    ko=$(modinfo -n mwifiex_pcie 2>/dev/null)
    if [ -z "$ko" ]; then
        echo "mwifiex_pcie module not found."
    else
        echo "module        : $ko"
        local strings_out=""
        case "$ko" in
        *.zst) have zstd && strings_out=$(zstd -dc "$ko" 2>/dev/null | strings) ;;
        *.xz) strings_out=$(xz -dc "$ko" 2>/dev/null | strings) ;;
        *.gz) strings_out=$(gzip -dc "$ko" 2>/dev/null | strings) ;;
        *) strings_out=$(strings "$ko") ;;
        esac
        if [ -z "$strings_out" ]; then
            echo "could not read module strings (need zstd/xz and binutils 'strings')"
        else
            echo "$strings_out" | grep -q 'reset_d3cold' &&
                echo "reset_d3cold quirk : present (upstream)" ||
                echo "reset_d3cold quirk : absent"
            if echo "$strings_out" | grep -qiE 'no_bri(d)?ge_d3'; then
                echo "no_bridge_d3 quirk : PRESENT (linux-surface kernel patch)"
                fw_ok=1
            else
                echo "no_bridge_d3 quirk : absent (stock kernel - bridge may enter D3)"
            fi
        fi
    fi

    section "Workaround state"
    if grep -qw 'pcie_port_pm=off' /proc/cmdline; then
        echo "pcie_port_pm=off   : ACTIVE"
        fw_ok=1
    else
        echo "pcie_port_pm=off   : not set"
    fi
    for h in /usr/lib/systemd/system-sleep/* /etc/systemd/system-sleep/*; do
        [ -f "$h" ] && grep -qi mwifiex "$h" 2>/dev/null &&
            echo "sleep hook touching mwifiex: $h"
    done

    section "Journal evidence (boot $BOOT)"
    if ! have journalctl; then
        echo "journalctl not available."
    else
        local j
        j=$(journalctl -k -b "$BOOT" --no-pager -o short 2>&1)
        if echo "$j" | grep -qiE 'no persistent|not seeing messages|Insufficient permissions|No journal files'; then
            echo "Cannot read the journal: $(echo "$j" | head -1)"
            echo "Try: sudo bash $0 $*"
        else
            c() { echo "$j" | grep -ciE "$1"; }
            local cycles fwdead d3 tmo skip dnld
            cycles=$(c 'PM: suspend entry')
            fwdead=$(c "Firmware (didn't wake up|wakeup failed)")
            d3=$(c 'Unable to change power state.*inaccessible')
            tmo=$(c 'cmd_wait_q terminated')
            skip=$(c 'WLAN FW already running')
            dnld=$(c 'FW download over')
            echo "suspend cycles                       : $cycles"
            echo "firmware downloads (fresh start)     : $dnld"
            echo "'Firmware didn't wake up' / wakeup failed : $fwdead"
            echo "'Unable to change power state' (D3)  : $d3"
            echo "'cmd_wait_q terminated' (fw hung)    : $tmo"
            echo "'WLAN FW already running' (reused fw): $skip"
            echo
            echo "Recent mwifiex / suspend lines:"
            echo "$j" | grep -iE 'mwifiex|PM: suspend (entry|exit)|01:00\.0.*(power|inaccessible)' | tail -25 | cut -c1-200
            if [ $((fwdead + tmo)) -gt 0 ] || { [ "$d3" -gt 0 ] && [ "$cycles" -gt 0 ]; }; then
                score=1
            fi
        fi
    fi

    section "Verdict"
    if [ -z "$pci_dev" ]; then
        echo "Card absent from the PCI bus. Power off completely (hold power button), boot,"
        echo "then re-run this script."
    elif [ "$BOOT" != "0" ]; then
        echo "Journal of boot $BOOT inspected; the mitigation state above is the CURRENT boot's"
        if [ "$score" -eq 1 ]; then
            echo "and that boot showed failure signatures."
        else
            echo "and that boot showed no failure signatures."
        fi
    elif [ "$fw_ok" -eq 1 ]; then
        echo "A bridge-D3 mitigation is in place (pcie_port_pm=off or a patched kernel)."
        [ "$score" -eq 1 ] && echo "...but the journal still shows failure signatures; open an issue with --redact output."
    elif [ "$score" -eq 1 ]; then
        echo "Failure signatures present and no mitigation active: this matches the known"
        echo "Surface mwifiex suspend/resume firmware crash. See docs/WRITEUP.md and run"
        echo "scripts/wifi-fix.sh apply."
    else
        echo "No failure signatures in this boot's journal and no mitigation active."
        echo "Either the problem has not triggered yet (suspend a few times and re-run)"
        echo "or this is a different issue."
    fi
}

main "$@" 2>&1 | redact
