#!/bin/bash
# =============================================================================
# Automarking Script - Activity 4-2: VPN with OpenVPN
# 7015ICT | Griffith University
# =============================================================================
# Run on Internal Gateway, External Gateway, or OpenVPN Client VM.
# The script auto-detects which VM it is running on.
#
# Error code reference (see Activity 4-2 guide Troubleshooting section):
#   E1 — OpenVPN or Easy-RSA not installed / missing files
#   E2 — PKI not initialised or certificates missing
#   E3 — Files not copied to /etc/openvpn correctly
#   E4 — server.conf missing or misconfigured
#   E5 — IP forwarding not enabled (runtime or persistent)
#   E6 — OpenVPN service not running or not enabled
#   E7 — tun0 interface missing or wrong IP
#   E8 — Client certificates or .ovpn bundle missing
#   E9 — nftables UDP 1194 rules missing on External Gateway
#   E10 — VPN not connected on Client VM (tun0 absent or wrong IP)
#
#   ---- IPv6 test layer (added; mirrors the IPv4 checks, non-destructive) ----
#   E11 — IPv6 addressing wrong/missing (eth0/eth1/wg0/tun0 inet6)
#   E12 — IPv6 routing wrong/missing (ip -6 route get)
#   E13 — IPv6 forwarding not enabled (net.ipv6.conf.all.forwarding)
#   E14 — IPv6 nftables rule missing (UDP 1194 accept in ip6/inet family)
#   E15 — IPv6 connectivity failed (ping6 to a lab peer / across the tunnel)
#   E16 — No IPv6 internet access
#   E17 — OpenVPN IPv6 service not listening on a v6 transport (when v6-configured)
#
#   NOTE: The author's supplied OpenVPN config is IPv4-only (proto udp, server
#   10.8.0.0). All OpenVPN-over-IPv6 checks below are marked "# ASSUMPTION:" and
#   are SOFT — they only fail loudly when the config actually shows IPv6 intent
#   (proto udp6 / server-ipv6 / tun-ipv6); otherwise they warn and skip. See the
#   augmentation report for the exact items the author must confirm.
#
# Usage: sudo bash automark_activity4.2.sh
# =============================================================================

if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "  [ERROR] Please run with sudo: sudo bash automark_activity4.2.sh"
    echo ""
    exit 1
fi

# -----------------------------------------------------------------------------
REAL_USER="${SUDO_USER:-user}"
USER_HOME=$(eval echo "~$REAL_USER")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
ERRORS=()

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $2"; echo -e "         ${YELLOW}→ Error $1${NC}"; ERRORS+=("$1"); ((FAIL++)) || true; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
section() { echo ""; echo -e "${BOLD}--- $1 ---${NC}"; }

has_ip() {
    ip addr show 2>/dev/null | grep -q "$1"
}

# ============================================================================
#  SHARED IPv6 HELPER BLOCK  —  pasted verbatim, placed AFTER the existing
#  helper/check functions and BEFORE the run_<vm>() funcs. These names are
#  unique and won't clash with existing helpers. They reuse the script's
#  existing pass()/fail()/section()/CYAN/NC.
# ============================================================================

# ---- IPv6 diagnostics ----
diag_ip6() {
    echo -e "         ${CYAN}[DIAG] Current IPv6 addresses:${NC}"
    ip -6 -br addr show 2>/dev/null | sed 's/^/                /'
}
diag_routes6() {
    echo -e "         ${CYAN}[DIAG] Current IPv6 routes:${NC}"
    ip -6 route show 2>/dev/null | sed 's/^/                /'
    ip -6 route show table 51820 2>/dev/null | sed 's/^/                [t51820] /'
}

# ---- IPv6 addressing ----
# check_ip6 <iface> <expected-cidr e.g. 2404:9400:29c1:df10::80/64> <code>
check_ip6() {
    local iface=$1 expected=$2 code=$3
    if ip -6 addr show "$iface" 2>/dev/null | grep -qF "inet6 $expected"; then
        pass "$iface = $expected"
    else
        local actual
        actual=$(ip -6 addr show "$iface" 2>/dev/null | grep "inet6 " | grep -v "fe80" | awk '{print $2}' | tr '\n' ' ')
        fail "$code" "$iface = $expected  (found: ${actual:-none})"
        diag_ip6
    fi
}
# check_ip6_has_global <iface> <code>   (for SLAAC/unknown addresses)
check_ip6_has_global() {
    local iface=$1 code=$2
    if ip -6 addr show "$iface" scope global 2>/dev/null | grep -q "inet6 "; then
        local a
        a=$(ip -6 addr show "$iface" scope global 2>/dev/null | grep "inet6 " | awk '{print $2}' | tr '\n' ' ')
        pass "$iface has a global IPv6 address ($a)"
    else
        fail "$code" "$iface has no global IPv6 address"; diag_ip6
    fi
}

