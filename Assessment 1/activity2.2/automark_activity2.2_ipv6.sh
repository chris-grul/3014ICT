#!/bin/bash
# =============================================================================
# Automarking Script - Activity 2.2: BIND9 DNS Server
# 7015ICT | Griffith University
# =============================================================================
# Run on Internal Gateway, Ubuntu Server, or Ubuntu Desktop.
# The script auto-detects which VM it is running on.
#
# Error Code Reference:
#   E1  — BIND9 named service not starting or not listening on port 53
#   E2  — listen-on configuration missing required addresses
#   E3  — DNS zone not loading or resolving incorrectly
#   E4  — All external DNS queries return SERVFAIL / forwarding broken
#   E5  — Ubuntu Server Netplan DNS not set to 192.168.1.1
#   E6  — Ubuntu Server can't reach BIND9 at 192.168.1.1
#   E7  — Ubuntu Desktop cannot reach BIND9 at 10.10.1.254
#   E8  — Ubuntu Desktop cannot reach web server by domain name
#   E9  — General connectivity failure
#
#   --- IPv6 test layer (mirrors the IPv4 checks above) ---
#   E10 — IPv6 addressing wrong/missing on an interface
#   E11 — IPv6 routing (default/internet route) wrong or missing
#   E12 — IPv6 forwarding not enabled (Internal Gateway)
#   E13 — IPv6 connectivity failure (ping6 neighbour / IPv6 internet)
#   E14 — IPv6 DNS service: listen-on-v6 { any; } missing, or BIND9 not
#         answering over IPv6 transport
#   E15 — IPv6 DNS records: AAAA record and/or ip6.arpa reverse PTR missing
#   E16 — IPv6 tunnel services down (Remote Gateway: wstunnel-server /
#         wg-quick@wg0 not active, or no WireGuard handshake on wg0)
#
# Runs on: Internal Gateway, Ubuntu Server, Ubuntu Desktop, or the
#          Remote Gateway (BinaryLane VM — public IPv4 112.213.39.252).
#
# Usage: sudo bash automark_activity2.2_ipv6.sh
# =============================================================================

if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "  [ERROR] Please run with sudo: sudo bash automark_activity2.2.sh"
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

