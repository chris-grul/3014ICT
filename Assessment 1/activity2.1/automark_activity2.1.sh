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