# ---- IPv6 routing (uses `ip -6 route get`, so it also sees wg-quick table 51820) ----
# check_route6_get <dest> <expected-substr e.g. 'via 2404:...df10::254' or 'dev wg0'> <code> <label>
check_route6_get() {
    local dest=$1 expect=$2 code=$3 label=$4 out
    out=$(ip -6 route get "$dest" 2>/dev/null)
    if echo "$out" | grep -q "$expect"; then
        pass "IPv6 route to $label — $expect"
    else
        fail "$code" "IPv6 route to $label not '$expect'  (got: ${out:-none})"; diag_routes6
    fi
}

# ---- IPv6 forwarding ----
check_ip6_forward() {
    local code=$1 val
    val=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)
    if [ "$val" = "1" ]; then pass "IPv6 forwarding enabled (net.ipv6.conf.all.forwarding = 1)"
    else fail "$code" "IPv6 forwarding not enabled (value: ${val:-unreadable})"; fi
}

# ---- IPv6 connectivity ----
check_ping6() {
    local target=$1 label=$2 code=$3
    if ping -6 -c 2 -W 2 "$target" &>/dev/null; then pass "Ping6 $label ($target)"
    else fail "$code" "Cannot ping6 $label ($target)"; fi
}
check_internet6() {
    local code=$1
    if ping -6 -c 2 -W 3 2001:4860:4860::8888 &>/dev/null; then
        pass "IPv6 internet reachable (ping 2001:4860:4860::8888)"; return; fi
    local http
    http=$(curl -6 -s -o /dev/null -w "%{http_code}" --max-time 8 -L https://www.google.com 2>/dev/null)
    if [[ "$http" =~ ^[23] ]]; then pass "IPv6 internet reachable (HTTP $http over IPv6)"; return; fi
    fail "$code" "No IPv6 internet access (ping6 + curl -6 both failed)"; diag_routes6
}

# ---- IPv6 service listener (checks something is bound on a v6 address:port) ----
# check_listen6 <port> <label> <code>
check_listen6() {
    local port=$1 label=$2 code=$3 laddrs
    laddrs=$(ss -H -ltn "( sport = :$port )" 2>/dev/null | awk '{print $4}')
    # v6 listener shows as [::]:port, [::1]:port, [2404:...]:port, or *:port (dual-stack)
    if echo "$laddrs" | grep -qE '^\[|^\*:'; then
        pass "$label listening on IPv6 (port $port)"
    else
        fail "$code" "$label not listening on IPv6 (port $port) — found: ${laddrs:-none}"
    fi
}

# ---- HTTP(S) over IPv6 (forces -6; use a literal [addr] or a AAAA name) ----
# check_curl6 <url> <label> <code>   e.g. check_curl6 "https://[2404:...df10::80]/" "server" E13
check_curl6() {
    local url=$1 label=$2 code=$3 http
    http=$(curl -6 -sk -o /dev/null -w "%{http_code}" --max-time 8 -L "$url" 2>/dev/null)
    if [[ "$http" =~ ^[23] ]]; then pass "IPv6 HTTP $http from $label ($url)"
    else fail "$code" "No IPv6 HTTP from $label ($url) — code: ${http:-none}"; fi
}

# ---- Generic nftables rule presence (family-agnostic; whitespace-normalised) ----
# Accepts iif/iifname and oif/oifname by writing your regex with iif(name)? etc.
# check_nft6 '<extended-regex>' '<pass message>' <code>
check_nft6() {
    local re=$1 msg=$2 code=$3 norm
    norm=$(nft list ruleset 2>/dev/null | tr -s ' \t\n' ' ')
    if echo "$norm" | grep -qE "$re"; then pass "$msg"
    else
        fail "$code" "missing nft rule: $msg"
        echo -e "         ${CYAN}[DIAG] nft ruleset (head):${NC}"
        nft list ruleset 2>/dev/null | sed 's/^/                /' | head -40
    fi
}

# ---- DNS AAAA / reverse-v6 helpers (for the DNS/mail activities) ----
# check_aaaa <name> <server-or-empty> <code>   (server may be @host or blank for system resolver)
check_aaaa() {
    local name=$1 server=$2 code=$3 out
    out=$(dig +short ${server:+@$server} AAAA "$name" 2>/dev/null | grep -E ':' | head -1)
    if [ -n "$out" ]; then pass "AAAA $name ${server:+via $server} -> $out"
    else fail "$code" "no AAAA for $name ${server:+via $server}"; fi
}
# ============================================================================
#  END SHARED IPv6 HELPER BLOCK
# ============================================================================

# =============================================================================
# Detect VM
# =============================================================================
detect_vm() {
    if has_ip "192.168.1.1" && has_ip "10.10.1.254"; then
        echo "internal_gateway"
        return
    fi

    if has_ip "192.168.1.254"; then
        echo "external_gateway"
        return
    fi

    if command -v openvpn >/dev/null 2>&1; then
        echo "openvpn_client"
        return
    fi

    echo "unknown"
}

# =============================================================================
# Internal Gateway
# =============================================================================
run_internal_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: Internal Gateway${NC}"

    OPENVPN_CA="$USER_HOME/openvpn-ca"
    CLIENT_CONFIGS="$USER_HOME/client-configs"

    # -------------------------------------------------------------------------
    section "OpenVPN Installation"

    if command -v openvpn >/dev/null 2>&1; then
        pass "OpenVPN installed"
    else
        fail "E1" "OpenVPN not installed — run: sudo apt install openvpn -y"
    fi

    if [ -f "$OPENVPN_CA/easyrsa" ]; then
        pass "Easy-RSA present ($OPENVPN_CA/easyrsa)"
    else
        fail "E1" "Easy-RSA missing — expected at $OPENVPN_CA/easyrsa"
    fi

    if [ -f "$OPENVPN_CA/vars" ]; then
        pass "vars file present"
    else
        fail "E1" "vars file missing from $OPENVPN_CA/"
    fi

    # -------------------------------------------------------------------------
    section "PKI"

    if [ -d "$OPENVPN_CA/pki" ]; then
        pass "PKI directory exists"
    else
        fail "E2" "PKI not initialised — run: cd $OPENVPN_CA && ./easyrsa init-pki"
    fi

    if [ -f "$OPENVPN_CA/pki/ca.crt" ]; then
        pass "CA certificate exists"
    else
        fail "E2" "CA certificate missing — run: ./easyrsa build-ca"
    fi

    if [ -f "$OPENVPN_CA/pki/issued/server.crt" ]; then
        pass "Server certificate exists"
    else
        fail "E2" "Server certificate missing — run: ./easyrsa gen-req server nopass && ./easyrsa sign-req server server"
    fi

    if [ -f "$OPENVPN_CA/pki/private/server.key" ]; then
        pass "Server key exists"
    else
        fail "E2" "Server key missing — regenerate with: ./easyrsa gen-req server nopass"
    fi

    if [ -f "$OPENVPN_CA/pki/dh.pem" ]; then
        pass "DH parameters exist"
    else
        fail "E2" "DH parameters missing — run: ./easyrsa gen-dh (takes 1–3 min)"
    fi

    if [ -f "$OPENVPN_CA/ta.key" ]; then
        pass "TLS auth key exists"
    else
        fail "E2" "TLS auth key missing — run: openvpn --genkey secret $OPENVPN_CA/ta.key"
    fi

    # -------------------------------------------------------------------------
    section "Files Copied to /etc/openvpn"

    for f in ca.crt server.crt server.key dh2048.pem ta.key; do
        if [ -f "/etc/openvpn/$f" ]; then
            pass "$f present in /etc/openvpn"
        else
            fail "E3" "$f missing from /etc/openvpn — check the copy commands in Part B"
        fi
    done

    # -------------------------------------------------------------------------
    section "server.conf"

    if [ -f /etc/openvpn/server.conf ]; then
        pass "server.conf exists"

        CONF=$(cat /etc/openvpn/server.conf)

        for directive in \
            "port 1194" \
            "proto udp" \
            "dev tun" \
            "server 10.8.0.0" \
            "tls-auth ta.key"
        do
            if echo "$CONF" | grep -q "$directive"; then
                pass "  server.conf: '$directive' found"
            else
                fail "E4" "server.conf: '$directive' missing or commented out"
            fi
        done

    else
        fail "E4" "server.conf missing from /etc/openvpn — copy sample: sudo cp /usr/share/doc/openvpn/examples/sample-config-files/server.conf /etc/openvpn/"
    fi

    # -------------------------------------------------------------------------
    section "IP Forwarding"

    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
        pass "IP forwarding enabled (runtime)"
    else
        fail "E5" "IP forwarding disabled — run: sudo sysctl -w net.ipv4.ip_forward=1"
    fi

    if grep -Eq "net.ipv4.ip_forward *= *1" /etc/sysctl.conf; then
        pass "Persistent IP forwarding set in /etc/sysctl.conf"
    else
        fail "E5" "Persistent IP forwarding missing — add 'net.ipv4.ip_forward=1' to /etc/sysctl.conf then run: sudo sysctl -p"
    fi

    # -------------------------------------------------------------------------
    section "OpenVPN Service"

    if systemctl is-active --quiet openvpn@server; then
        pass "OpenVPN service active"
    else
        fail "E6" "OpenVPN service not running — check: sudo journalctl -u openvpn@server --no-pager | tail -30"
        info "Common causes: wrong certificate path, missing dh2048.pem, or /var/log/openvpn not created"
    fi

    if systemctl is-enabled --quiet openvpn@server; then
        pass "OpenVPN service enabled at boot"
    else
        fail "E6" "OpenVPN service not enabled — run: sudo systemctl enable openvpn@server"
    fi

    # -------------------------------------------------------------------------
    section "tun0 Interface"

    if ip addr show tun0 >/dev/null 2>&1; then
        TUNIP=$(ip -4 addr show tun0 | awk '/inet / {print $2}' | cut -d/ -f1 | tr -d '[:space:]')
        if [[ "$TUNIP" == "10.8.0.1" ]]; then
            pass "tun0 has correct IP (10.8.0.1)"
        else
            fail "E7" "tun0 has wrong IP ($TUNIP) — expected 10.8.0.1; check 'server' directive in server.conf"
        fi
    else
        fail "E7" "tun0 interface missing — OpenVPN service must be running to create it"
    fi

    # -------------------------------------------------------------------------
    section "Client Certificates"

    if [ -f "$OPENVPN_CA/pki/issued/client1.crt" ]; then
        pass "client1.crt exists"
    else
        fail "E8" "client1.crt missing — run: ./easyrsa gen-req client1 nopass && ./easyrsa sign-req client client1"
    fi

    if [ -f "$OPENVPN_CA/pki/private/client1.key" ]; then
        pass "client1.key exists"
    else
        fail "E8" "client1.key missing — regenerate with: ./easyrsa gen-req client1 nopass"
    fi

    if [ -f "$CLIENT_CONFIGS/files/client1.ovpn" ]; then
        pass "client1.ovpn bundle exists"
    else
        fail "E8" "client1.ovpn missing from $CLIENT_CONFIGS/files/ — run make_config.sh and check all keys are in ~/client-configs/keys/"
    fi

    if [ -f "$CLIENT_CONFIGS/base.conf" ]; then
        REMOTE=$(grep '^remote ' "$CLIENT_CONFIGS/base.conf")
        if echo "$REMOTE" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
            pass "base.conf 'remote' IP configured"
        else
            fail "E8" "base.conf 'remote' IP not set — replace [ETH0_IP] with the External Gateway's eth0 IP"
        fi
    else
        fail "E8" "base.conf missing from $CLIENT_CONFIGS/ — copy sample client config and edit it"
    fi

    # =========================================================================
    # ============================  IPv6 TEST LAYER  ==========================
    # Mirrors the IPv4 checks above using the lab's routed /56
    # (2404:9400:29c1:df00::/56). Non-destructive / read-only.
    # This VM is the OpenVPN SERVER (the ExtGW DNATs UDP 1194 here → 192.168.1.1).
    # =========================================================================
    section "IPv6 Addressing"
    # Internal Gateway: eth0 = DMZ side, eth1 = internal side (mirrors 192.168.1.1 / 10.10.1.254)
    check_ip6 eth0 "2404:9400:29c1:df10::1/64"   E11
    check_ip6 eth1 "2404:9400:29c1:df20::254/64" E11

    section "IPv6 Routing"
    # Default v6 route to the internet is via the External Gateway (DMZ side)
    check_route6_get "2001:4860:4860::8888" "via 2404:9400:29c1:df10::254" E12 "internet (via ExtGW ::df10::254)"

    section "IPv6 Forwarding"
    check_ip6_forward E13

    section "IPv6 Connectivity"
    check_ping6 "2404:9400:29c1:df10::254" "External Gateway (DMZ)" E15
    check_ping6 "2404:9400:29c1:df10::80"  "Ubuntu Server"          E15
    check_ping6 "2404:9400:29c1:df20::1"   "Ubuntu Desktop"         E15

    section "IPv6 Internet"
    check_internet6 E16

    section "IPv6 — OpenVPN server transport"
    # ASSUMPTION: the supplied server.conf is IPv4-only ('proto udp' + 'server 10.8.0.0').
    # Every item below is SOFT — it only fails when server.conf actually shows IPv6 intent.
    SRVCONF="/etc/openvpn/server.conf"
    if [ -f "$SRVCONF" ] && grep -Eq '^[[:space:]]*(proto[[:space:]]+udp6|proto[[:space:]]+tcp6|server-ipv6|tun-ipv6)' "$SRVCONF"; then
        info "server.conf shows IPv6 intent — enforcing OpenVPN IPv6 checks"
        # ASSUMPTION: a v6-configured server listens on an IPv6 transport for 1194
        check_listen6 1194 "OpenVPN server" E17
        # ASSUMPTION: tun0 carries a global IPv6 (from the server-ipv6 pool); exact subnet unknown
        check_ip6_has_global tun0 E11
        # ASSUMPTION: connected clients sit at <tun0-prefix>::1000+ ; best-effort ping of one
        TUN6NET=$(ip -6 route show dev tun0 2>/dev/null | awk '/\/64/{print $1; exit}')
        if [ -n "$TUN6NET" ]; then
            PEER6="${TUN6NET%::/64}::1000"
            info "ASSUMPTION: pinging first VPN client across the tunnel ($PEER6)"
            check_ping6 "$PEER6" "VPN client over tunnel" E15
        else
            warn "tun0 has no IPv6 /64 route — cannot derive a tunnel peer to ping6 (skipped)"
        fi
    else
        warn "server.conf has no IPv6 directive (proto udp6 / server-ipv6 / tun-ipv6) — OpenVPN IPv6 transport not configured; skipping v6 VPN checks"
        info "ASSUMPTION: to enable, add e.g. 'proto udp6' and 'server-ipv6 2404:9400:29c1:dfXX::/64' to server.conf"
    fi
}