pass()    { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "  ${RED}[FAIL]${NC} $2"; echo -e "         ${YELLOW}→ Error $1 — see Troubleshooting section of Activity 2.2 guide${NC}"; ERRORS+=("$1"); ((FAIL++)); }
info()    { echo -e "  ${CYAN}[INFO]${NC} $1"; }
warn()    { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
section() { echo ""; echo -e "${BOLD}--- $1 ---${NC}"; }

has_ip() { ip addr show 2>/dev/null | grep -q "inet $1"; }

# =============================================================================
# Detect VM
# =============================================================================
detect_vm() {
    if has_ip "112.213.39.252"; then
        echo "remote_gateway"
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
# Shared helpers
# =============================================================================

check_port_listening() {
    local port=$1 label=$2 code=$3
    if ss -tuln 2>/dev/null | grep -q ":$port "; then
        pass "$label listening on port $port"
    else
        fail "$code" "$label not listening on port $port"
    fi
}

check_internet() {
    local code=$1
    for url in "https://example.com" "https://www.google.com" "https://1.1.1.1"; do
        local h
        h=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 -L "$url" 2>/dev/null)
        if [[ "$h" =~ ^[23] ]]; then
            pass "Internet access confirmed (HTTP $h from $url)"
            return
        fi
    done
    fail "$code" "No internet access — check default route and NAT on External Gateway"
}

# =============================================================================
# Detect student domain from BIND9 config
# =============================================================================
detect_domain() {
    local zone
    zone=$(grep "^zone" /etc/bind/named.conf.local 2>/dev/null \
        | grep -v 'arpa\|localhost\|hint\|\"\.\"\|"."' \
        | grep '"' | head -1 \
        | sed 's/.*"\(.*\)".*/\1/')
    echo "$zone"
}

# =============================================================================
# BIND9 checks (used by Internal Gateway)
# =============================================================================

check_bind9_running() {
    if systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null; then
        pass "BIND9 (named) is running"
    else
        fail "E1" "BIND9 (named) is not running"
        info "Fix: sudo systemctl enable --now named"
        info "Then check config: sudo named-checkconf"
    fi
}

check_bind9_listen_on() {
    local listenon
    listenon=$(grep "listen-on" /etc/bind/named.conf.options 2>/dev/null | grep -v v6 | head -1)
    if echo "$listenon" | grep -q "127.0.0.1"; then
        pass "listen-on includes 127.0.0.1"
    else
        fail "E2" "127.0.0.1 missing from listen-on in named.conf.options"
        info "Edit named.conf.options: listen-on { 127.0.0.1; 192.168.1.1; 10.10.1.254; };"
    fi
    if echo "$listenon" | grep -q "10.10.1.254"; then
        pass "listen-on includes 10.10.1.254"
    else
        fail "E2" "10.10.1.254 missing from listen-on in named.conf.options"
        info "Edit named.conf.options: listen-on { 127.0.0.1; 192.168.1.1; 10.10.1.254; };"
    fi
}

check_external_dns_forwarding() {
    local result
    result=$(dig @127.0.0.1 google.com +short +time=8 +tries=1 2>/dev/null | head -1)
    if [ -n "$result" ]; then
        pass "External DNS forwarding works (google.com → $result)"
    else
        fail "E4" "BIND9 cannot forward external queries — no response for google.com"
        info "Check forwarders in named.conf.options and confirm internet access"
        info "If Azure is blocking UDP 53, add: server 8.8.8.8 { tcp-only yes; }; in named.conf"
    fi
}

check_local_zone_resolves() {
    local zone_name
    zone_name=$(detect_domain)

    if [ -z "$zone_name" ] || [ "$zone_name" = "." ]; then
        fail "E3" "No custom forward zone found in /etc/bind/named.conf.local"
        info "Add your zone definition and restart named"
        return
    fi

    info "Detected zone: $zone_name"

    # Validate zone file exists in the correct subdirectory
    local zone_file="/etc/bind/zones/db.$zone_name"
    if [ -f "$zone_file" ]; then
        local check_result
        check_result=$(named-checkzone "$zone_name" "$zone_file" 2>&1)
        if echo "$check_result" | grep -q "^OK$"; then
            pass "Zone file validates: $zone_file"
        else
            fail "E3" "Zone file has errors: $zone_file"
            info "Run: sudo named-checkzone $zone_name $zone_file"
        fi
    else
        fail "E3" "Zone file not found at $zone_file"
        info "Zone files must be in /etc/bind/zones/ — check named.conf.local path"
    fi

    local result
    result=$(dig @127.0.0.1 "www.$zone_name" +short +time=5 +tries=1 2>/dev/null)
    if printf '%s\n' "$result" | grep -qx "192.168.1.80"; then
        pass "Forward lookup: www.$zone_name → 192.168.1.80"
    else
        fail "E3" "www.$zone_name did not resolve to 192.168.1.80 (got: ${result:-no response})"
        info "Run: sudo named-checkzone $zone_name /etc/bind/zones/db.$zone_name"
    fi
}

check_reverse_lookup() {
    local result
    result=$(dig @127.0.0.1 -x 192.168.1.80 +short +time=5 +tries=1 2>/dev/null)
    if [ -n "$result" ]; then
        pass "Reverse lookup: 192.168.1.80 → $result"
    else
        fail "E3" "Reverse lookup for 192.168.1.80 returned no PTR record"
        local rev_file="/etc/bind/zones/db.192.168.1"
        if [ -f "$rev_file" ]; then
            info "Reverse zone file exists — run: sudo named-checkzone 1.168.192.in-addr.arpa $rev_file"
        else
            info "Reverse zone file not found at $rev_file — check named.conf.local"
        fi
    fi
}

check_dnssec_validation() {
    local result
    result=$(dig @127.0.0.1 dnssec-failed.org +time=5 +tries=1 2>/dev/null | grep -i "SERVFAIL\|status:")
    if echo "$result" | grep -qi "SERVFAIL"; then
        pass "DNSSEC validation active (dnssec-failed.org → SERVFAIL)"
    else
        fail "B5" "DNSSEC validation not enforcing — dnssec-failed.org did not return SERVFAIL"
        info "Check named.conf.options: dnssec-validation auto; must be set, then restart named"
    fi
}

check_dnssec_ad_flag() {
    local result
    result=$(dig @127.0.0.1 google.com +dnssec +time=5 +tries=1 2>/dev/null)
    if echo "$result" | grep -q " ad "; then
        pass "DNSSEC ad flag present for google.com"
    else
        warn "DNSSEC ad flag not present for google.com (may be expected in Azure TCP-forwarding environment)"
        info "Use the dnssec-failed.org SERVFAIL test (B5) as definitive proof of DNSSEC enforcement"
    fi
}

# ============================================================================
#  SHARED IPv6 HELPER BLOCK  —  pasted verbatim from ipv6_helpers.sh.
#  Placed AFTER the existing helper/check functions and BEFORE run_<vm>().
#  Reuses the script's existing pass()/fail()/section()/CYAN/NC.
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
#  Activity 2.2 specific IPv6 DNS checks (BIND9 over IPv6)
# ============================================================================

# BIND9 must be told to listen on IPv6. The shipped default is `listen-on-v6
# { none; };` (IPv6 disabled). Students may enable it either with `{ any; }` or by
# binding explicit IPv6 addresses — both are valid; an explicit list is tighter.
# We fail only on the disabled default (none) or a missing directive. Grep the
# config directly; the functional transport test below is the authoritative proof.
check_listen_on_v6_any() {
    local code=$1 line inside
    line=$(grep "listen-on-v6" /etc/bind/named.conf.options 2>/dev/null | head -1)
    inside=$(echo "$line" | sed -n 's/.*{\(.*\)}.*/\1/p')
    if echo "$line" | grep -qE 'listen-on-v6[[:space:]]*\{[[:space:]]*any[[:space:]]*;'; then
        pass "named.conf.options has listen-on-v6 { any; }"
    elif echo "$line" | grep -qE 'listen-on-v6[[:space:]]*\{[[:space:]]*none[[:space:]]*;'; then
        fail "$code" "listen-on-v6 is disabled ({ none; }) in named.conf.options — BIND won't answer over IPv6"
        info "Enable it: listen-on-v6 { any; };  (or an explicit IPv6 address list)  then: sudo systemctl restart named"
    elif echo "$inside" | grep -q ':'; then
        pass "named.conf.options binds explicit IPv6 addresses (listen-on-v6 {${inside}})"
    else
        fail "$code" "listen-on-v6 not enabled in named.conf.options (found: ${line:-none})"
        info "Enable it: listen-on-v6 { any; };  (or an explicit IPv6 address list)  then: sudo systemctl restart named"
    fi
}

# Confirm BIND9 answers over IPv6 transport by querying an EXISTING A record via a
# v6 server address (independent of whether AAAA records have been added yet).
# check_dns6_transport <server-v6> <domain> <code>
check_dns6_transport() {
    local server=$1 zone=$2 code=$3 ans
    if [ -z "$zone" ] || [ "$zone" = "." ]; then
        fail "$code" "cannot test IPv6 DNS transport — domain not detected"; return
    fi
    ans=$(dig -6 @"$server" "www.$zone" A +short +time=5 +tries=1 2>/dev/null | head -1)
    if [ -n "$ans" ]; then
        pass "BIND9 answers over IPv6 transport (dig -6 @$server www.$zone -> $ans)"
    else
        fail "$code" "BIND9 did not answer over IPv6 transport at [$server] (needs listen-on-v6 { any; } + restart)"
        info "Confirm: dig -6 @$server www.$zone  responds after enabling listen-on-v6 { any; }"
    fi
}

# ip6.arpa reverse PTR for the server's IPv6 address, IF a v6 reverse zone exists.
# check_reverse6 <server-v6-for-query> <target-v6-addr> <code>
check_reverse6() {
    local server=$1 target=$2 code=$3 ptr
    ptr=$(dig -6 @"$server" -x "$target" +short +time=5 +tries=1 2>/dev/null | head -1)
    if [ -n "$ptr" ]; then
        pass "IPv6 reverse (ip6.arpa) PTR: $target -> $ptr"
    else
        fail "$code" "no ip6.arpa PTR for $target (add a reverse v6 zone if the activity requires it)"
    fi
}

# =============================================================================
# Internal Gateway checks
# =============================================================================
run_internal_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: Internal Gateway${NC}"

    section "Part B — BIND9 Service (E1)"
    check_bind9_running
    check_port_listening "53" "BIND9" "E1"

    section "Part B — BIND9 Listen-on Configuration (E2)"
    check_bind9_listen_on

    section "Part B — External DNS Forwarding (E4)"
    check_external_dns_forwarding

    section "Part B — Local Zone Resolution (E3)"
    check_local_zone_resolves

    section "Part B — Reverse Lookup (E3)"
    check_reverse_lookup

    section "Part B — DNSSEC (B5)"
    check_dnssec_validation
    check_dnssec_ad_flag

    section "Connectivity"
    ping -c 2 -W 2 192.168.1.80 &>/dev/null \
        && pass "Ping Ubuntu Server (192.168.1.80)" \
        || fail "E9" "Cannot ping Ubuntu Server (192.168.1.80)"
    ping -c 2 -W 2 10.10.1.1 &>/dev/null \
        && pass "Ping Ubuntu Desktop (10.10.1.1)" \
        || fail "E9" "Cannot ping Ubuntu Desktop (10.10.1.1)"
    check_internet "E9"

    # =========================================================================
    # IPv6 test layer (mirrors the IPv4 checks above) — Internal Gateway
    # =========================================================================
    # ASSUMPTION: DMZ-side interface is eth0 and internal-side interface is eth1
    # (matches detect_vm's 192.168.1.1 / 10.10.1.254 roles). Adjust iface names
    # if your VM uses different ones.
    section "IPv6 Addressing (E10)"
    check_ip6 eth0 2404:9400:29c1:df10::1/64 "E10"
    check_ip6 eth1 2404:9400:29c1:df20::254/64 "E10"

    section "IPv6 Forwarding (E12)"
    check_ip6_forward "E12"

    section "IPv6 Routing (E11)"
    check_route6_get 2001:4860:4860::8888 "via 2404:9400:29c1:df10::254" "E11" "IPv6 internet (via External Gateway)"

    section "IPv6 Connectivity (E13)"
    check_ping6 2404:9400:29c1:df10::254 "External Gateway" "E13"
    check_ping6 2404:9400:29c1:df10::80  "Ubuntu Server"    "E13"
    check_ping6 2404:9400:29c1:df20::1   "Ubuntu Desktop"   "E13"
    check_internet6 "E13"

    section "IPv6 DNS Service — listen-on-v6 + IPv6 transport (E14)"
    check_listen_on_v6_any "E14"
    # BIND9 runs here; query it over its own IPv6 loopback (covered by listen-on-v6 { any; }).
    local zone6
    zone6=$(detect_domain)
    check_dns6_transport "::1" "$zone6" "E14"

    section "IPv6 DNS Records — AAAA + reverse ip6.arpa (E15)"
    # ASSUMPTION: an AAAA record for www.<domain> pointing at the Ubuntu Server's
    # IPv6 (2404:9400:29c1:df10::80) is expected. The shipped forward zone only
    # ships A records, so add the AAAA if the activity requires IPv6 name resolution.
    check_aaaa "www.$zone6" "::1" "E15"
    # ASSUMPTION: an ip6.arpa reverse zone is expected for the DMZ /64. None ships
    # in the base config; add one (or remove this check) to match your activity.
    check_reverse6 "::1" 2404:9400:29c1:df10::80 "E15"
}

