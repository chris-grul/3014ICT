#!/bin/bash
# =============================================================================
# Automarking Script - Activity 1: DMZ Networks  (IPv6-augmented)
# 7015ICT - Cyber Security Operation Centres | Griffith University
# =============================================================================
# Run this script on any of the lab VMs after completing the activity.
# The script will auto-detect which VM it is running on and perform the
# appropriate checks. Any failures are reported as numbered error codes
# that you can look up in the Troubleshooting section of the activity guide.
#
# This is the IPv6-augmented copy of the Activity 1 automarker: every original
# IPv4 check is retained unchanged, and an additional IPv6 test layer mirrors
# each one. It can also run on the Remote Gateway (BinaryLane VM) — the IPv6
# tunnel endpoint, public IPv4 112.213.39.252.
#
# Error Code Reference:
#   E1  — IP address wrong or missing
#   E2  — Network interface missing
#   E3  — Routing / IP forwarding wrong on a gateway
#   E4  — nftables rules wrong, missing, or not applied
#   E5  — Cannot reach another VM or subnet
#   E6  — No IPv4 internet access
#   E7  — nftables service not running
#
#   --- IPv6 test layer (mirrors the IPv4 checks above) ---
#   E8  — IPv6 address wrong or missing on an interface
#   E9  — IPv6 route wrong or missing (route-get / default gateway)
#   E10 — IPv6 forwarding disabled on a gateway
#   E11 — IPv6 nftables rules wrong, missing, or not applied
#   E12 — Cannot reach another VM over IPv6 (ping6)
#   E13 — No IPv6 internet access
#   E14 — IPv6 tunnel service failing (wstunnel/wg-quick not active, or no
#         WireGuard handshake on wg0)
#
# Usage: sudo ./automark_activity1_ipv6.sh
# =============================================================================

# --- Enforce root ---
if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "  [ERROR] This script must be run with sudo."
    echo "          Usage: sudo ./automark_activity1_ipv6.sh"
    echo ""
    exit 1
fi

# --- Colour codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
ERRORS=()

# =============================================================================
# Helper functions
# =============================================================================

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    ((PASS++))
}

fail() {
    local code=$1
    local msg=$2
    echo -e "  ${RED}[FAIL]${NC} $msg"
    echo -e "         ${YELLOW}→ Error $code${NC}"
    ERRORS+=("$code")
    ((FAIL++))
}

info() {
    echo -e "  ${CYAN}[INFO]${NC} $1"
}

section() {
    echo ""
    echo -e "${BOLD}--- $1 ---${NC}"
}

# Print a short diagnostic snapshot — shown automatically on relevant failures
diag_ip() {
    echo -e "         ${CYAN}[DIAG] Current addresses:${NC}"
    ip -brief addr show 2>/dev/null | sed 's/^/                /'
}

diag_routes() {
    echo -e "         ${CYAN}[DIAG] Current routes:${NC}"
    ip route show 2>/dev/null | sed 's/^/                /'
}

diag_nft() {
    echo -e "         ${CYAN}[DIAG] Current nft ruleset:${NC}"
    nft list ruleset 2>/dev/null | sed 's/^/                /' | head -40
}

# Check if an IP address (without prefix) is assigned to any interface
has_ip() {
    ip addr show 2>/dev/null | grep -q "inet $1"
}

# =============================================================================
# Detect which VM this is
# =============================================================================

detect_vm() {
    if has_ip "112.213.39.252"; then
        echo "remote_gateway"
    elif has_ip "192.168.1.254"; then
        echo "external_gateway"
    elif has_ip "192.168.1.1" && has_ip "10.10.1.254"; then
        echo "internal_gateway"
    elif has_ip "192.168.1.80"; then
        echo "ubuntu_server"
    elif has_ip "10.10.1.1"; then
        echo "ubuntu_desktop"
    else
        echo "unknown"
    fi
}

# =============================================================================
# Check functions (shared)
# =============================================================================

check_iface_exists() {
    local iface=$1
    local error_code=$2
    if ip link show "$iface" &>/dev/null; then
        pass "Interface $iface exists"
    else
        fail "$error_code" "Interface $iface not found (check Hyper-V adapter assignment)"
        info "Available interfaces: $(ip -brief link show | awk '{print $1}' | tr '\n' ' ')"
    fi
}

