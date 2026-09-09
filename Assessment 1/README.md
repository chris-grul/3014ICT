# Assessment 1 — Cybersecurity DMZ Lab (IPv6-extended)

> Configuration, automarking and presentation tooling for the Assessment 1 lab
> activities. **3014ICT / 7015ICT Cyber Security Operation Centres** · Griffith
> University.

This is one student's as-built lab: a segmented DMZ (perimeter gateway →
internal gateway → DMZ server + internal desktop) extended with **native IPv6**
on a routed `/56`, carried into an Azure-hosted lab over a WireGuard-in-wstunnel
tunnel (Azure blocks outbound UDP, so WireGuard rides WebSocket/TCP 443).

For the authoritative deployed topology, addressing, routing, tunnel and service
map, see **[`VM_CONFIG_REFERENCE.md`](./VM_CONFIG_REFERENCE.md)**.

## Activities

| Activity | Topic | Automarker | IPv6 variant | Status |
|---|---|---|---|---|
| [1](./activity1/)   | DMZ Networks                        | `automark_activity1.sh`   | `automark_activity1_ipv6.sh`   | ✅ built |
| [2.1](./activity2.1/) | Secure Web (NAT / SSL / Squid proxy) | `automark_activity2.1.sh` | `automark_activity2.1_ipv6.sh` | ✅ built |
| [2.2](./activity2.2/) | DNS (BIND9, split-horizon)          | `automark_activity2.2.sh` | `automark_activity2.2_ipv6.sh` | ✅ built |
| [3](./activity3/)   | Mail (Postfix + Dovecot)            | `automark_activity3.sh`   | `automark_activity3_ipv6.sh`   | ✅ built |
| [4.1](./activity4.1/) | Firewalls (nftables)              | `automark_activity4.1.sh` | `automark_activity4.1_ipv6.sh` | ⏳ pending on VMs |
| [4.2](./activity4.2/) | VPN (OpenVPN)                     | `automark_activity4.2.sh` | `automark_activity4.2_ipv6.sh` | ⏳ pending on VMs |

The machines are currently configured **up to and including Activity 3**. The
Activity 4 materials (scripts, configs, automarkers) are present in the repo but
not yet deployed on the VMs.

Each automarker runs on the VM, auto-detects which machine it is on from its IP
addresses, checks the expected configuration, and reports colour-coded pass/fail
with numbered error codes. The `_ipv6.sh` variants add the equivalent IPv6
checks plus coverage of the Remote Gateway / tunnel.

## Lab domain

Primary zone `chrisgrul-3014ict.com`, plus `3014ict.chris.grul.me` served as a
split-horizon internal-only view: public records at the registrar (Namecheap),
internal view served by BIND9 on the Internal Gateway (forwarding upstream over
Quad9 DNS-over-TLS). Zone files live under
[`activity2.2/bind/`](./activity2.2/bind/).

## Presentation tool

[`presentation/lab-view.zsh`](./presentation/) is an activity-aware walkthrough
driver used for the recorded demos. Given an activity number it walks the
relevant hosts, shows guide-aligned live evidence with syntax highlighting
(`lab_lexers.py`), renders a per-activity network map (`network_map.py`), and
runs the matching `_ipv6` automarker on each host.

## Design principles

- **Self-contained** — automarkers work standalone with only standard Ubuntu tools.
- **Auto-detecting** — the same command runs on every VM; the script identifies the host from its addresses.
- **Non-destructive** — read-only checks; configuration is never modified.
- **Inline diagnostics** — on failure the relevant live state is printed immediately.
- **Exact validation** — checks match specific expected values (e.g. nftables rules matched by interface pair, not by keyword).

## Environment

Ubuntu Server / Desktop 22.04 LTS. The internal lab runs in Azure Lab Services;
the Remote Gateway is a small external VPS (Binary Lane) that terminates the
tunnel and provides the routed IPv6 `/56`.

## Licence

MIT — free to use, adapt, and redistribute with attribution.
