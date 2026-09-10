# Assessment 1 — As-Built VM Configuration Reference

This document records the **actual deployed configuration** of the lab VMs,
reconciled from a live per-VM config backup. It is the source of truth for
addressing, routing, service placement and the IPv6 tunnel. The per-activity
folders remain the step-by-step teaching material; this file describes the
end state the machines are actually running.

**Completion status:** configured **through Activity 4.2** (OpenVPN). The
converged dual-stack firewall (4.1) is on egw, and the OpenVPN server (4.2) runs
on igw with an IPv6 tunnel pool. Remote clients connect to egw's public UDP 1194
(DNAT'd to igw) and are addressed from `10.8.0.0/24` and
`2404:9400:29c1:df80::/64`.

**Lab domains:** the primary zone is `chrisgrul-3014ict.com`, with
`3014ict.chris.grul.me` served as a split-horizon internal-only view. Public
records are hosted at the registrar (Namecheap); the internal view is served by
BIND9 on the Internal Gateway.

**IPv6 allocation:** routed `/56` = `2404:9400:29c1:df00::/56`, delegated to the
Remote Gateway (a Binary Lane VPS) and carried into the lab over the tunnel.

## Hosts

| Alias | Hostname          | Role                                            | Key services (enabled)                        |
|-------|-------------------|-------------------------------------------------|-----------------------------------------------|
| rgw   | `remotegateway`   | Off-site tunnel head-end (Binary Lane VPS)      | `wstunnel-server`, `nftables`                 |
| egw   | `externalgateway` | Perimeter gateway / NAT / tunnel client         | `wstunnel-client`, `wg-quick@wg0`, `wg-watchdog.timer`, `nftables` |
| igw   | `internalgateway` | Internal gateway / DNS / web proxy              | `named` (BIND9), `squid`, `nftables`          |
| srv   | `server`          | DMZ server — web + mail                         | `apache2`, `postfix`, `dovecot`               |
| dkt   | `desktop`         | Internal workstation (client)                   | `openvpn` client unit                         |
| ovc   | `openvpnclient`   | Off-net OpenVPN client (4.2 demo)               | `openvpn` (connects `~/client1.ovpn`)         |

ovc is not on the lab LAN — it dials in over the VPN and is reachable only at
its tunnel-issued address `2404:9400:29c1:df80::1000` once connected. Bring the
tunnel up (`sudo openvpn --config ~/client1.ovpn`) before deploying to or
presenting it, and point the `ovc` ssh alias at that address.

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
| `2404:9400:29c1:df80::/64`       | `10.8.0.0/24`     | OpenVPN client pool (4.2)       | igw tun0 `::1` / `10.8.0.1`, clients      |
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
- `srv`'s default routes point at egw, but the OpenVPN server sits on igw, so srv
  carries explicit return routes for the VPN pools via igw — `10.8.0.0/24` via
  `192.168.1.1` and `2404:9400:29c1:df80::/64` via `2404:9400:29c1:df10::1` —
  mirroring its existing internal-LAN routes. Without them srv would hand
  VPN-client replies to egw, which has no path to the pools.
- `egw` carries the same two VPN-pool routes via igw (`10.8.0.0/24` via
  `192.168.1.1`, `2404:9400:29c1:df80::/64` via `2404:9400:29c1:df10::1`). Its
  `wg0` pulls a default route (`AllowedIPs = ::/0`), so these more-specific
  routes — preferred via wg-quick's `suppress_prefixlength 0` rule — are what let
  admin traffic bound for a VPN client (e.g. ovc at `df80::1000`) reach igw's
  `tun0` instead of being sent back out the tunnel. Admin reaches ovc as
  `Chris /48 → rgw → egw (wg0) → egw eth1 → igw → tun0 → ovc df80::1000`.

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
  clamps MSS and forwards `wg0 ↔ eth0` for the `/56`. A **socat SMTP relay**
  (`labview-smtp-forward.service`) accepts public IPv4 `:25` and forwards it to
  the DMZ server over IPv6 (`[df10::80]:25`) — netfilter can't DNAT across
  address families, and only IPv6 reaches the lab over the tunnel. `input` `:25`
  and the outbound v6 are opened for it. Applied idempotently by
  `deploy-lab-view.zsh` (rgw only). Plain TCP relay, so srv sees rgw as the peer.
- **egw** — Activity 4.1 hardened firewall, **converged** into one `inet filter`
  table (`input`/`output`/`forward`, all default-drop) with the IPv4 (eth0 uplink)
  and IPv6 (wg0 tunnel) rules kept as distinct blocks. `forward` permits DMZ egress
  (`eth1 → eth0` IPv4, `eth1 → wg0` IPv6), IPv4 DNS forwarding, and inbound
  `80/443/25` to the server (`eth0 → eth1` IPv4 via DNAT, `wg0 → eth1` IPv6 direct
  to `df10::80`), with a TCP-MSS clamp on the tunnel path. `input` keeps the
  hardening: source-restricted admin SSH, `df00::/56` transit, `ct state invalid
  drop`, and ICMPv6 (ND + PMTUD + echo). `output` default-drops with loopback,
  established, `ct state new`, and DNS out. `ip nat` (IPv4-only) DNATs
  `80/443/25 → 192.168.1.80` (per-port), masquerades out `eth0`, and SNATs the
  server's return traffic to `192.168.1.254`; IPv6 needs no NAT. The
  source-restricted admin-SSH forward also carries an explicit rule for the VPN
  pool (`/48 → df80::/64 tcp/22`, alongside the general `/48 → :22` rule) so the
  admin path to ovc at `df80::1000` is visible in the ruleset. This passes the
  Activity 4.1 automarker in full; `deploy-lab-view.zsh` installs it idempotently
  on egw (detected by the DNAT-to-DMZ signature).
- **igw** — filter chains are open (it is an internal router); `inet nat`
  prerouting **redirects internal `tcp/80 → :8081` and `tcp/443 → :8443`** to
  force client web traffic through Squid (transparent interception). The DMZ
  server **srv (`192.168.1.80` / `2404:9400:29c1:df10::80`) is excluded** from
  this intercept for both families — two `return` rules ahead of the redirects
  send its `80/443` traffic direct to Apache (so bare-IP HTTPS works without
  ssl-bump/SNI). External traffic is still intercepted. Applied idempotently by
  `deploy-lab-view.zsh`.
- **srv**, **dkt** — baseline `inet filter` skeleton (no restrictive policy).

**Admin (SSH) source ranges** allowed on the gateways: IPv4 `49.255.230.48/29`,
IPv6 `2402:7800:2014::/48`. egw additionally permits SSH from the HyperV host
subnet `172.16.10.0/24`.

## Services

- **DNS (BIND9, igw):** master for two forward zones — `chrisgrul-3014ict.com`
  and the split-horizon internal zone `3014ict.chris.grul.me` (internal view
  only) — plus reverse zones. Forward-only to **Quad9 over DNS-over-TLS**
  (`9.9.9.9` / `149.112.112.112` / `2620:fe::f` / `2620:fe::9`, port 853, `tls
  quad9-dot` → `dns.quad9.net`); DoT is TCP, which is what makes forwarding work
  through Azure's UDP block (this replaced the earlier `tcp-only` forwarder
  workaround, now commented out in `named.conf`). DNSSEC validating. Listens on
  IPv4 (`127.0.0.1`, `192.168.1.1`, `10.10.1.254`) and IPv6 (`::1`, `df10::1`,
  `df20::254`); allow-query covers the v4 LANs and the whole `df00::/56`. Zone
  files: `db.chrisgrul-3014ict.com`, `db.3014ict.chris.grul.me` (A/AAAA, CNAME
  `www`, MX on the `.grul.me` zone), `db.192.168.1` (v4 PTR),
  `db.2404.9400.29c1.df10` (v6 PTR). The `tls quad9-dot` profile is defined in
  `named.conf`. See `activity2.2/bind/`.