check_ip() {
    local iface=$1
    local expected_cidr=$2
    local error_code=$3
    local label="$iface = $expected_cidr"

    if ip addr show "$iface" 2>/dev/null | grep -q "inet $expected_cidr"; then
        pass "$label"
    else
        local actual
        actual=$(ip addr show "$iface" 2>/dev/null | grep "inet " | awk '{print $2}')
        fail "$error_code" "$label  (found: ${actual:-none})"
        diag_ip
    fi
}

check_default_route() {
    local expected_via=$1
    local error_code=$2

    if ip route show default | grep -q "via $expected_via"; then
        pass "Default route via $expected_via"
    else
        local actual
        actual=$(ip route show default)
        fail "$error_code" "Default route via $expected_via  (found: ${actual:-none})"
        diag_routes
    fi
}

check_static_route() {
    local dest=$1
    local via=$2
    local error_code=$3

    if ip route show | grep -q "$dest.*via $via\|$dest.*$via"; then
        pass "Route to $dest via $via"
    else
        fail "$error_code" "Route to $dest via $via not found"
        diag_routes
    fi
}

check_ip_forward() {
    local error_code=$1
    local val
    val=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    if [ "$val" = "1" ]; then
        pass "IP forwarding enabled (net.ipv4.ip_forward = 1)"
    else
        fail "$error_code" "IP forwarding not enabled (value: ${val:-unreadable})"
    fi
}

check_ping() {
    local target=$1
    local label=$2
    local error_code=$3

    if ping -c 2 -W 2 "$target" &>/dev/null; then
        pass "Ping $label ($target)"
    else
        fail "$error_code" "Cannot ping $label ($target)"
    fi
}

check_curl() {
    local url=$1
    local label=$2
    local error_code=$3

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
    if [[ "$http_code" =~ ^[23] ]]; then
        pass "HTTP $http_code from $label ($url)"
    else
        fail "$error_code" "Cannot reach $label ($url) — HTTP code: ${http_code:-no response}"
    fi
}

# Robust internet check: tries multiple HTTPS URLs, passes if any one succeeds
check_internet() {
    local error_code=$1
    local urls=(
        "https://example.com"
        "https://www.google.com"
        "https://1.1.1.1"
    )

    for url in "${urls[@]}"; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 -L "$url" 2>/dev/null)
        if [[ "$http_code" =~ ^[23] ]]; then
            pass "Internet access confirmed (HTTP $http_code from $url)"
            return
        fi
    done

    fail "$error_code" "No internet access — tried ${urls[*]}"
}

check_nftables_service() {
    local error_code=$1
    if systemctl is-active --quiet nftables 2>/dev/null; then
        pass "nftables service is active"
    else
        fail "$error_code" "nftables service is not running"
    fi
}

# --- Tight nftables rule checks ---
check_nft_forward_dmz_to_inet() {
    local error_code=$1
    local ruleset
    ruleset=$(nft list ruleset 2>/dev/null)

    local normalised
    normalised=$(echo "$ruleset" | tr -s ' \t\n' ' ')

    if echo "$normalised" | grep -qE 'iif[[:space:]]+"eth1"[[:space:]]+oif[[:space:]]+"eth0"[[:space:]]+accept'; then
        pass "nftables forward rule: iif eth1 oif eth0 accept"
    else
        fail "$error_code" "Missing forward rule: iif \"eth1\" oif \"eth0\" accept"
        diag_nft
    fi
}

check_nft_forward_return_traffic() {
    local error_code=$1
    local ruleset
    ruleset=$(nft list ruleset 2>/dev/null)
    local normalised
    normalised=$(echo "$ruleset" | tr -s ' \t\n' ' ')

    if echo "$normalised" | grep -qE 'iif[[:space:]]+"eth0"[[:space:]]+oif[[:space:]]+"eth1"[[:space:]]+(ct state|ct state established)'; then
        pass "nftables forward rule: iif eth0 oif eth1 ct state established,related accept"
    else
        fail "$error_code" "Missing return-traffic rule: iif \"eth0\" oif \"eth1\" ct state established,related accept"
        diag_nft
    fi
}

check_nft_nat_masquerade() {
    local error_code=$1
    local ruleset
    ruleset=$(nft list ruleset 2>/dev/null)
    local normalised
    normalised=$(echo "$ruleset" | tr -s ' \t\n' ' ')

    if echo "$normalised" | grep -qE 'oif[[:space:]]+"eth0"[[:space:]]+masquerade'; then
        pass "nftables NAT masquerade: oif eth0 masquerade"
    else
        if echo "$normalised" | grep -q "masquerade"; then
            fail "$error_code" "masquerade found but NOT on eth0 — check your oif interface name"
        else
            fail "$error_code" "nftables NAT masquerade rule missing entirely"
        fi
        diag_nft
    fi
}