# =============================================================================
# Ubuntu Server checks
# =============================================================================
run_ubuntu_server() {
    echo -e "\n${BOLD}${CYAN}VM detected: Ubuntu Server${NC}"

    section "Part C — DNS Server Configuration (E5)"
    if grep -q "192.168.1.1" /etc/netplan/50-cloud-init.yaml 2>/dev/null; then
        pass "Netplan DNS set to 192.168.1.1"
    else
        fail "E5" "DNS server 192.168.1.1 not found in /etc/netplan/50-cloud-init.yaml"
        info "Add nameservers: addresses: [192.168.1.1] under eth0 in netplan, then: sudo netplan apply"
    fi

    section "Part C — DNS Resolution via Internal Gateway (E6)"
    local ext_result
    ext_result=$(dig @192.168.1.1 google.com +short +time=5 +tries=1 2>/dev/null | head -1)
    if [ -n "$ext_result" ]; then
        pass "External DNS via 192.168.1.1 works (google.com → $ext_result)"
    else
        fail "E6" "Cannot resolve google.com via 192.168.1.1"
        info "Check BIND9 is running on Internal Gateway and netplan is applied"
    fi

    section "Part C — Local Domain Resolution (E6)"
    local ptr
    ptr=$(dig @192.168.1.1 -x 192.168.1.80 +short +time=5 +tries=1 2>/dev/null)
    local DOMAIN=""
    if [ -n "$ptr" ]; then
        pass "Reverse lookup via 192.168.1.1: 192.168.1.80 → $ptr"
        DOMAIN=$(echo "$ptr" | sed 's/^www\.//' | sed 's/\.$//')
    else
        fail "E6" "Reverse lookup for 192.168.1.80 failed via 192.168.1.1"
        info "Ensure BIND9 reverse zone is configured on Internal Gateway"
    fi

    if [ -n "$DOMAIN" ]; then
        local fwd
        fwd=$(dig @192.168.1.1 "www.$DOMAIN" +short +time=5 +tries=1 2>/dev/null)
        if printf '%s\n' "$fwd" | grep -qx "192.168.1.80"; then
            pass "Forward lookup via 192.168.1.1: www.$DOMAIN → 192.168.1.80"
        else
            fail "E6" "www.$DOMAIN did not resolve via 192.168.1.1 (got: ${fwd:-no response})"
        fi
    fi

    section "Internet Access"
    check_internet "E9"

    # =========================================================================
    # IPv6 test layer (mirrors the IPv4 checks above) — Ubuntu Server
    # =========================================================================
    # ASSUMPTION: single interface is eth0.
    section "IPv6 Addressing (E10)"
    check_ip6 eth0 2404:9400:29c1:df10::80/64 "E10"

    section "IPv6 Routing (E11)"
    check_route6_get 2001:4860:4860::8888 "via 2404:9400:29c1:df10::254" "E11" "IPv6 internet (via External Gateway)"

    section "IPv6 Connectivity (E13)"
    check_ping6 2404:9400:29c1:df10::254 "External Gateway" "E13"
    check_ping6 2404:9400:29c1:df10::1   "Internal Gateway" "E13"
    check_internet6 "E13"

    # DNS client checks: this VM points at BIND9 on the Internal Gateway. Query the
    # gateway's DMZ-side IPv6 address to confirm IPv6 DNS works end-to-end.
    section "IPv6 DNS via Internal Gateway (E14/E15)"
    if [ -n "$DOMAIN" ]; then
        check_dns6_transport 2404:9400:29c1:df10::1 "$DOMAIN" "E14"
        # ASSUMPTION: AAAA for www.<domain> -> 2404:9400:29c1:df10::80 is expected.
        check_aaaa "www.$DOMAIN" 2404:9400:29c1:df10::1 "E15"
    else
        fail "E14" "Cannot test IPv6 DNS — domain not detected (resolve E6 first)"
    fi
}

