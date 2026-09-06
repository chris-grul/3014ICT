#!/bin/bash
# =============================================================================
# Automarking Script - Activity 2.1: NAT, SSL, Proxy
# 7015ICT | Griffith University
# =============================================================================
# Run this script on any of the four lab VMs after completing the activity.
# The script will auto-detect which VM it is running on and perform the
# appropriate checks. Any failures are reported as E-codes matching the
# Troubleshooting section of the Activity 2.1 guide.
#
# Error Code Reference:
#   E1  — IP address wrong or missing
#   E2  — Network interface missing
#   E3  — IP forwarding disabled on a gateway
#   E4  — nftables rules wrong, missing, or not applied
#   E5  — Cannot reach another VM or subnet
#   E6 — Ubuntu Server cannot reach internal network clients
#   E7 — Apache not serving pages or SSL failing
#   E8 — Squid not running or not on port 8080
#   E9 — Australian sites not blocked by Squid
#
#   --- IPv6 test layer (mirrors the IPv4 checks above) ---
#   E13 — IPv6 address wrong or missing on an interface
#   E14 — IPv6 route wrong or missing (route-get / default gateway)
#   E15 — IPv6 forwarding disabled on a gateway
#   E16 — IPv6 nftables rules wrong, missing, or not applied
#   E17 — Cannot reach another VM over IPv6 (ping6)
#   E18 — IPv6 service failing (Apache/Squid not on IPv6, or HTTPS over IPv6 fails)
#   E19 — No IPv6 internet access
#
# Usage: sudo ./automark_activity2.1.sh
# =============================================================================

# --- Enforce root ---
if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "  [ERROR] This script must be run with sudo."
    echo "          Usage: sudo ./automark_activity2.1.sh"
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
    echo -e "         ${YELLOW}→ Error $code — see Troubleshooting section of Activity 2.1 guide${NC}"
    ERRORS+=("$code")
    ((FAIL++))
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
}

info() {
    echo -e "  ${CYAN}[INFO]${NC} $1"
}

section() {
    echo ""
    echo -e "${BOLD}--- $1 ---${NC}"
}

diag_ip() {
    echo -e "         ${CYAN}[DIAG] Current addresses:${NC}"
    ip -brief addr show 2>/dev/null | sed 's/^/                /'
}

diag_nft() {
    echo -e "         ${CYAN}[DIAG] Current nft ruleset:${NC}"
    nft list ruleset 2>/dev/null | sed 's/^/                /' | head -60
}

has_ip() {
    ip addr show 2>/dev/null | grep -q "inet $1"
}

# =============================================================================
# Detect which VM this is
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

# =============================================================================
# Shared check functions
# =============================================================================

check_service_active() {
    local service=$1
    local error_code=$2
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        pass "Service $service is active"
    else
        fail "$error_code" "Service $service is not running"
        info "Fix: sudo systemctl enable --now $service"
    fi
}

check_port_listening() {
    local port=$1
    local label=$2
    local error_code=$3
    if ss -tuln 2>/dev/null | grep -q ":$port "; then
        pass "$label listening on port $port"
    else
        fail "$error_code" "$label not listening on port $port"
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

check_http() {
    local url=$1
    local label=$2
    local error_code=$3
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 "$url" 2>/dev/null)
    if [[ "$http_code" =~ ^[23] ]]; then
        pass "HTTP $http_code from $label ($url)"
    else
        fail "$error_code" "Cannot reach $label ($url) — HTTP code: ${http_code:-no response}"
    fi
}

check_https_insecure() {
    local url=$1
    local label=$2
    local error_code=$3
    local http_code
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 8 "$url" 2>/dev/null)
    if [[ "$http_code" =~ ^[23] ]]; then
        pass "HTTPS $http_code from $label ($url)"
    else
        fail "$error_code" "Cannot reach $label via HTTPS ($url) — HTTP code: ${http_code:-no response}"
    fi
}