# ============================================================================
#  SHARED IPv6 HELPER BLOCK  —  paste verbatim into each automarker, placed
#  AFTER the existing helper/check functions and BEFORE the run_<vm>() funcs.
#  These names are unique and won't clash with existing helpers. They reuse the
#  script's existing pass()/fail()/section()/CYAN/NC.
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

# =============================================================================
# Per-VM check suites
# =============================================================================

run_remote_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: Remote Gateway (BinaryLane VM — IPv6 uplink)${NC}"

    section "Network Interfaces"
    for _i in eth0 wg0; do
        if ip link show "$_i" &>/dev/null; then pass "Interface $_i exists"
        else fail "E8" "Interface $_i not found"; fi
    done

    section "IPv4 Addressing"
    if has_ip "112.213.39.252"; then pass "eth0 has public IPv4 (112.213.39.252)"
    else fail "E8" "public IPv4 112.213.39.252 not found"; fi

    section "IPv6 Addressing"
    check_ip6 "wg0" "2404:9400:29c1:df00::254/64" "E8"
    check_ip6_has_global "eth0" "E8"

    section "IPv6 Routing"
    check_route6_get "2404:9400:29c1:df10::80" "dev wg0"  "E9" "lab /56 (down the tunnel)"
    check_route6_get "2001:4860:4860::8888"    "dev eth0" "E9" "internet (own uplink)"

    section "IPv6 Forwarding"
    check_ip6_forward "E10"

    section "Tunnel Services"
    for _svc in wstunnel-server wg-quick@wg0; do
        if systemctl is-active --quiet "$_svc" 2>/dev/null; then pass "service $_svc is active"
        else fail "E14" "service $_svc is not active"; fi
    done
    _hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -1)
    if [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null; then
        pass "WireGuard handshake present ($(( $(date +%s) - _hs ))s ago)"
    else fail "E14" "no WireGuard handshake on wg0 — tunnel not established"; fi

    section "IPv6 Connectivity — Lab"
    check_ping6 "2404:9400:29c1:df00::1"  "External Gateway (wg0)" "E12"
    check_ping6 "2404:9400:29c1:df10::80" "Ubuntu Server"          "E12"
    check_ping6 "2404:9400:29c1:df20::1"  "Ubuntu Desktop"         "E12"

    section "IPv6 Internet Access"
    check_internet6 "E13"
}

