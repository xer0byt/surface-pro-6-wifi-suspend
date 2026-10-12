# Changelog

## v1.1 (2026-10-12)

Documentation and evidence only. The scripts are unchanged.

- Results on the linux-surface kernel (6.19.8-surface-3, stop-gap removed) grew
  from two suspends to six, including 77 min, 101 min and 18 h 28 min
  overnight. Wi-Fi came back in 3 to 4 s each time; no failure signatures in
  that boot's kernel log. Total is now nine cycles on one machine.
- Standby drain on that kernel measured: about 0.5 W (1.2% per hour) overnight.
  The write-up documents the method and its limits, and one wrong turn: a
  since-boot S0ix counter total looked like 8% residency, a before/after test
  showed about 100%.
- Documented the touchscreen (`ipts`) start/resume failure seen on that kernel,
  with the reload that restores touch and links to the open upstream reports.
  It is not a Wi-Fi symptom.
- New evidence sections G to J in `docs/evidence/journal-excerpts.txt`.

## v1.0 (2026-10-11)

Initial release: diagnostic script, `pcie_port_pm=off` stop-gap, write-up, and
the first results on the linux-surface kernel.
