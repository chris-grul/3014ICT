#!/bin/bash
# =============================================================================
# Automarking Script - Activity 4-1: Firewalls with nftables
# 7015ICT | Griffith University
# =============================================================================
# Run on External Gateway only.
# The script auto-detects which VM it is running on and exits if incorrect.
#
# Error code reference (see Activity 4-1 guide Troubleshooting section):
#   E1  — nftables service not running or not enabled
#   E2  — Default-drop policy missing on input, output, or forward chain
#   E3  — Output chain missing ct state new accept — gateway cannot initiate connections
#   E4  — Port 25 (SMTP) forward or DNAT rule missing
#   E5  — Port 80 (HTTP) forward or DNAT rule missing
#   E6  — Port 443 (HTTPS) forward or DNAT rule missing
#   E7  — DNS forwarding rules missing from forward chain
#   E8  — Masquerade rule missing — internal hosts cannot reach internet
#   E9  — SNAT rules missing — web/mail return traffic may route incorrectly
#   E10 — nftables rules not persistent — ruleset lost after reboot
#   E11 — Loopback not accepted — gateway services may break
#   E12 — Established/related traffic not accepted — return traffic dropped
#
#   --- IPv6 test layer (additive; mirrors the IPv4 checks above, read-only) ---
#   E13 — IPv6 addressing missing/incorrect (wg0 df00::1 / eth1 df10::254)
#   E14 — IPv6 routing incorrect (internet 'dev wg0' / internal 'via …df10::1')
#   E15 — IPv6 forwarding not enabled (net.ipv6.conf.all.forwarding)
#   E16 — IPv6 nftables rule missing (v6 default-drop / estab / loopback /
#         ICMPv6 nd+echo / DMZ→uplink forward / inbound 80,443,25 forward)
#   E17 — IPv6 connectivity failed (ping6 to DMZ hosts)
#   E18 — No IPv6 internet access
#
# Usage: sudo bash automark_activity4.1.sh
# =============================================================================

if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "  [ERROR] Please run with sudo: sudo bash automark_activity4.1.sh"
    echo ""
    exit 1
fi

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

has_ip() { ip addr show 2>/dev/null | grep -q "inet $1"; }