run_external_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: External Gateway${NC}"

    section "Network Interfaces"
    check_iface_exists "eth0" "E2"
    check_iface_exists "eth1" "E2"

    section "IP Addressing"
    local eth0_ip
    eth0_ip=$(ip addr show eth0 2>/dev/null | grep "inet " | awk '{print $2}')
    if [ -n "$eth0_ip" ]; then
        pass "eth0 has DHCP-assigned address ($eth0_ip)"
    else
        fail "E1" "eth0 has no IP address (DHCP may have failed)"
        diag_ip
    fi
    check_ip "eth1" "192.168.1.254/24" "E1"

    section "Routing"
    check_static_route "10.10.1.0/24" "192.168.1.1" "E3"

    section "IP Forwarding"
    check_ip_forward "E3"

    section "nftables Service"
    check_nftables_service "E7"

    section "nftables Forward Rules"
    check_nft_forward_dmz_to_inet "E4"
    check_nft_forward_return_traffic "E4"

    section "nftables NAT Rule"
    check_nft_nat_masquerade "E4"

    section "Connectivity — DMZ"
    check_ping "192.168.1.1"  "Internal Gateway (DMZ side)" "E5"
    check_ping "192.168.1.80" "Ubuntu Server"               "E5"

    section "Connectivity — Internal"
    check_ping "10.10.1.1"   "Ubuntu Desktop"                   "E5"
    check_ping "10.10.1.254" "Internal Gateway (internal side)" "E5"

    section "Internet Access"
    check_internet "E6"

    # =========================================================================
    # IPv6 test layer — mirrors the IPv4 checks above (External Gateway)
    # =========================================================================

    section "IPv6 Addressing (E8)"
    check_ip6 wg0  "2404:9400:29c1:df00::1/64"   "E8"   # transit-side v6 on wg0 tunnel
    check_ip6 eth1 "2404:9400:29c1:df10::254/64" "E8"   # DMZ-side v6 on eth1

    section "IPv6 Forwarding (E10)"
    check_ip6_forward "E10"

    section "IPv6 Routing (E9)"
    check_route6_get "2001:4860:4860::8888"    "dev wg0"                    "E9" "internet (via wg0 tunnel)"
    check_route6_get "2404:9400:29c1:df20::1"  "via 2404:9400:29c1:df10::1" "E9" "internal (Desktop via IntGW)"

    section "IPv6 nftables — Forward eth1<->wg0 (E11)"
    check_nft6 'iif(name)? "eth1" oif(name)? "wg0" accept' \
        "IPv6/inet forward accept: eth1 -> wg0 (DMZ to tunnel)" "E11"
    check_nft6 'iif(name)? "wg0" oif(name)? "eth1" accept' \
        "IPv6/inet forward accept: wg0 -> eth1 (tunnel to DMZ)" "E11"

    section "Tunnel Services (E14)"
    for _svc in wstunnel-client wg-quick@wg0; do
        if systemctl is-active --quiet "$_svc" 2>/dev/null; then pass "service $_svc is active"
        else fail "E14" "service $_svc is not active"; fi
    done
    _hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -1)
    if [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null; then
        pass "WireGuard handshake present ($(( $(date +%s) - _hs ))s ago)"
    else fail "E14" "no WireGuard handshake on wg0 — tunnel not established"; fi

    section "IPv6 Connectivity (E12)"
    check_ping6 "2404:9400:29c1:df00::254" "Remote Gateway (wg0)"        "E12"
    check_ping6 "2404:9400:29c1:df10::1"   "Internal Gateway (DMZ side)" "E12"
    check_ping6 "2404:9400:29c1:df10::80"  "Ubuntu Server"               "E12"
    check_ping6 "2404:9400:29c1:df20::1"   "Ubuntu Desktop"              "E12"

    section "IPv6 Internet Access (E13)"
    check_internet6 "E13"
}

run_internal_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: Internal Gateway${NC}"

    section "Network Interfaces"
    check_iface_exists "eth0" "E2"
    check_iface_exists "eth1" "E2"

    section "IP Addressing"
    check_ip "eth0" "192.168.1.1/24"  "E1"
    check_ip "eth1" "10.10.1.254/24"  "E1"

    section "Routing"
    check_default_route "192.168.1.254" "E3"

    section "IP Forwarding"
    check_ip_forward "E3"

    section "Connectivity — DMZ"
    check_ping "192.168.1.254" "External Gateway (DMZ side)" "E5"
    check_ping "192.168.1.80"  "Ubuntu Server"               "E5"

    section "Connectivity — Internal"
    check_ping "10.10.1.1" "Ubuntu Desktop" "E5"

    section "Internet Access"
    check_internet "E6"

    # =========================================================================
    # IPv6 test layer — mirrors the IPv4 checks above (Internal Gateway)
    # =========================================================================

    section "IPv6 Addressing (E8)"
    check_ip6 eth0 "2404:9400:29c1:df10::1/64"   "E8"   # DMZ side
    check_ip6 eth1 "2404:9400:29c1:df20::254/64" "E8"   # internal side

    section "IPv6 Forwarding (E10)"
    check_ip6_forward "E10"

    section "IPv6 Routing (E9)"
    check_route6_get "2001:4860:4860::8888" "via 2404:9400:29c1:df10::254" "E9" "internet (via ExtGW)"

    section "IPv6 Connectivity (E12)"
    check_ping6 "2404:9400:29c1:df10::254" "External Gateway" "E12"
    check_ping6 "2404:9400:29c1:df10::80"  "Ubuntu Server"    "E12"
    check_ping6 "2404:9400:29c1:df20::1"   "Ubuntu Desktop"   "E12"

    section "IPv6 Internet Access (E13)"
    check_internet6 "E13"
}

