# Surface Pro: Wi-Fi dead after suspend (Marvell 88W8897 / mwifiex_pcie)

Wi-Fi does not come back after sleep on Surface devices with the Marvell
88W8897 card, running Debian, Ubuntu, Kubuntu, Linux Mint, Pop!_OS or another
Debian-based distribution. A full power-off is needed to recover.

This repository has a diagnostic script, a stop-gap fix, and a full write-up.

> **Status:** the stop-gap fix is verified on one machine (Surface Pro 6,
> Kubuntu / Ubuntu 26.04, kernel 7.0.0-38-generic). The complete fix, a kernel
> carrying the linux-surface patches, is described but **not yet tested by the
> author**. See [docs/WRITEUP.md](docs/WRITEUP.md).

## Is this your problem?

After resume, one or more of these appear in `journalctl -k`:

```
mwifiex_pcie 0000:01:00.0: Unable to change power state from D3hot to D0, device inaccessible
mwifiex_pcie 0000:01:00.0: Firmware didn't wake up
mwifiex_pcie 0000:01:00.0: cmd_wait_q terminated: -110
```

or Wi-Fi simply never returns and `lspci` no longer shows the Marvell device.

```bash
git clone https://github.com/<owner>/surface-pro-6-wifi-suspend
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
machine a 40-minute suspend used about 4% battery. Measure yours.

## Proper fix

Run the [linux-surface](https://github.com/linux-surface/linux-surface) kernel,
which carries the Wi-Fi quirks that the stock Debian/Ubuntu kernels lack. Once
you do, remove the stop-gap with `wifi-fix.sh revert`.

## Contents

| Path | What |
| --- | --- |
| `scripts/wifi-diagnose.sh` | Read-only report with a verdict; `--redact` masks MACs and hostname |
| `scripts/wifi-fix.sh` | `apply`, `revert`, `status`, `--dry-run`, `--disable-hooks` |
| `docs/WRITEUP.md` | Root cause, what failed and why, fix options, caveats |
| `docs/evidence/journal-excerpts.txt` | Sanitized kernel logs: failure, failed workarounds, working state |

## Safety

- The scripts are short; read them before running with sudo.
- `wifi-fix.sh` only writes a GRUB drop-in file and (with `--disable-hooks`)
  moves sleep hooks that mention mwifiex; both are reversed by `revert`.
- Do not use PCI remove/rescan or driver reload as a suspend workaround on this
  hardware. In testing it made the card vanish until power-off. See the write-up.

## License

MIT. See [LICENSE](LICENSE). No warranty.