# =============================================================================
# Detect VM
# =============================================================================
detect_vm() {
    if has_ip "192.168.1.254"; then
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
# External Gateway — Full Activity 4-1 checks
# =============================================================================
run_external_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: External Gateway${NC}"

    local ruleset
    ruleset=$(nft list ruleset 2>/dev/null)

    # =========================================================================
    section "nftables Service"
    # =========================================================================
    if systemctl is-active --quiet nftables 2>/dev/null; then
        pass "nftables service is active"
    else
        fail "E1" "nftables service is not active — run: sudo systemctl start nftables"
    fi

    if systemctl is-enabled --quiet nftables 2>/dev/null; then
        pass "nftables service is enabled (rules persist on reboot)"
    else
        fail "E10" "nftables service is not enabled — run: sudo systemctl enable nftables"
    fi

    # =========================================================================
    section "Configuration File"
    # =========================================================================
    if [ -f /etc/nftables.conf ]; then
        pass "/etc/nftables.conf exists"
        if grep -q "flush ruleset" /etc/nftables.conf 2>/dev/null; then
            pass "/etc/nftables.conf contains flush ruleset"
        else
            fail "E10" "/etc/nftables.conf is missing 'flush ruleset' — rules may stack on reload"
        fi
    else
        fail "E10" "/etc/nftables.conf not found — rules will not persist after reboot"
        info "Create the file with your ruleset and run: sudo nft -f /etc/nftables.conf"
    fi

    # =========================================================================
    section "Default-Drop Policies"
    # =========================================================================
    if echo "$ruleset" | grep -A5 'chain input' | grep -q 'policy drop'; then
        pass "Input chain — default policy: drop"
    else
        fail "E2" "Input chain is missing default-drop policy"
        info "Add: type filter hook input priority 0; policy drop;"
    fi

    if echo "$ruleset" | grep -A5 'chain output' | grep -q 'policy drop'; then
        pass "Output chain — default policy: drop"
    else
        fail "E2" "Output chain is missing default-drop policy"
        info "Add: type filter hook output priority 0; policy drop;"
    fi

    if echo "$ruleset" | grep -A5 'chain forward' | grep -q 'policy drop'; then
        pass "Forward chain — default policy: drop"
    else
        fail "E2" "Forward chain is missing default-drop policy"
        info "Add: type filter hook forward priority 0; policy drop;"
    fi

    # =========================================================================
    section "Loopback Rules"
    # =========================================================================
    if echo "$ruleset" | grep -q 'iif lo accept\|iif "lo" accept'; then
        pass "Loopback input accepted"
    else
        fail "E11" "Loopback input rule missing — add: iif lo accept"
    fi

    if echo "$ruleset" | grep -q 'oif lo accept\|oif "lo" accept'; then
        pass "Loopback output accepted"
    else
        fail "E11" "Loopback output rule missing — add: oif lo accept"
    fi

    # =========================================================================
    section "Established/Related Traffic"
    # =========================================================================
    local estab_count
    estab_count=$(echo "$ruleset" | grep -c 'ct state established,related accept\|ct state { established,related } accept' 2>/dev/null || true)
    if [ "$estab_count" -ge 2 ]; then
        pass "Established/related traffic accepted in multiple chains ($estab_count rules found)"
    elif [ "$estab_count" -eq 1 ]; then
        warn "Only one established/related accept rule found — expected in both input and forward chains"
    else
        fail "E12" "No established/related accept rules found — return traffic will be dropped"
        info "Add to input and forward chains: ct state established,related accept"
    fi

    # =========================================================================
    section "Output Chain — New Connections"
    # =========================================================================
    if echo "$ruleset" | grep -A20 'chain output' | grep -q 'ct state new accept'; then
        pass "Output chain allows new outbound connections (ct state new accept)"
    else
        fail "E3" "ct state new accept missing from output chain — External Gateway cannot initiate outbound connections (e.g. curl, apt)"
        info "Add to chain output: ct state new accept"
    fi

    # =========================================================================
    section "DNS Rules"
    # =========================================================================
    if echo "$ruleset" | grep -A20 'chain output' | grep -E 'udp dport 53 accept|udp dport \{ [^}]*53' >/dev/null; then
        pass "DNS UDP queries allowed in output chain (dport 53)"
    else
        fail "E7" "DNS UDP output rule missing — add: oif \"eth0\" udp dport 53 accept"
    fi

    if echo "$ruleset" | grep -A20 'chain output' | grep -E 'tcp dport 53 accept' >/dev/null; then
        pass "DNS TCP queries allowed in output chain (dport 53)"
    else
        fail "E7" "DNS TCP output rule missing — add: oif \"eth0\" tcp dport 53 accept"
    fi

    if echo "$ruleset" | grep -A20 'chain forward' | grep -E 'udp dport 53.*accept' >/dev/null; then
        pass "DNS UDP forwarding allowed in forward chain"
    else
        fail "E7" "DNS UDP forward rule missing — add: iif \"eth1\" oif \"eth0\" udp dport 53 ct state new accept"
    fi

    if echo "$ruleset" | grep -A20 'chain forward' | grep -E 'tcp dport 53.*accept' >/dev/null; then
        pass "DNS TCP forwarding allowed in forward chain"
    else
        fail "E7" "DNS TCP forward rule missing — add: iif \"eth1\" oif \"eth0\" tcp dport 53 ct state new accept"
    fi

    # =========================================================================
    section "HTTP Port Forwarding (Port 80)"
    # =========================================================================
    if echo "$ruleset" | grep -A20 'chain forward' | grep -E 'tcp dport 80.*accept|tcp dport \{ [^}]*80' >/dev/null; then
        pass "Port 80 forward rule present in forward chain"
    else
        fail "E5" "Port 80 forward rule missing from forward chain"
        info 'Add: iif "eth0" oif "eth1" tcp dport 80 ct state new accept'
    fi

    if echo "$ruleset" | grep -A20 'chain prerouting' | grep -E 'tcp dport 80.*dnat to 192\.168\.1\.80' >/dev/null; then
        pass "Port 80 DNAT rule forwards to 192.168.1.80"
    else
        fail "E5" "Port 80 DNAT rule missing from prerouting chain"
        info 'Add: iif "eth0" tcp dport 80 dnat to 192.168.1.80'
    fi

    # =========================================================================
    section "HTTPS Port Forwarding (Port 443)"
    # =========================================================================
    if echo "$ruleset" | grep -A20 'chain forward' | grep -E 'tcp dport 443.*accept|tcp dport \{ [^}]*443' >/dev/null; then
        pass "Port 443 forward rule present in forward chain"
    else
        fail "E6" "Port 443 forward rule missing from forward chain"
        info 'Add: iif "eth0" oif "eth1" tcp dport 443 ct state new accept'
    fi

    if echo "$ruleset" | grep -A20 'chain prerouting' | grep -E 'tcp dport 443.*dnat to 192\.168\.1\.80' >/dev/null; then
        pass "Port 443 DNAT rule forwards to 192.168.1.80"
    else
        fail "E6" "Port 443 DNAT rule missing from prerouting chain"
        info 'Add: iif "eth0" tcp dport 443 dnat to 192.168.1.80'
    fi

    # =========================================================================
    section "SMTP Port Forwarding (Port 25)"
    # =========================================================================
    if echo "$ruleset" | grep -A20 'chain forward' | grep -E 'tcp dport 25.*accept|tcp dport \{ [^}]*25' >/dev/null; then
        pass "Port 25 forward rule present in forward chain"
    else
        fail "E4" "Port 25 forward rule missing from forward chain"
        info 'Add: iif "eth0" oif "eth1" tcp dport 25 ct state new accept'
    fi

    if echo "$ruleset" | grep -A20 'chain prerouting' | grep -E 'tcp dport 25.*dnat to 192\.168\.1\.80' >/dev/null; then
        pass "Port 25 DNAT rule forwards to 192.168.1.80"
    else
        fail "E4" "Port 25 DNAT rule missing from prerouting chain"
        info 'Add: iif "eth0" tcp dport 25 dnat to 192.168.1.80'
    fi

    # =========================================================================
    section "Outbound NAT (Masquerade)"
    # =========================================================================
    if echo "$ruleset" | grep -A20 'chain postrouting' | grep -E 'oif "eth0" masquerade|oif eth0 masquerade' >/dev/null; then
        pass "Masquerade rule present on eth0 — internal hosts can reach internet"
    else
        fail "E8" "Masquerade rule missing from postrouting chain"
        info 'Add: oif "eth0" masquerade'
    fi

    # =========================================================================
    section "SNAT Return Traffic Rules"
    # =========================================================================
    if echo "$ruleset" | grep -A20 'chain postrouting' | grep -E 'tcp dport 80.*snat to 192\.168\.1\.254' >/dev/null; then
        pass "SNAT rule present for port 80 return traffic"
    else
        fail "E9" "SNAT rule missing for port 80 — web server replies may not route correctly"
        info 'Add: oif "eth1" tcp dport 80 ip daddr 192.168.1.80 snat to 192.168.1.254'
    fi

    if echo "$ruleset" | grep -A20 'chain postrouting' | grep -E 'tcp dport 443.*snat to 192\.168\.1\.254' >/dev/null; then
        pass "SNAT rule present for port 443 return traffic"
    else
        fail "E9" "SNAT rule missing for port 443 — HTTPS return traffic may not route correctly"
        info 'Add: oif "eth1" tcp dport 443 ip daddr 192.168.1.80 snat to 192.168.1.254'
    fi

    if echo "$ruleset" | grep -A20 'chain postrouting' | grep -E 'tcp dport 25.*snat to 192\.168\.1\.254' >/dev/null; then
        pass "SNAT rule present for port 25 return traffic"
    else
        fail "E9" "SNAT rule missing for port 25 — SMTP return traffic may not route correctly"
        info 'Add: oif "eth1" tcp dport 25 ip daddr 192.168.1.80 snat to 192.168.1.254'
    fi

    # =========================================================================
    section "Live Connectivity Tests"
    # =========================================================================
    info "Testing internet access from External Gateway..."
    if curl -fsSL --max-time 5 -o /dev/null -w "%{http_code}" https://google.com 2>/dev/null | grep -qE '^[23]'; then
        pass "Internet access working from External Gateway (curl https://google.com)"
    else
        fail "E3" "External Gateway cannot reach the internet — check output chain and masquerade rule"
    fi

    info "Testing web server reachable on port 80 via DMZ..."
    if curl -fsSL --max-time 5 -o /dev/null http://192.168.1.80 2>/dev/null; then
        pass "Web server reachable on port 80 (192.168.1.80)"
    else
        fail "E5" "Web server not reachable on port 80 — check Apache on Ubuntu Server and forward/DNAT rules"
    fi

    info "Testing web server reachable on port 443 via DMZ..."
    if curl -fsSLk --max-time 5 -o /dev/null https://192.168.1.80 2>/dev/null; then
        pass "Web server reachable on port 443 (192.168.1.80)"
    else
        fail "E6" "Web server not reachable on port 443 — check Apache HTTPS and forward/DNAT rules"
    fi

    info "Testing SMTP port reachable on Ubuntu Server..."
    if (echo > /dev/tcp/192.168.1.80/25) 2>/dev/null; then
        pass "SMTP port 25 reachable on 192.168.1.80"
    else
        fail "E4" "SMTP port 25 not reachable on 192.168.1.80 — check Postfix and forward/DNAT rules"
    fi

    # #########################################################################
    # ###  IPv6 TEST LAYER  (additive; mirrors the IPv4 checks above)       ###
    # ###  Read-only. New codes: E13 addressing, E14 routing, E15 fwd,      ###
    # ###  E16 nftables(v6), E17 connectivity, E18 internet.                ###
    # #########################################################################

    # =========================================================================
    section "IPv6 Addressing (External Gateway)"
    # =========================================================================
    # ASSUMPTION: per the lab IPv6 addressing table the ExtGW reaches the transit
    # network over the wg0 tunnel (df00::1); this activity's IPv4 uplink is eth0.
    # Adjust the interface names below if your IPv6 uplink differs.
    check_ip6 wg0  2404:9400:29c1:df00::1/64   E13
    check_ip6 eth1 2404:9400:29c1:df10::254/64 E13

    # =========================================================================
    section "IPv6 Forwarding"
    # =========================================================================
    check_ip6_forward E15

    # =========================================================================
    section "IPv6 Routing"
    # =========================================================================
    # ASSUMPTION: ExtGW default IPv6 route lives on the wg0 tunnel (table 51820);
    # `ip -6 route get` still resolves it. Internal net is reached via the IntGW.
    check_route6_get 2001:4860:4860::8888  "dev wg0" E14 "internet"
    check_route6_get 2404:9400:29c1:df20::1 "via 2404:9400:29c1:df10::1" E14 \
        "internal 2404:9400:29c1:df20::1 (via IntGW)"

    # =========================================================================
    section "IPv6 Connectivity"
    # =========================================================================
    check_ping6 2404:9400:29c1:df10::1  "Internal Gateway (DMZ)" E17
    check_ping6 2404:9400:29c1:df10::80 "Ubuntu Server (DMZ)"    E17

    # =========================================================================
    section "IPv6 Firewall Rules (nftables — ip6/inet family)"
    # =========================================================================
    # The activity's filter table is 'inet' (dual-stack) so these mirror the
    # IPv4 rules for IPv6 too; ICMPv6 is IPv6-specific and has no IPv4 analogue.

    # Default-drop policies (mirror E2) on forward + input chains.
    check_nft6 'hook forward priority[^;]*; ?policy drop' \
        "IPv6 forward chain default-drop policy (inet/ip6)" E16
    check_nft6 'hook input priority[^;]*; ?policy drop' \
        "IPv6 input chain default-drop policy (inet/ip6)" E16

    # Established/related accept (mirror E12) — also serves the uplink->DMZ
    # (wg0->DMZ) return path for inbound sessions.
    check_nft6 'ct state \{? ?established, ?related ?\}? accept' \
        "IPv6 established/related accept (return traffic, incl. uplink->DMZ)" E16

    # Loopback accept (mirror E11).
    check_nft6 'iif(name)? "?lo"? accept' "IPv6 loopback input accept"  E16
    check_nft6 'oif(name)? "?lo"? accept' "IPv6 loopback output accept" E16

    # ICMPv6 — REQUIRED for IPv6 (neighbour discovery + echo). No IPv4 analogue;
    # without it IPv6 breaks (ND) and diagnostics fail (echo).
    check_nft6 '(meta l4proto (ipv6-icmp|icmpv6)|ip6 nexthdr icmpv6|nexthdr icmpv6) accept|icmpv6 type \{?[^}]*nd-(neighbor|router)-[a-z]+' \
        "ICMPv6 neighbour discovery allowed in input" E16
    check_nft6 '(meta l4proto (ipv6-icmp|icmpv6)|ip6 nexthdr icmpv6|nexthdr icmpv6) accept|icmpv6 type \{?[^}]*echo-(request|reply)' \
        "ICMPv6 echo-request/reply allowed in input" E16

    # DMZ -> uplink forward accept (mirror IPv4 'iif eth1 oif eth0 accept').
    # ASSUMPTION: v6 DMZ egress leaves via eth0 (as IPv4) or the wg0 tunnel.
    check_nft6 'iif(name)? "?eth1"? oif(name)? "?(eth0|wg0)"? accept' \
        "IPv6 DMZ->uplink forward accept (eth1 -> eth0/wg0)" E16

    # Inbound 80/443/25 to the server (mirror the IPv4 E5/E6/E4 forward accepts).
    # ASSUMPTION: IPv6 reaches the server by its native global address
    # (2404:9400:29c1:df10::80), so the inbound path is a plain forward-accept —
    # there is NO ip6 DNAT (the activity's NAT table is 'ip nat', IPv4-only).
    # Inbound interface is eth0 (as IPv4) or the wg0 tunnel.
    check_nft6 'iif(name)? "?(eth0|wg0)"? oif(name)? "?eth1"? tcp dport 80 ct state new accept' \
        "IPv6 inbound HTTP (80) forward-accept to server" E16
    check_nft6 'iif(name)? "?(eth0|wg0)"? oif(name)? "?eth1"? tcp dport 443 ct state new accept' \
        "IPv6 inbound HTTPS (443) forward-accept to server" E16
    check_nft6 'iif(name)? "?(eth0|wg0)"? oif(name)? "?eth1"? tcp dport 25 ct state new accept' \
        "IPv6 inbound SMTP (25) forward-accept to server" E16

    # =========================================================================
    section "IPv6 Internet Access"
    # =========================================================================
    check_internet6 E18
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
        echo -e "  ${YELLOW}Refer to the Troubleshooting section of the Activity 4-1 guide.${NC}"
        echo ""
    else
        echo ""
        echo -e "  ${GREEN}${BOLD}All checks passed! Activity 4-1 configuration looks correct.${NC}"
        echo ""
    fi
}

# =============================================================================
# Main
# =============================================================================
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Activity 4-1 Automarker — Firewalls with nftables${NC}"
echo -e "${BOLD} 7015ICT | Griffith University${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

VM=$(detect_vm)

case "$VM" in
    external_gateway) run_external_gateway ;;
    internal_gateway|ubuntu_server|ubuntu_desktop)
        echo ""
        echo -e "${YELLOW}[WARN]${NC} This script is designed to run on the External Gateway only."
        echo ""
        echo "       Activity 4-1 firewall configuration is applied exclusively"
        echo "       on the External Gateway (eth1: 192.168.1.254)."
        echo ""
        echo "       Please run this script on the External Gateway VM."
        echo ""
        exit 0
        ;;
    *)
        echo ""
        echo -e "${RED}[ERROR]${NC} Could not detect which VM this is."
        echo ""
        echo "        Expected IP address for External Gateway:"
        echo "          eth1 at 192.168.1.254"
        echo ""
        echo "        Your current addresses:"
        ip -brief addr show 2>/dev/null | sed 's/^/          /'
        exit 1
        ;;
esac

print_summary