run_ubuntu_server() {
    echo -e "\n${BOLD}${CYAN}VM detected: Ubuntu Server (DMZ Web Server)${NC}"

    section "Network Interfaces"
    check_iface_exists "eth0" "E1"

    section "IP Addressing"
    check_ip "eth0" "192.168.1.80/24" "E1"

    section "Routing"
    check_default_route "192.168.1.254" "E3"

    section "Connectivity — DMZ Gateways"
    check_ping "192.168.1.254" "External Gateway (DMZ side)" "E5"
    check_ping "192.168.1.1"   "Internal Gateway (DMZ side)" "E5"

    section "Internet Access"
    check_internet "E6"

    # =========================================================================
    # IPv6 test layer — mirrors the IPv4 checks above (Ubuntu Server)
    # =========================================================================

    section "IPv6 Addressing (E8)"
    check_ip6 eth0 "2404:9400:29c1:df10::80/64" "E8"

    section "IPv6 Routing (E9)"
    check_route6_get "2001:4860:4860::8888" "via 2404:9400:29c1:df10::254" "E9" "internet (default via ExtGW)"

    section "IPv6 Connectivity (E12)"
    check_ping6 "2404:9400:29c1:df10::254" "External Gateway (DMZ side)" "E12"
    check_ping6 "2404:9400:29c1:df10::1"   "Internal Gateway (DMZ side)" "E12"

    section "IPv6 Internet Access (E13)"
    check_internet6 "E13"
}

run_ubuntu_desktop() {
    echo -e "\n${BOLD}${CYAN}VM detected: Ubuntu Desktop (Internal Client)${NC}"

    section "Network Interfaces"
    check_iface_exists "eth0" "E1"

    section "IP Addressing"
    check_ip "eth0" "10.10.1.1/24" "E1"

    section "Routing"
    check_default_route "10.10.1.254" "E3"

    section "Connectivity — Internal Gateway"
    check_ping "10.10.1.254" "Internal Gateway (internal side)" "E5"

    section "Connectivity — DMZ"
    check_ping "192.168.1.1"  "Internal Gateway (DMZ side)" "E5"
    check_ping "192.168.1.80" "Ubuntu Server (DMZ)"         "E5"

    section "Internet Access"
    check_internet "E6"

    # =========================================================================
    # IPv6 test layer — mirrors the IPv4 checks above (Ubuntu Desktop)
    # =========================================================================

    section "IPv6 Addressing (E8)"
    check_ip6 eth0 "2404:9400:29c1:df20::1/64" "E8"

    section "IPv6 Routing (E9)"
    check_route6_get "2001:4860:4860::8888" "via 2404:9400:29c1:df20::254" "E9" "internet (default via IntGW)"

    section "IPv6 Connectivity (E12)"
    check_ping6 "2404:9400:29c1:df20::254" "Internal Gateway (internal side)" "E12"
    check_ping6 "2404:9400:29c1:df10::1"   "Internal Gateway (DMZ side)"      "E12"
    check_ping6 "2404:9400:29c1:df10::80"  "Ubuntu Server (DMZ)"              "E12"

    section "IPv6 Internet Access (E13)"
    check_internet6 "E13"
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
        echo -e "  ${YELLOW}Refer to the Troubleshooting section of the activity guide.${NC}"
        echo ""
    else
        echo ""
        echo -e "  ${GREEN}${BOLD}All checks passed! Activity 1 configuration looks correct.${NC}"
        echo ""
    fi
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Activity 1 Automarker — DMZ Networks (IPv6-augmented)${NC}"
echo -e "${BOLD} 7015ICT Cyber Security Operation Centres | Griffith University${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

VM=$(detect_vm)

case "$VM" in
    remote_gateway)    run_remote_gateway ;;
    external_gateway)  run_external_gateway ;;
    internal_gateway)  run_internal_gateway ;;
    ubuntu_server)     run_ubuntu_server ;;
    ubuntu_desktop)    run_ubuntu_desktop ;;
    *)
        echo ""
        echo -e "${RED}[ERROR]${NC} Could not detect which VM this is."
        echo ""
        echo "        Expected IP addresses:"
        echo "          Remote Gateway    — public IPv4 112.213.39.252"
        echo "          External Gateway  — eth1 at 192.168.1.254"
        echo "          Internal Gateway  — eth0 at 192.168.1.1 AND eth1 at 10.10.1.254"
        echo "          Ubuntu Server     — eth0 at 192.168.1.80"
        echo "          Ubuntu Desktop    — eth0 at 10.10.1.1"
        echo ""
        echo "        Your current addresses:"
        ip -brief addr show 2>/dev/null | sed 's/^/          /'
        echo ""
        echo "        If no IPs are assigned, start with Error E1 in the guide."
        echo "        If IPs look correct but detection failed, check for typos"
        echo "        in your netplan config and run: sudo netplan apply"
        exit 1
        ;;
esac

print_summary