# =============================================================================
# Ubuntu Desktop checks
# =============================================================================
run_ubuntu_desktop() {
    echo -e "\n${BOLD}${CYAN}VM detected: Ubuntu Desktop${NC}"

    section "Part D — DNS Resolution via Internal Gateway (E7)"
    if dig @10.10.1.254 google.com +short +time=5 +tries=1 2>/dev/null | grep -qE '^[0-9]'; then
        pass "External DNS via 10.10.1.254 resolves external domains"
    else
        fail "E7" "Cannot resolve external domains via DNS at 10.10.1.254"
        info "Ensure BIND9 is running on Internal Gateway and Desktop DNS is set to 10.10.1.254"
    fi

    section "Part D — Local Domain Resolution (E7)"
    local ptr
    ptr=$(dig @10.10.1.254 -x 192.168.1.80 +short +time=5 +tries=1 2>/dev/null)
    local DOMAIN=""
    if [ -n "$ptr" ]; then
        pass "Reverse lookup: 192.168.1.80 → $ptr"
        DOMAIN=$(echo "$ptr" | sed 's/^www\.//' | sed 's/\.$//')
    else
        fail "E7" "Reverse lookup for 192.168.1.80 failed via 10.10.1.254"
        info "Ensure BIND9 reverse zone is configured on Internal Gateway"
    fi

    if [ -n "$DOMAIN" ]; then
        local fwd
        fwd=$(dig @10.10.1.254 "www.$DOMAIN" +short +time=5 +tries=1 2>/dev/null)
        if printf '%s\n' "$fwd" | grep -qx "192.168.1.80"; then
            pass "Forward lookup: www.$DOMAIN → 192.168.1.80"
        else
            fail "E7" "www.$DOMAIN did not resolve (got: ${fwd:-no response})"
        fi
    fi

    section "Part D — Web Server Accessible by Domain Name (E8)"
    if [ -n "$DOMAIN" ]; then
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
            --resolve "www.$DOMAIN:80:192.168.1.80" \
            "http://www.$DOMAIN" 2>/dev/null)
        if [[ "$http_code" =~ ^[23] ]]; then
            pass "HTTP $http_code — http://www.$DOMAIN loads"
        else
            fail "E8" "http://www.$DOMAIN did not load (HTTP: ${http_code:-no response})"
            info "Ensure DNS resolves and Apache is running on Ubuntu Server"
        fi

        local https_code
        https_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 8 \
            --resolve "www.$DOMAIN:443:192.168.1.80" \
            "https://www.$DOMAIN" 2>/dev/null)
        if [[ "$https_code" =~ ^[23] ]]; then
            pass "HTTPS $https_code — https://www.$DOMAIN loads"
        else
            fail "E8" "https://www.$DOMAIN did not load (HTTP: ${https_code:-no response})"
            info "Ensure SSL is configured on Apache (Part C) and port 443 is reachable"
        fi
    else
        fail "E8" "Cannot test web access by domain — domain not detected from DNS"
        info "Resolve E7 errors first so the domain can be identified"
    fi

    section "Internet Access"
    check_internet "E9"

    # =========================================================================
    # IPv6 test layer (mirrors the IPv4 checks above) — Ubuntu Desktop
    # =========================================================================
    # ASSUMPTION: single interface is eth0.
    section "IPv6 Addressing (E10)"
    check_ip6 eth0 2404:9400:29c1:df20::1/64 "E10"

    section "IPv6 Routing (E11)"
    check_route6_get 2001:4860:4860::8888 "via 2404:9400:29c1:df20::254" "E11" "IPv6 internet (via Internal Gateway)"

    section "IPv6 Connectivity (E13)"
    check_ping6 2404:9400:29c1:df20::254 "Internal Gateway" "E13"
    check_ping6 2404:9400:29c1:df10::80  "Ubuntu Server"    "E13"
    check_internet6 "E13"

    # DNS client checks: this VM points at BIND9 on the Internal Gateway. Query the
    # gateway's internal-side IPv6 address to confirm IPv6 DNS works end-to-end.
    section "IPv6 DNS via Internal Gateway (E14/E15)"
    if [ -n "$DOMAIN" ]; then
        check_dns6_transport 2404:9400:29c1:df20::254 "$DOMAIN" "E14"
        # ASSUMPTION: AAAA for www.<domain> -> 2404:9400:29c1:df10::80 is expected.
        check_aaaa "www.$DOMAIN" 2404:9400:29c1:df20::254 "E15"
    else
        fail "E14" "Cannot test IPv6 DNS — domain not detected (resolve E7 first)"
    fi
}