# =============================================================================
# External Gateway
# =============================================================================
run_external_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: External Gateway${NC}"

    RULESET=$(nft list ruleset 2>/dev/null)

    section "nftables — UDP 1194 Rules"

    if echo "$RULESET" | grep -q "udp dport 1194"; then
        pass "UDP 1194 forward rule present"
    else
        fail "E9" "UDP 1194 forward rule missing — add to forward chain: iif \"eth0\" oif \"eth1\" udp dport 1194 ct state new accept"
    fi

    if echo "$RULESET" | grep -q "dnat to 192.168.1.1"; then
        pass "DNAT rule present (→ 192.168.1.1)"
    else
        fail "E9" "DNAT rule missing — add to prerouting chain: iif \"eth0\" udp dport 1194 dnat to 192.168.1.1"
    fi

    if echo "$RULESET" | grep -q "snat to 192.168.1.254"; then
        pass "SNAT rule present (→ 192.168.1.254)"
    else
        fail "E9" "SNAT rule missing — add to postrouting chain: oif \"eth1\" udp dport 1194 snat to 192.168.1.254"
    fi

    section "Existing Rules (regression check)"

    if echo "$RULESET" | grep -qE 'tcp dport (80|\{ 80, 443|25)'; then
        pass "Previous activity port rules still present"
    else
        warn "HTTP/HTTPS/SMTP forward rules may be missing — verify Activity 4-1 rules were not overwritten"
    fi

    # =========================================================================
    # ============================  IPv6 TEST LAYER  ==========================
    # Mirrors the IPv4 path using the lab's routed /56 (2404:9400:29c1:df00::/56).
    # Non-destructive / read-only.
    # =========================================================================
    section "IPv6 Addressing"
    # ASSUMPTION: ExtGW carries the transit /64 on wg0 and the DMZ /64 on eth1 (lab-wide table)
    check_ip6 wg0  "2404:9400:29c1:df00::1/64"   E11
    check_ip6 eth1 "2404:9400:29c1:df10::254/64" E11

    section "IPv6 Routing"
    # Default v6 route to the internet leaves via the tunnel (wg0); lives in table 51820
    check_route6_get "2001:4860:4860::8888" "dev wg0" E12 "internet (dev wg0)"
    # Route to an internal /64 host goes via the Internal Gateway (DMZ side)
    check_route6_get "2404:9400:29c1:df20::1" "via 2404:9400:29c1:df10::1" E12 "internal ::df20::1 (via IntGW)"

    section "IPv6 Forwarding"
    check_ip6_forward E13

    section "IPv6 Connectivity"
    check_ping6 "2404:9400:29c1:df10::1"  "Internal Gateway (DMZ)" E15
    check_ping6 "2404:9400:29c1:df10::80" "Ubuntu Server"          E15
    check_ping6 "2404:9400:29c1:df20::1"  "Ubuntu Desktop"         E15

    section "IPv6 Internet"
    check_internet6 E16

    section "IPv6 — Tunnel services"
    # ASSUMPTION: the lab-wide IPv6 uplink rides a wg0 tunnel; only checked if wg0 exists.
    if ip link show wg0 >/dev/null 2>&1; then
        if systemctl is-active --quiet wg-quick@wg0; then
            pass "wg-quick@wg0 active"
        else
            fail "E11" "wg-quick@wg0 not active — the IPv6 uplink tunnel is down"
        fi
        if command -v wg >/dev/null 2>&1; then
            HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
            if [[ "$HS" =~ ^[0-9]+$ ]] && [ "$HS" -gt 0 ]; then
                pass "WireGuard handshake present on wg0 (latest=$HS)"
            else
                warn "no WireGuard handshake on wg0 yet (latest-handshakes=0) — tunnel may be idle"
            fi
        fi
        if systemctl list-unit-files 2>/dev/null | grep -q 'wstunnel'; then
            if systemctl is-active --quiet 'wstunnel*' 2>/dev/null; then
                pass "wstunnel client active"
            else
                warn "wstunnel client not active (ASSUMPTION: only relevant if the lab uses wstunnel)"
            fi
        fi
    else
        warn "wg0 interface absent — this ExtGW may not run the lab IPv6 tunnel; skipping tunnel checks (ASSUMPTION)"
    fi

    section "IPv6 — nftables UDP 1194"
    # Mirror of the IPv4 UDP 1194 path. In IPv4 this activity uses DNAT→192.168.1.1 + SNAT.
    # ASSUMPTION: over IPv6 the lab routes natively (no NAT), so the mirrored v6 rule is a
    # plain forward ACCEPT of 'udp dport 1194' toward the server in the ip6/inet family.
    # nft rule check accepts both iif/iifname and oif/oifname.
    check_nft6 'table (ip6|inet).*(iif(name)?|oif(name)?)?[^}]*udp dport 1194[^}]*accept' \
               "IPv6 forward accept for UDP 1194 present (ip6/inet family)" E14
}

