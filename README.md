# Surface Pro: Wi-Fi dead after suspend (Marvell 88W8897 / mwifiex_pcie)

Wi-Fi does not come back after sleep on Surface devices with the Marvell
88W8897 card, running Debian, Ubuntu, Kubuntu, Linux Mint, Pop!_OS or another
Debian-based distribution. A full power-off is needed to recover.

This repository has a diagnostic script, a stop-gap fix, and a full write-up.

> **Status:** both fixes are verified on one machine (Surface Pro 6, Kubuntu /
> Ubuntu 26.04). The stop-gap (`pcie_port_pm=off`, stock 7.0.0-38-generic)
> survived three suspends, longest 40 minutes. The proper fix (linux-surface
> kernel 6.19.8-surface-3, stop-gap removed) survived six, from 45 seconds to
> 18 h 28 min overnight, with Wi-Fi back in 3 to 4 seconds each time and none of
> the original error signatures. It is still one machine and nine cycles in
> total. See [docs/WRITEUP.md](docs/WRITEUP.md) and the [changelog](CHANGELOG.md).

## Is this your problem?

After resume, one or more of these appear in `journalctl -k`:

```
mwifiex_pcie 0000:01:00.0: Unable to change power state from D3hot to D0, device inaccessible
mwifiex_pcie 0000:01:00.0: Firmware didn't wake up
mwifiex_pcie 0000:01:00.0: cmd_wait_q terminated: -110
```

or Wi-Fi simply never returns and `lspci` no longer shows the Marvell device.

```bash
git clone https://github.com/xer0byt/surface-pro-6-wifi-suspend
cd surface-pro-6-wifi-suspend
bash scripts/wifi-diagnose.sh            # read-only
bash scripts/wifi-diagnose.sh --redact   # safe to paste into an issue
```

## Stop-gap fix (in place, tested)

Keeps PCIe root ports out of the D3 power state with the kernel parameter
`pcie_port_pm=off`, which is close to what the linux-surface kernel patch does
for the Wi-Fi bridge only.

```bash
sudo bash scripts/wifi-fix.sh apply --disable-hooks   # adds the parameter; GRUB only
sudo reboot
bash scripts/wifi-fix.sh status                       # "param active: yes"
```

Undo with `sudo bash scripts/wifi-fix.sh revert`.

Trade-off: the parameter is global, so every PCIe port stays awake. On the test
machine a 40-minute suspend used about 4% battery (one uncontrolled reading).
Measure yours.

## Proper fix

Run the [linux-surface](https://github.com/linux-surface/linux-surface) kernel,
which carries the Wi-Fi quirks that the stock Debian/Ubuntu kernels lack. Once
you do, remove the stop-gap with `wifi-fix.sh revert` and reboot.

Tested result (Surface Pro 6, Secure Boot on, linux-surface signing key enrolled
in MOK): after booting 6.19.8-surface-3 without `pcie_port_pm=off`,
`wifi-diagnose.sh` reports `no_bridge_d3 quirk : PRESENT`, and six suspends
(45 s, 8 min, 9 min, 77 min, 101 min and 18 h 28 min) all resumed with Wi-Fi
back in 3 to 4 s, with none of the original failure signatures anywhere in that
boot's kernel log.

Standby drain on that kernel: about 0.5 W (1.2% battery per hour) over the
overnight suspend. The write-up has the measurement method and its limits;
it is one machine and was not compared with the stop-gap under the same
conditions.

Things to check after installing it:

- `uname -r` should show the `-surface` kernel. Which kernel GRUB boots by
  default depends on its version ordering; if you land on the generic one,
  choose the Surface entry under *Advanced options*.
- The touchscreen is the weak spot of the Surface kernel on the test machine,
  and it is unrelated to Wi-Fi. The `ipts` driver intermittently fails to
  start (3 of 8 boot/resume sequences, once at boot with no suspend), leaving
  touch dead until `sudo modprobe -r ipts && sudo modprobe ipts`; restarting
  `iptsd` is not enough. A worse variant left `iptsd` stuck, which aborted two
  re-suspend attempts; a three-minute shutdown stall on an earlier boot looks
  like the same thing, but I have no kernel stack for it. It matches the open
  upstream reports
  [linux-surface#2299](https://github.com/linux-surface/linux-surface/issues/2299)
  and [#1181](https://github.com/linux-surface/linux-surface/issues/1181).
  Wi-Fi was not affected. See the write-up.

## Contents

| Path | What |
| --- | --- |
| `scripts/wifi-diagnose.sh` | Read-only report with a verdict; `--redact` masks MACs and hostname |
| `scripts/wifi-fix.sh` | `apply`, `revert`, `status`, `--dry-run`, `--disable-hooks` |
| `docs/WRITEUP.md` | Root cause, what failed and why, fix options, caveats |
| `docs/evidence/journal-excerpts.txt` | Sanitized kernel logs: failure, failed workarounds, working state, long suspends, touchscreen failures |
| `CHANGELOG.md` | What changed between releases |

## Safety

- The scripts are short; read them before running with sudo.
- `wifi-fix.sh` only writes a GRUB drop-in file and (with `--disable-hooks`)
  moves sleep hooks that mention mwifiex; both are reversed by `revert`.
- Do not use PCI remove/rescan or driver reload as a suspend workaround on this
  hardware. In testing it made the card vanish until power-off. See the write-up.

## License

MIT. See [LICENSE](LICENSE). No warranty.