# =============================================================================
# Remote Gateway checks (BinaryLane VM — IPv6 uplink)
# =============================================================================
run_remote_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: Remote Gateway (BinaryLane VM — IPv6 uplink)${NC}"

    section "Network Interfaces"
    for _i in eth0 wg0; do
        if ip link show "$_i" &>/dev/null; then pass "Interface $_i exists"
        else fail "E10" "Interface $_i not found"; fi
    done

    section "IPv4 Addressing"
    if has_ip "112.213.39.252"; then pass "eth0 has public IPv4 (112.213.39.252)"
    else fail "E10" "public IPv4 112.213.39.252 not found"; fi

    section "IPv6 Addressing"
    check_ip6 "wg0" "2404:9400:29c1:df00::254/64" "E10"
    check_ip6_has_global "eth0" "E10"

    section "IPv6 Routing"
    check_route6_get "2404:9400:29c1:df10::80" "dev wg0"  "E11" "lab /56 (down the tunnel)"
    check_route6_get "2001:4860:4860::8888"    "dev eth0" "E11" "internet (own uplink)"

    section "IPv6 Forwarding"
    check_ip6_forward "E12"

    section "Tunnel Services"
    for _svc in wstunnel-server wg-quick@wg0; do
        if systemctl is-active --quiet "$_svc" 2>/dev/null; then pass "service $_svc is active"
        else fail "E16" "service $_svc is not active"; fi
    done
    _hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -1)
    if [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null; then
        pass "WireGuard handshake present ($(( $(date +%s) - _hs ))s ago)"
    else fail "E16" "no WireGuard handshake on wg0 — tunnel not established"; fi

    section "IPv6 Connectivity — Lab"
    check_ping6 "2404:9400:29c1:df00::1"  "External Gateway (wg0)" "E13"
    check_ping6 "2404:9400:29c1:df10::80" "Ubuntu Server"          "E13"
    check_ping6 "2404:9400:29c1:df20::1"  "Ubuntu Desktop"         "E13"

    section "IPv6 Internet Access"
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
        echo -e "  ${YELLOW}Refer to the Troubleshooting section of the Activity 2.2 guide.${NC}"
        echo ""
    else
        echo ""
        echo -e "  ${GREEN}${BOLD}All checks passed! Activity 2.2 configuration looks correct.${NC}"
        echo ""
    fi
}

# =============================================================================
# Main
# =============================================================================
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Activity 2.2 Automarker — BIND9 DNS Server${NC}"
echo -e "${BOLD} 7015ICT | Griffith University${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

VM=$(detect_vm)

case "$VM" in
    remote_gateway)   run_remote_gateway ;;
    internal_gateway) run_internal_gateway ;;
    ubuntu_server)    run_ubuntu_server ;;
    ubuntu_desktop)   run_ubuntu_desktop ;;
    *)
        echo ""
        echo -e "${RED}[ERROR]${NC} Could not detect which VM this is."
        echo ""
        echo "        Expected IP addresses:"
        echo "          Remote Gateway   — public IPv4 112.213.39.252"
        echo "          Internal Gateway — eth0 at 192.168.1.1 AND eth1 at 10.10.1.254"
        echo "          Ubuntu Server    — eth0 at 192.168.1.80"
        echo "          Ubuntu Desktop   — eth0 at 10.10.1.1"
        echo ""
        echo "        Your current addresses:"
        ip -brief addr show 2>/dev/null | sed 's/^/          /'
        echo ""
        exit 1
        ;;
esac

print_summary