- **Web (Apache, srv):** HTTP (`000-default`) + HTTPS (`default-ssl`) on
  `192.168.1.80` / `[2404:9400:29c1:df10::80]`; the SSL vhost is
  `chrisgrul-3014ict.com` (ServerAlias covers `www`, the wildcard, and both
  literal addresses) with a self-signed cert
  (`/etc/ssl/certs/chrisgrul-3014ICT.crt`). Reachable from outside via egw DNAT.
  See `activity2.1/default-ssl.conf`.
- **Proxy (Squid, igw):** explicit `8080`, transparent `8081`, HTTPS ssl-bump
  `8443` (peek→bump). Sample policy blocks `.au` sites during office hours
  (Mon–Fri 09:00–17:00) and allows the internal LAN. See `activity2.1/squid.conf`.
- **Mail (Postfix + Dovecot, srv):** dual-stack (`inet_protocols = all`),
  Maildir delivery via LMTP, Dovecot serving `imap pop3 lmtp` with PAM auth
  (`ssl = no` inside the lab). `mydomain = 3014ict.chris.grul.me`,
  `myhostname = mail.3014ict.chris.grul.me`; trusted networks
  `127.0.0.0/8, 192.168.1.0/24, 10.10.1.0/24, [::1]/128, [df00::]/56`. Because
  direct port-25 egress is blocked, **outbound mail relays through Resend**
  (`[smtp.resend.com]:587`, SASL + TLS); the relay credential lives in
  `/etc/postfix/sasl_passwd` on the box and is **not** in the repo or backup.
  Effective configs: `activity3/postfix/main.cf.as-built`,
  `activity3/dovecot/dovecot.conf.as-built`.

## Provenance / redaction

Recovered from the private `chris-grul/3014ICT_backup` per-VM backup (BIND, mail
and web configs captured by the extended `tools/lab-backup.sh`). WireGuard
private/preshared keys, the Squid ssl-bump CA private key, the Postfix
`sasl_passwd` relay credential, and all TLS private keys are **excluded**; only
public keys and non-secret directives are reproduced here.