check_internet() {
    local error_code=$1
    local urls=("https://example.com" "https://www.google.com" "https://1.1.1.1")
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

# =============================================================================
# nftables checks — External Gateway
# =============================================================================

check_nft_service() {
    if systemctl is-active --quiet nftables 2>/dev/null; then
        pass "nftables service is active"
    else
        fail "E4" "nftables service is not running"
        info "Fix: sudo systemctl enable --now nftables"
    fi
}

get_nft_normalised() {
    nft list ruleset 2>/dev/null | tr -s ' \t\n' ' '
}

check_nft_masquerade() {
    local n
    n=$(get_nft_normalised)
    if echo "$n" | grep -qE 'oif[[:space:]]+"eth0"[[:space:]]+masquerade'; then
        pass "nftables NAT masquerade: oif eth0 masquerade"
    else
        fail "E4" "nftables masquerade rule missing or not on eth0"
        diag_nft
    fi
}

check_nft_dnat_http() {
    local n
    n=$(get_nft_normalised)
    if echo "$n" | grep -qE 'dport[[:space:]]+(80|[{][^}]*80[^}]*[}])[[:space:]]+dnat[[:space:]]+to[[:space:]]+192\.168\.1\.80'; then
        pass "nftables DNAT rule: port 80 → 192.168.1.80"
    else
        fail "E4" "DNAT rule for port 80 → 192.168.1.80 not found"
        diag_nft
    fi
}

check_nft_dnat_https() {
    local n
    n=$(get_nft_normalised)
    if echo "$n" | grep -qE 'dport[[:space:]]+(443|[{][^}]*443[^}]*[}])[[:space:]]+dnat[[:space:]]+to[[:space:]]+192\.168\.1\.80'; then
        pass "nftables DNAT rule: port 443 → 192.168.1.80"
    else
        fail "E4" "DNAT rule for port 443 → 192.168.1.80 not found"
        diag_nft
    fi
}

check_nft_forward_inbound() {
    local n
    n=$(get_nft_normalised)
    if echo "$n" | grep -qE 'iif[[:space:]]+"eth0"[[:space:]]+oif[[:space:]]+"eth1"'; then
        pass "nftables forward rule: eth0 → eth1 (inbound to DMZ)"
    else
        fail "E4" "Forward rule for inbound traffic eth0 → eth1 not found"
        diag_nft
    fi
}

check_nft_forward_dmz_out() {
    local n
    n=$(get_nft_normalised)
    if echo "$n" | grep -qE 'iif[[:space:]]+"eth1"[[:space:]]+oif[[:space:]]+"eth0"[[:space:]]+accept'; then
        pass "nftables forward rule: eth1 → eth0 (DMZ to internet)"
    else
        fail "E4" "Forward rule eth1 → eth0 accept not found"
        diag_nft
    fi
}

check_ip_forwarding() {
    local val
    val=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    if [ "$val" = "1" ]; then
        pass "IP forwarding enabled (net.ipv4.ip_forward = 1)"
    else
        fail "E3" "IP forwarding is disabled (net.ipv4.ip_forward = ${val:-not set})"
        info "Fix: sudo sysctl -w net.ipv4.ip_forward=1 and add to /etc/sysctl.conf"
    fi
}

# =============================================================================
# Squid checks — Internal Gateway
# =============================================================================

check_squid_port() {
    if ss -tuln 2>/dev/null | grep -q ":8080 "; then
        pass "Squid listening on port 8080"
    else
        fail "E8" "Squid not listening on port 8080"
        info "Check http_port line in /etc/squid/squid.conf, then: sudo systemctl restart squid"
    fi
}

check_squid_acl_internal() {
    if grep -q "acl internal_network src 10.10.1.0/24" /etc/squid/squid.conf 2>/dev/null; then
        pass "Squid ACL: internal_network defined (10.10.1.0/24)"
    else
        fail "E9" "Squid ACL 'acl internal_network src 10.10.1.0/24' not found in squid.conf"
    fi
}

check_squid_acl_australian() {
    if grep -q "acl australian_sites dstdomain" /etc/squid/squid.conf 2>/dev/null; then
        pass "Squid ACL: australian_sites defined"
    else
        fail "E9" "Squid ACL 'australian_sites' not found in squid.conf"
    fi
}

check_squid_acl_office_hours() {
    if grep -q "acl office_hours time" /etc/squid/squid.conf 2>/dev/null; then
        pass "Squid ACL: office_hours defined"
    else
        fail "E9" "Squid ACL 'office_hours' not found in squid.conf"
    fi
}

check_squid_allow_internal() {
    if grep -q "http_access allow internal_network" /etc/squid/squid.conf 2>/dev/null; then
        pass "Squid rule: http_access allow internal_network present"
    else
        fail "E8" "Squid rule 'http_access allow internal_network' missing from squid.conf"
    fi
}

check_squid_deny_australian() {
    if grep -q "http_access deny australian_sites office_hours" /etc/squid/squid.conf 2>/dev/null; then
        pass "Squid rule: http_access deny australian_sites office_hours present"
    else
        fail "E9" "Squid rule 'http_access deny australian_sites office_hours' missing"
    fi
}

check_squid_rule_order() {
    local deny_line allow_line
    deny_line=$(grep -n "http_access deny australian_sites" /etc/squid/squid.conf 2>/dev/null | head -1 | cut -d: -f1)
    allow_line=$(grep -n "http_access allow internal_network" /etc/squid/squid.conf 2>/dev/null | head -1 | cut -d: -f1)

    if [ -z "$deny_line" ] || [ -z "$allow_line" ]; then
        fail "E9" "Cannot verify rule order — one or both ACL rules are missing"
        return
    fi

    if [ "$deny_line" -lt "$allow_line" ]; then
        pass "Squid ACL rule order correct (deny australian_sites before allow internal_network)"
    else
        fail "E9" "Squid ACL rule order wrong — 'allow internal_network' appears before 'deny australian_sites'"
        info "The deny rule must come first otherwise Australian sites will bypass the block"
    fi
}

# =============================================================================
# Apache/SSL checks — Ubuntu Server
# =============================================================================

check_ssl_cert_exists() {
    if [ -f /etc/ssl/certs/apache-selfsigned.crt ] && [ -f /etc/ssl/private/apache-selfsigned.key ]; then
        pass "SSL certificate and key files exist"
    else
        fail "E7" "SSL cert or key missing"
        info "Expected: /etc/ssl/certs/apache-selfsigned.crt and /etc/ssl/private/apache-selfsigned.key"
    fi
}

check_ssl_params_conf() {
    if [ -f /etc/apache2/conf-available/ssl-params.conf ]; then
        pass "ssl-params.conf exists"
    else
        fail "E7" "ssl-params.conf not found in /etc/apache2/conf-available/"
    fi
}

check_ssl_vhost_conf() {
    if apache2ctl -S 2>/dev/null | grep -q ":443"; then
        pass "Apache SSL virtual host configured on port 443"
    else
        fail "E7" "No Apache virtual host found on port 443"
        info "Check /etc/apache2/sites-enabled/default-ssl.conf and run: sudo a2ensite default-ssl"
    fi
}

check_apache_modules() {
    local missing=()
    for mod in ssl headers; do
        if ! apache2ctl -M 2>/dev/null | grep -q "${mod}_module"; then
            missing+=("$mod")
        fi
    done
    if [ ${#missing[@]} -eq 0 ]; then
        pass "Apache modules enabled: ssl, headers"
    else
        fail "E7" "Apache module(s) not enabled: ${missing[*]}"
        info "Fix: sudo a2enmod ${missing[*]} && sudo systemctl restart apache2"
    fi
}

check_static_route_internal() {
    if ip route show 2>/dev/null | grep -q "10.10.1.0/24 via 192.168.1.1"; then
        pass "Static route to 10.10.1.0/24 via 192.168.1.1 present"
    else
        fail "E6" "Static route to 10.10.1.0/24 via 192.168.1.1 missing"
        info "Add to /etc/netplan/50-cloud-init.yaml: - to: 10.10.1.0/24 / via: 192.168.1.1"
        info "Then: sudo netplan apply"
    fi
}

check_custom_webpage() {
    local content
    content=$(curl -s --max-time 5 http://localhost 2>/dev/null)
    if echo "$content" | grep -qi "Welcome to My Web Server\|welcome.*web server"; then
        pass "Custom web page content detected"
    elif echo "$content" | grep -qi "Apache2 Default Page\|It works"; then
        fail "E6" "Apache is serving the default page — custom content not configured"
        info "Edit /var/www/html/index.html and replace the default content with your name"
    else
        warn "Could not confirm custom page content — check manually in browser"
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

run_external_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: External Gateway${NC}"

    section "IP Forwarding"
    check_ip_forwarding

    section "Part A — nftables Service"
    check_nft_service

    section "Part A — NAT Masquerade"
    check_nft_masquerade

    section "Part A — DNAT Port Forwarding"
    check_nft_dnat_http
    check_nft_dnat_https

    section "Part A — Forward Rules"
    check_nft_forward_inbound
    check_nft_forward_dmz_out

    section "Connectivity (E5)"
    check_ping "192.168.1.1"  "Internal Gateway (DMZ side)" "E5"
    check_ping "192.168.1.80" "Ubuntu Server"               "E5"
    check_ping "10.10.1.1"   "Ubuntu Desktop"               "E5"

    section "Internet Access (E5)"
    check_internet "E5"

    section "Part A — Web Server Reachable via DNAT (E11)"
    check_http           "http://192.168.1.80"  "Ubuntu Server HTTP"  "E11"
    check_https_insecure "https://192.168.1.80" "Ubuntu Server HTTPS" "E11"

    # =========================================================================
    # IPv6 test layer — mirrors the IPv4 checks above (External Gateway)
    # =========================================================================

    section "IPv6 Addressing (E13)"
    # ASSUMPTION: External Gateway holds the transit-side v6 on wg0 and the DMZ-side v6 on eth1.
    check_ip6 wg0  "2404:9400:29c1:df00::1/64"   "E13"   # ASSUMPTION: wg0 v6 /64 (transit)
    check_ip6 eth1 "2404:9400:29c1:df10::254/64" "E13"   # ASSUMPTION: eth1 v6 /64 (DMZ)

    section "IPv6 Forwarding (E15)"
    check_ip6_forward "E15"

    section "IPv6 Routing (E14)"
    check_route6_get "2001:4860:4860::8888"    "dev wg0"                    "E14" "internet (via wg0 tunnel)"
    check_route6_get "2404:9400:29c1:df20::1"  "via 2404:9400:29c1:df10::1" "E14" "internal (Desktop via IntGW)"

    section "IPv6 nftables — Inbound Web Forward (E16)"
    # IPv4 uses table ip nat DNAT (80/443 -> 192.168.1.80) plus an inet-filter forward accept.
    # For IPv6 native routing there is typically no DNAT: mirror the forward-accept path instead.
    check_nft6 'iif(name)? "eth0" oif(name)? "eth1" tcp dport [{] 80, 443 [}] ct state new accept' \
        "IPv6/inet forward accept: eth0 -> eth1 web (80,443) to server" "E16"
    check_nft6 'iif(name)? "eth1" oif(name)? "eth0" accept' \
        "IPv6/inet forward accept: eth1 -> eth0 (DMZ to internet)" "E16"

    section "IPv6 Connectivity (E17)"
    check_ping6 "2404:9400:29c1:df10::1"  "Internal Gateway (DMZ side)" "E17"
    check_ping6 "2404:9400:29c1:df10::80" "Ubuntu Server"               "E17"
    check_ping6 "2404:9400:29c1:df20::1"  "Ubuntu Desktop"              "E17"

    section "IPv6 Service — Web Server Reachable over IPv6 (E18)"
    check_curl6 "https://[2404:9400:29c1:df10::80]/" "Ubuntu Server HTTPS (via ExtGW)" "E18"

    section "IPv6 Internet Access (E19)"
    check_internet6 "E19"
}

run_internal_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: Internal Gateway${NC}"

    section "IP Forwarding"
    check_ip_forwarding

    section "Part D — Squid Service (E8)"
    check_service_active "squid" "E12"
    check_squid_port
    check_squid_allow_internal

    section "Part D — Squid ACLs (E9)"
    check_squid_acl_internal
    check_squid_acl_australian
    check_squid_acl_office_hours

    section "Part D — Squid Rule Order (E9)"
    check_squid_deny_australian
    check_squid_rule_order

    section "Connectivity (E5)"
    check_ping "192.168.1.254" "External Gateway" "E5"
    check_ping "192.168.1.80"  "Ubuntu Server"    "E5"
    check_ping "10.10.1.1"    "Ubuntu Desktop"    "E5"
    check_internet "E5"

    # =========================================================================
    # IPv6 test layer — mirrors the IPv4 checks above (Internal Gateway)
    # =========================================================================

    section "IPv6 Addressing (E13)"
    check_ip6 eth0 "2404:9400:29c1:df10::1/64"   "E13"   # DMZ side
    check_ip6 eth1 "2404:9400:29c1:df20::254/64" "E13"   # internal side

    section "IPv6 Forwarding (E15)"
    check_ip6_forward "E15"

    section "IPv6 Routing (E14)"
    check_route6_get "2001:4860:4860::8888" "via 2404:9400:29c1:df10::254" "E14" "internet (via ExtGW)"

    section "IPv6 Service — Squid on IPv6 (E18)"
    check_listen6 8080 "Squid" "E18"

    section "IPv6 Connectivity (E17)"
    check_ping6 "2404:9400:29c1:df10::254" "External Gateway" "E17"
    check_ping6 "2404:9400:29c1:df10::80"  "Ubuntu Server"    "E17"
    check_ping6 "2404:9400:29c1:df20::1"   "Ubuntu Desktop"   "E17"

    section "IPv6 Internet Access (E19)"
    check_internet6 "E19"
}

run_ubuntu_server() {
    echo -e "\n${BOLD}${CYAN}VM detected: Ubuntu Server${NC}"

    section "Static Route Check (E6)"
    check_static_route_internal

    section "Part C — Apache Service (E7)"
    check_service_active "apache2" "E7"
    check_port_listening "80"  "Apache HTTP"  "E7"
    check_port_listening "443" "Apache HTTPS" "E7"

    section "Part C — Apache Modules (E7)"
    check_apache_modules

    section "Part C — SSL Configuration (E7)"
    check_ssl_cert_exists
    check_ssl_params_conf
    check_ssl_vhost_conf

    section "Part C — Web Server Response (E7)"
    check_http           "http://192.168.1.80"  "Apache HTTP"  "E7"
    check_https_insecure "https://192.168.1.80" "Apache HTTPS" "E7"

    section "Part C — Custom Webpage (E7)"
    check_custom_webpage

    section "Connectivity (E5)"
    check_ping "192.168.1.254" "External Gateway"            "E5"
    check_ping "192.168.1.1"   "Internal Gateway (DMZ side)" "E5"
    check_internet "E5"

    # =========================================================================
    # IPv6 test layer — mirrors the IPv4 checks above (Ubuntu Server)
    # =========================================================================

    section "IPv6 Addressing (E13)"
    check_ip6 eth0 "2404:9400:29c1:df10::80/64" "E13"

    section "IPv6 Routing (E14)"
    check_route6_get "2001:4860:4860::8888"   "via 2404:9400:29c1:df10::254" "E14" "internet (default via ExtGW)"
    # Mirror of the IPv4 static route 10.10.1.0/24 via 192.168.1.1:
    check_route6_get "2404:9400:29c1:df20::1" "via 2404:9400:29c1:df10::1"   "E14" "internal /64 (via IntGW)"

    section "IPv6 Service — Apache on IPv6 (E18)"
    check_listen6 80  "Apache HTTP"  "E18"
    check_listen6 443 "Apache HTTPS" "E18"
    check_curl6 "https://[2404:9400:29c1:df10::80]/" "Apache HTTPS (local IPv6)" "E18"

    section "IPv6 Connectivity (E17)"
    check_ping6 "2404:9400:29c1:df10::254" "External Gateway"            "E17"
    check_ping6 "2404:9400:29c1:df10::1"   "Internal Gateway (DMZ side)" "E17"

    section "IPv6 Internet Access (E19)"
    check_internet6 "E19"
}

run_ubuntu_desktop() {
    echo -e "\n${BOLD}${CYAN}VM detected: Ubuntu Desktop${NC}"

    section "Part C — Web Server Access (E7)"
    check_http           "http://192.168.1.80"  "Ubuntu Server HTTP (direct)"  "E7"
    check_https_insecure "https://192.168.1.80" "Ubuntu Server HTTPS (direct)" "E7"

    section "Part D — Squid Proxy Reachability (E8)"
    if nc -z -w 3 10.10.1.254 8080 2>/dev/null; then
        pass "Squid proxy reachable at 10.10.1.254:8080"
    else
        fail "E8" "Cannot reach Squid proxy at 10.10.1.254:8080"
        info "Ensure Squid is running on Internal Gateway: sudo systemctl status squid"
    fi

    section "Part D — Web Access via Proxy (E8)"
    local proxy_code
    proxy_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 \
        --proxy "http://10.10.1.254:8080" "http://192.168.1.80" 2>/dev/null)
    if [[ "$proxy_code" =~ ^[2345] ]]; then
        pass "HTTP $proxy_code — Squid proxy is handling requests (verify page loads in Firefox)"
    else
        fail "E8" "No response from Squid proxy (HTTP code: ${proxy_code:-no response})"
        info "Ensure Firefox proxy is configured: Settings → Network Settings → 10.10.1.254:8080"
    fi

    section "Connectivity (E5)"
    check_ping "10.10.1.254" "Internal Gateway" "E5"
    check_ping "192.168.1.80" "Ubuntu Server"   "E5"
    check_internet "E5"

    # =========================================================================
    # IPv6 test layer — mirrors the IPv4 checks above (Ubuntu Desktop)
    # =========================================================================

    section "IPv6 Addressing (E13)"
    check_ip6 eth0 "2404:9400:29c1:df20::1/64" "E13"

    section "IPv6 Routing (E14)"
    check_route6_get "2001:4860:4860::8888" "via 2404:9400:29c1:df20::254" "E14" "internet (default via IntGW)"

    section "IPv6 Service — Web Server Access over IPv6 (E18)"
    check_curl6 "https://[2404:9400:29c1:df10::80]/" "Ubuntu Server HTTPS (direct, IPv6)" "E18"

    section "IPv6 Service — Web Access via Squid over IPv6 (E18)"
    # ASSUMPTION: Squid also serves the internal /64 gateway address over IPv6 on 8080.
    local proxy6_code
    proxy6_code=$(curl -6 -s -o /dev/null -w "%{http_code}" --max-time 8 \
        --proxy "http://[2404:9400:29c1:df20::254]:8080" "http://[2404:9400:29c1:df10::80]/" 2>/dev/null)
    if [[ "$proxy6_code" =~ ^[2345] ]]; then
        pass "HTTP $proxy6_code — Squid proxy handling requests over IPv6"
    else
        fail "E18" "No response from Squid proxy over IPv6 (HTTP code: ${proxy6_code:-no response})"
        info "ASSUMPTION: verify Squid listens on the IntGW IPv6 [2404:9400:29c1:df20::254]:8080"
    fi

    section "IPv6 Connectivity (E17)"
    check_ping6 "2404:9400:29c1:df20::254" "Internal Gateway" "E17"
    check_ping6 "2404:9400:29c1:df10::80"  "Ubuntu Server"    "E17"

    section "IPv6 Internet Access (E19)"
    check_internet6 "E19"
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
        echo -e "  ${RED}${BOLD}Error codes: $unique_errors${NC}"
        echo -e "  ${YELLOW}Look up each code in Section 8 of the Activity 2.1 guide.${NC}"
        echo ""
    else
        echo ""
        echo -e "  ${GREEN}${BOLD}All checks passed! Activity 2.1 configuration looks correct.${NC}"
        echo ""
    fi
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Activity 2.1 Automarker — NAT, SSL & Proxy${NC}"
echo -e "${BOLD} 7015ICT | Griffith University${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

VM=$(detect_vm)

case "$VM" in
    external_gateway)  run_external_gateway ;;
    internal_gateway)  run_internal_gateway ;;
    ubuntu_server)     run_ubuntu_server ;;
    ubuntu_desktop)    run_ubuntu_desktop ;;
    *)
        echo ""
        echo -e "${RED}[ERROR]${NC} Could not detect which VM this is."
        echo ""
        echo "        Expected IP addresses:"
        echo "          External Gateway  — eth1 at 192.168.1.254"
        echo "          Internal Gateway  — eth0 at 192.168.1.1 AND eth1 at 10.10.1.254"
        echo "          Ubuntu Server     — eth0 at 192.168.1.80"
        echo "          Ubuntu Desktop    — eth0 at 10.10.1.1"
        echo ""
        echo "        Your current addresses:"
        ip -brief addr show 2>/dev/null | sed 's/^/          /'
        echo ""
        echo -e "        ${YELLOW}If your IPs look correct, refer to E1 in the Activity 2.1 Troubleshooting guide.${NC}"
        echo ""
        exit 1
        ;;
esac

print_summary
