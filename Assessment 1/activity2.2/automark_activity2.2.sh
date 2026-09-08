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
# Usage: sudo bash automark_activity2.2.sh
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
    if has_ip "192.168.1.1" && has_ip "10.10.1.254"; then
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
    if [ "$result" = "192.168.1.80" ]; then
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
        if [ "$fwd" = "192.168.1.80" ]; then
            pass "Forward lookup via 192.168.1.1: www.$DOMAIN → 192.168.1.80"
        else
            fail "E6" "www.$DOMAIN did not resolve via 192.168.1.1 (got: ${fwd:-no response})"
        fi
    fi

    section "Internet Access"
    check_internet "E9"
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
        if [ "$fwd" = "192.168.1.80" ]; then
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
    internal_gateway) run_internal_gateway ;;
    ubuntu_server)    run_ubuntu_server ;;
    ubuntu_desktop)   run_ubuntu_desktop ;;
    *)
        echo ""
        echo -e "${RED}[ERROR]${NC} Could not detect which VM this is."
        echo ""
        echo "        Expected IP addresses:"
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
