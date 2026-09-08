# Assessment 1 — As-Built VM Configuration Reference

This document records the **actual deployed configuration** of the lab VMs,
reconciled from a live per-VM config backup. It is the source of truth for
addressing, routing, service placement and the IPv6 tunnel. The per-activity
folders remain the step-by-step teaching material; this file describes the
end state the machines are actually running.

**Completion status:** configured **up to and including Activity 3** (Mail).
Activity 4.1 (standalone firewall hardening) and 4.2 (OpenVPN) are not yet
built out on the boxes — an `openvpn` client unit exists on the Desktop but no
VPN server is deployed.

**Lab domain:** `3014ict.chris.grul.me` — split-horizon DNS. Public records are
hosted at the registrar (Namecheap); the internal view is served by BIND9 on
the Internal Gateway.

**IPv6 allocation:** routed `/56` = `2404:9400:29c1:df00::/56`, delegated to the
Remote Gateway (a Binary Lane VPS) and carried into the lab over the tunnel.

## Hosts

| Alias | Hostname          | Role                                            | Key services (enabled)                        |
|-------|-------------------|-------------------------------------------------|-----------------------------------------------|
| rgw   | `remotegateway`   | Off-site tunnel head-end (Binary Lane VPS)      | `wstunnel-server`, `nftables`                 |
| egw   | `externalgateway` | Perimeter gateway / NAT / tunnel client         | `wstunnel-client`, `wg-quick@wg0`, `wg-watchdog.timer`, `nftables` |
| igw   | `internalgateway` | Internal gateway / DNS / web proxy              | `named` (BIND9), `squid`, `nftables`          |
| srv   | `server`          | DMZ server — web + mail                         | `apache2`, `postfix`, `dovecot`               |
| dkt   | `desktop`         | Internal workstation (client)                   | (`openvpn` client unit present; 4.2 pending)  |

## Addressing

| Host | Interface | IPv4                    | IPv6 (GUA)                          | Notes                                  |
|------|-----------|-------------------------|-------------------------------------|----------------------------------------|
| rgw  | eth0      | `112.213.39.252/24`     | `2404:9400:2:0:216:3eff:fee9:c1df/64` (SLAAC) | Public VPS interface           |
| rgw  | wg0       | —                       | `2404:9400:29c1:df00::254/64`       | Tunnel head-end; ListenPort 51820      |
| egw  | eth0      | `172.16.10.100/24` (metric 100) | (link-local only)           | Azure "WAN" upstream                    |
| egw  | eth1      | `192.168.1.254/24`      | `2404:9400:29c1:df10::254/64`       | DMZ-facing                              |
| egw  | wg0       | —                       | `2404:9400:29c1:df00::1/64`         | Tunnel client end                       |
| igw  | eth0      | `192.168.1.1/24`        | `2404:9400:29c1:df10::1/64`         | DMZ-facing; DNS + proxy                  |
| igw  | eth1      | `10.10.1.254/24`        | `2404:9400:29c1:df20::254/64`       | Internal-facing; default gw for dkt     |
| srv  | eth0      | `192.168.1.80/24`       | `2404:9400:29c1:df10::80/64`        | Web (Apache) + mail (Postfix/Dovecot)   |
| dkt  | eth0      | `10.10.1.1/24`          | `2404:9400:29c1:df20::1/64`         | Workstation                             |

### Segments

| Prefix (IPv6)                    | IPv4 subnet       | Segment                         | Members                                   |
|----------------------------------|-------------------|---------------------------------|-------------------------------------------|
| `2404:9400:29c1:df00::/64`       | —                 | WireGuard tunnel transit        | rgw `::254`, egw `::1`                     |
| `2404:9400:29c1:df10::/64`       | `192.168.1.0/24`  | DMZ                             | egw `::254`, igw `::1`, srv `::80`         |
| `2404:9400:29c1:df20::/64`       | `10.10.1.0/24`    | Internal LAN                    | igw `::254`, dkt `::1`                     |
| —                                | `172.16.10.0/24`  | Azure WAN upstream (egw eth0)   | egw `172.16.10.100`                        |

## Routing

Default egress path for the internal networks:

```
dkt ──(df20::254 / 10.10.1.254)──▶ igw ──(df10::254 / 192.168.1.254)──▶ egw
     ──▶ wg0 tunnel ──▶ rgw ──▶ Internet
```

