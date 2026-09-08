# Griffith Assessment Automarker

> Automated configuration and assessment checking scripts for lab activities.  
> **7015ICT Cyber Security Operation Centres** · Griffith University

---

## Overview

This repository contains a growing collection of automarking scripts — one per lab activity. Each script runs directly on the student's VM, auto-detects the machine it is on, validates the expected configuration, and reports colour-coded pass/fail results with numbered error codes.

Scripts are designed to be downloaded by students at the end of each activity for self-checking, and can be used by teaching staff as a consistent marking baseline.

---

## Activities

| Activity | Topic | Script | Status |
|---|---|---|---|
| [Activity 1](./activity1/) | DMZ Networks | `automark_activity1.sh` | ✅ Ready |
| Activity 2 | TBA | — | 🔜 Coming |
| Activity 3 | TBA | — | 🔜 Coming |
| Activity 4 | TBA | — | 🔜 Coming |

---

## Quick start (for students)

Find your activity below, copy the one-liner, and run it on your VM.

### Activity 1 — DMZ Networks
```bash
curl -fsSL https://raw.githubusercontent.com/rishonmathew/griffith-assessment-automarker/main/activity1/automark_activity1.sh | sudo bash
```

> Scripts must be run with `sudo`. See the individual activity folder for full usage notes.

---

## Repository structure

```
griffith-assessment-automarker/
├── README.md                        ← You are here
├── activity1/
│   ├── automark_activity1.sh        ← Automarker script
│   └── README.md                    ← Activity-specific docs
├── activity2/
│   ├── automark_activity2.sh
│   └── README.md
└── ...
```

---

## Design principles

- **Self-contained** — each script works standalone with no external dependencies beyond standard Ubuntu tools.
- **Auto-detecting** — scripts identify which VM they are running on from IP addresses, so students run the same command on every machine.
- **Non-destructive** — read-only checks only. Scripts never modify system configuration.
- **Inline diagnostics** — on failure, relevant live state is printed immediately so students can self-diagnose without a tutor.
- **Exact validation** — checks verify specific expected values, not just the presence of keywords (e.g. nftables rules are matched by interface pair, not by word).

---

## Environment

All scripts target the Hyper-V based lab environment used in **7015ICT** at Griffith University. VMs run Ubuntu Server / Desktop 22.04 LTS on a Windows host with Hyper-V virtual switches.

---

## Licence

MIT — free to use, adapt, and redistribute with attribution.