# =============================================================================
# OpenVPN Client VM
# =============================================================================
run_openvpn_client() {
    echo -e "\n${BOLD}${CYAN}VM detected: OpenVPN Client${NC}"

    section "OpenVPN Installation"

    if command -v openvpn >/dev/null 2>&1; then
        pass "OpenVPN installed"
    else
        fail "E10" "OpenVPN not installed — run: sudo apt install openvpn -y"
    fi

    if [ -f "$USER_HOME/client1.ovpn" ]; then
        pass "client1.ovpn present in home directory"
    else
        fail "E8" "client1.ovpn missing — copy it from the Internal Gateway to ~/"
    fi

    section "VPN Connection"

    if ip addr show tun0 >/dev/null 2>&1; then
        TUNIP=$(ip addr show tun0 | grep inet | awk '{print $2}' | cut -d/ -f1)
        if echo "$TUNIP" | grep -q "^10.8.0\."; then
            pass "tun0 connected with IP $TUNIP"
        else
            fail "E10" "tun0 exists but has unexpected IP ($TUNIP) — expected 10.8.0.x"
        fi

        if ping -c 2 10.8.0.1 >/dev/null 2>&1; then
            pass "Ping to Internal Gateway (10.8.0.1) successful"
        else
            fail "E10" "Cannot ping 10.8.0.1 — check nftables UDP 1194 rules on External Gateway (E9)"
        fi
    else
        fail "E10" "VPN not connected (tun0 absent) — check remote IP in client1.ovpn matches current External Gateway eth0 IP"
        info "Connect via terminal: sudo openvpn --config ~/client1.ovpn"
        info "Check TLS auth direction: server.conf must use 'tls-auth ta.key 0', base.conf must use 'tls-auth ta.key 1'"
    fi

    # =========================================================================
    # ============================  IPv6 TEST LAYER  ==========================
    # Non-destructive / read-only. The supplied client1.ovpn is IPv4-only
    # ('proto udp' + IPv4 'remote'), so the VPN-over-IPv6 checks are SOFT.
    # =========================================================================
    section "IPv6 — VPN over IPv6 (across the tunnel)"
    OVPN="$USER_HOME/client1.ovpn"
    if [ -f "$OVPN" ] && grep -Eiq '^[[:space:]]*proto[[:space:]]+(udp6|tcp6)|^[[:space:]]*remote[[:space:]]+[0-9a-f]*:[0-9a-f:]+' "$OVPN"; then
        info "client1.ovpn shows IPv6 intent — enforcing IPv6 tunnel checks"
        if ip addr show tun0 >/dev/null 2>&1; then
            # ASSUMPTION: tun0 receives a global IPv6 from the server's server-ipv6 pool
            check_ip6_has_global tun0 E11
            # ASSUMPTION: the server end of the tunnel is <tun0-prefix>::1
            TUN6NET=$(ip -6 route show dev tun0 2>/dev/null | awk '/\/64/{print $1; exit}')
            if [ -n "$TUN6NET" ]; then
                PEER6="${TUN6NET%::/64}::1"
                info "ASSUMPTION: pinging the OpenVPN server end of the tunnel ($PEER6)"
                check_ping6 "$PEER6" "OpenVPN server over tunnel" E15
            else
                warn "tun0 has no IPv6 /64 route — cannot derive the server tunnel address (skipped)"
            fi
        else
            fail "E15" "tun0 absent — cannot verify IPv6 across the tunnel (VPN not connected)"
        fi
    else
        warn "client1.ovpn has no IPv6 directive (proto udp6 / IPv6 remote) — VPN-over-IPv6 not configured; skipping (ASSUMPTION)"
        info "ASSUMPTION: to test, the server must push an IPv6 tunnel (server-ipv6) and the client use an IPv6 transport"
    fi

    section "IPv6 Internet (host)"
    check_internet6 E16
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} Summary${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  Passed : ${GREEN}${PASS}${NC}"
    echo -e "  Failed : ${RED}${FAIL}${NC}"

    if [ ${#ERRORS[@]} -gt 0 ]; then
        local unique_errors
        unique_errors=$(printf '%s\n' "${ERRORS[@]}" | sort -u | tr '\n' ' ')
        echo ""
        echo -e "  ${RED}${BOLD}Errors detected: $unique_errors${NC}"
        echo -e "  ${YELLOW}Refer to the Troubleshooting section of the Activity 4-2 guide.${NC}"
        echo ""
    else
        echo ""
        echo -e "  ${GREEN}${BOLD}All checks passed! Activity 4-2 configuration looks correct.${NC}"
        echo ""
    fi
}

# =============================================================================
# Main
# =============================================================================
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Activity 4-2 Automarker — VPN with OpenVPN${NC}"
echo -e "${BOLD} 7015ICT | Griffith University${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

VM=$(detect_vm)

case "$VM" in
    internal_gateway) run_internal_gateway ;;
    external_gateway) run_external_gateway ;;
    openvpn_client)   run_openvpn_client ;;
    *)
        echo ""
        echo -e "${RED}[ERROR]${NC} Could not detect which VM this is."
        echo ""
        echo "        Expected IP addresses:"
        echo "          Internal Gateway — eth0 at 192.168.1.1 AND eth1 at 10.10.1.254"
        echo "          External Gateway — eth1 at 192.168.1.254"
        echo "          OpenVPN Client   — openvpn command present"
        echo ""
        echo "        Your current addresses:"
        ip -brief addr show 2>/dev/null | sed 's/^/          /'
        exit 1
        ;;
esac

print_summary