- **IPv6** is routed natively across the lab and out via WireGuard: egw forwards
  `eth1 → wg0` with `AllowedIPs = ::/0`; rgw accepts transit for the whole `/56`
  and forwards `wg0 → eth0` to the Internet. TCP MSS is clamped to the path MTU
  on both gateways (routers can't fragment IPv6).
- **IPv4** is NATed at egw (`masquerade` out `eth0`), with inbound `80/443`
  DNAT'd to the DMZ web server `192.168.1.80`.
- `igw` and `dkt` carry a default route toward `df10::254` / `df20::254`
  respectively; forwarding sysctls (`net.ipv4.ip_forward`,
  `net.ipv6.conf.all.forwarding`) are enabled on rgw, egw and igw.

## IPv6-over-TCP tunnel (why it exists)

Azure Lab Services blocks most outbound UDP, so WireGuard cannot peer directly.
WireGuard is therefore wrapped in **wstunnel** (WebSocket over TCP/443):

- **rgw** runs `wstunnel server wss://[::]:443` (`--restrict-to localhost:51820`,
  `CAP_NET_BIND_SERVICE`) fronting a WireGuard listener on UDP 51820.
- **egw** runs `wstunnel client … -L 'udp://51820:localhost:51820' wss://112.213.39.252:443`,
  and its `wg0` peers to `Endpoint = 127.0.0.1:51820` (the local wstunnel mouth).
- WireGuard: MTU `1280`, `PersistentKeepalive = 25`, PSK in use.
  Public keys (not secret): rgw `d+lPLoY6Ra/Wgf1TleES99OBpqxYApwEZu3LvSXFFXo=`,
  egw `tAfyBZkLBZFOjHYGWiO2xtu5stanS8TOsloTk07GSys=`.
- A `wg-watchdog` timer on egw re-establishes the tunnel after the lab VM's
  idle auto-suspend.

## Firewall (nftables) summary

- **rgw** — `inet filter` input default-drop (SSH restricted to the admin
  ranges below; TCP/443 open for wstunnel on IPv4 only); `ip6 filter forward`
  clamps MSS and forwards `wg0 ↔ eth0` for the `/56`.
- **egw** — `inet filter` input default-drop; `ip filter forward` allows LAN
  egress and inbound `80/443` to the web server; `ip6 filter forward` routes
  `eth1 → wg0` (MSS clamped); `ip nat` DNATs `80/443 → 192.168.1.80` and
  masquerades out `eth0`.
- **igw** — filter chains are open (it is an internal router); `inet nat`
  prerouting **redirects internal `tcp/80 → :8081` and `tcp/443 → :8443`** to
  force client web traffic through Squid (transparent interception).
- **srv**, **dkt** — baseline `inet filter` skeleton (no restrictive policy).

**Admin (SSH) source ranges** allowed on the gateways: IPv4 `49.255.230.48/29`,
IPv6 `2402:7800:2014::/48`. egw additionally permits SSH from the HyperV host
subnet `172.16.10.0/24`.

## Services

- **DNS (BIND9, igw):** authoritative for `3014ict.chris.grul.me` internally,
  forward-only to `8.8.8.8/8.8.4.4` over **TCP** (Azure blocks UDP/53), DNSSEC
  validating. Listens on IPv4 (`127.0.0.1`, `192.168.1.1`, `10.10.1.254`) and
  IPv6 (`::1`, `df10::1`, `df20::254`). Zone files: `db.3014ict.chris.grul.me`
  (A + AAAA + MX), `db.192.168.1` (v4 PTR), `db.df10.ip6` (v6 PTR). See
  `activity2.2/bind/`.
- **Web (Apache, srv):** serves HTTP/HTTPS on `192.168.1.80` and
  `[2404:9400:29c1:df10::80]`; reachable from outside via egw DNAT.
- **Proxy (Squid, igw):** explicit `8080`, transparent `8081`, HTTPS ssl-bump
  `8443` (peek→bump). Sample policy blocks `.au` sites during office hours
  (Mon–Fri 09:00–17:00) and allows the internal LAN. See `activity2.1/squid.conf`.
- **Mail (Postfix + Dovecot, srv):** Maildir delivery via LMTP; trusted
  networks `192.168.1.0/24` + `10.10.1.0/24`; MX `mail.3014ict.chris.grul.me`.
  See `activity3/`.

## Provenance / redaction

Recovered from the private `chris-grul/3014ICT_backup` per-VM backup. WireGuard
private/preshared keys and the Squid ssl-bump CA private key are **excluded**;
only public keys and non-secret directives are reproduced here.
