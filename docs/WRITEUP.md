# Marvell 88W8897 Wi-Fi fails after suspend on Surface devices: write-up

Test machine: Surface Pro 6, Kubuntu (Ubuntu 26.04), kernel 7.0.0-38-generic,
firmware package `linux-firmware 20260319`, driver `mwifiex 1.0 (15.68.19.p21)`,
s2idle only (`/sys/power/mem_sleep` = `[s2idle]`). Raw logs:
[evidence/journal-excerpts.txt](evidence/journal-excerpts.txt).

Applies in principle to Surface devices that use the 88W8897 (the linux-surface
patches name Surface Pro 4, 5, 5 LTE, 6, Surface Book, Book 2, Laptop, Laptop 2).
Only the Pro 6 was tested here.

## 1. Symptom

After suspend and resume, Wi-Fi is gone. Depending on the cycle:

- the kernel logs `Unable to change power state from D3hot to D0, device inaccessible`
  followed by `Firmware didn't wake up` and `Firmware wakeup failed`;
- or the interface comes back, associates, then every firmware command times
  out (`cmd_wait_q terminated: -110`) and nothing can scan;
- or, after attempted recovery, `lspci` no longer lists the card at all.

Recovery in my case required a complete power-off. I did not establish whether a
warm reboot would also have worked, so power off fully to be safe.

## 2. What the logs show

1. **The driver's own recovery does not recover.** After `Firmware wakeup failed`
   the driver runs its `reset_d3cold` quirk (puts the card and its root port into
   D3cold, then D0). The kernel still reports `device inaccessible`, and the next
   line is `WLAN FW already running! Skip FW dnld`. The firmware was never
   restarted, so a wedged firmware survives (evidence A and B).
2. **Reloading the driver does not restart the firmware either.** Unloading and
   reloading `mwifiex_pcie` always prints `WLAN FW already running! Skip FW dnld`.
   In every log I have, firmware is downloaded only at cold boot, never after a
   driver reload. A workaround that depends on a reload restarting the firmware
   will not work on this hardware.
3. **PCI function reset is not available.** `reset_method` for the card is
   `bus` only. A bus reset through sysfs did not restart the firmware.
4. **PCI remove + rescan is harmful.** In one cycle a hook removed the device and
   rescanned the bus. The card never re-enumerated, and every later attempt
   failed simply because the device was not there (evidence C). Anything that
   removes the device from the bus risks needing a power-off.
5. **Holding the root port out of D3 works.** With `pcie_port_pm=off`, no hook,
   and the driver left loaded, three suspends (about 49 s, 6 min, 40 min) all
   resumed with Wi-Fi back about four seconds after wake and none of the errors
   above (evidence D).

## 3. Root cause (best current understanding)

The 88W8897 firmware crashes or hangs when the PCIe root port above it enters D3
across suspend. This is the finding of the linux-surface patch
*"mwifiex: pcie: disable bridge_d3 for Surface gen4+"*, whose commit message says
that disabling D3 for the bridge fixes the firmware crashing after suspend, and
observes that on Windows the Wi-Fi root port never enters D3. The patch sets
`parent_pdev->bridge_d3 = false` for the affected Surface models.

Caveats on that claim:

- I did not read the Marvell firmware or verify the mechanism independently. The
  evidence here is consistent with the patch author's finding, and the stop-gap
  below made the failure disappear in my tests.
- Three suspend cycles on one machine is encouraging, not proof. The original
  failure was intermittent.
- Stock Debian/Ubuntu kernels contain the `reset_d3cold` quirk
  (`quirk reset_d3cold enabled` in dmesg) but, in my kernel, no no-bridge-D3
  quirk. `wifi-diagnose.sh` checks the module for it.

## 4. Fixes

### 4.1 Stop-gap in place: `pcie_port_pm=off`

Kernel parameter documented as "Disable power management of all PCIe ports".
`scripts/wifi-fix.sh apply` adds it through `/etc/default/grub.d/` and runs
`update-grub`. It is not the same code path as the patch (global instead of one
bridge), so treat it as "behaves similarly in testing", not "equivalent".

Pros: no extra packages, easily reversible, works on a stock kernel.

Cons:

- every PCIe port stays awake, which may cost standby battery. About 4% over a
  40-minute suspend on the test machine, no baseline measured;
- affects all devices, including the NVMe port;
- GRUB only. For systemd-boot or kernelstub add the parameter by hand.

Also remove any sleep hook that unloads the driver or removes the PCI device.
With the bridge held in D0 it is unnecessary, and the remove/rescan variants can
make the card disappear. `wifi-fix.sh apply --disable-hooks` moves hooks that
mention `mwifiex` aside and `revert` restores them.

### 4.2 Proper fix: a kernel with the Surface patches

The [linux-surface](https://github.com/linux-surface/linux-surface) project
publishes patched kernels and an apt repository for Debian/Ubuntu. Its mwifiex
patch set (for the 7.0 series:
[0003-mwifiex.patch](https://data.gpo.zugaina.org/linux-surface/sys-kernel/surface-sources/files/7.0/0003-mwifiex.patch))
contains:

| Quirk | What it does |
| --- | --- |
| `QUIRK_NO_BRIDGE_D3` | keeps the Wi-Fi root port out of D3 (the fix described above) |
| `QUIRK_DO_FLR_ON_BRIDGE` | resets the bridge after firmware init so the firmware's hardcoded LTR value does not block deep package C-states / S0ix |
| `QUIRK_FW_RST_D3COLD` | already upstream; D3cold firmware reset |

The second row matters for battery: it targets the very idle-power problem a
global `pcie_port_pm=off` can worsen.

Status: **not yet tested by the author.** Follow the linux-surface
installation guide for your distribution, including its notes on Secure Boot.
After booting the Surface kernel, run `wifi-diagnose.sh` (it should report
`no_bridge_d3 quirk : PRESENT`), do several suspend cycles, then
`sudo bash scripts/wifi-fix.sh revert` and reboot to drop the stop-gap and
compare.

## 5. What did not work

| Attempt | Result |
| --- | --- |
| Manual recovery script: unload, PCI remove, rescan, reload | card did not re-enumerate; power-off needed |
| systemd-sleep hook: unload before sleep, reload after | worked once, failed the next cycle (firmware reused, never scans) |
| Same hook plus scan check, PCI reset, then remove/rescan | made the card vanish from the bus |
| Driver's built-in `reset_d3cold` recovery | reports `device inaccessible`, firmware keeps running |

## 6. Measuring your own system

```bash
bash scripts/wifi-diagnose.sh               # state + journal counters
journalctl -k -b --no-pager | grep -iE 'mwifiex|01:00.0|PM: suspend|inaccessible|wake up'
upower -i $(upower -e | grep BAT)           # note energy before and after a long suspend
```

Test several short sleeps and at least one long one. A failure leaves the card
wedged; power off completely before the next test.

## 7. Assumptions I made that turned out wrong

- That reloading the module reloads the firmware: false here; see 2.2.
- That PCI remove/rescan is a safe recovery: it can strand the card; see 2.4.
- That one successful suspend test shows a workaround works: the failures were
  intermittent, and the hook that passed once failed on the next cycle.

## 8. Sources

- linux-surface mwifiex patch series (kernel 7.0 packaging copy), linked above.
- Kernel parameters documentation, `pcie_port_pm=`:
  <https://docs.kernel.org/admin-guide/kernel-parameters.html>
- linux-surface project: <https://github.com/linux-surface/linux-surface>
