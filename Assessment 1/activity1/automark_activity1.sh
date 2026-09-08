#!/bin/bash
# =============================================================================
# Automarking Script - Activity 1: DMZ Networks
# 7015ICT - Cyber Security Operation Centres | Griffith University
# =============================================================================
# Run this script on any of the four lab VMs after completing the activity.
# The script will auto-detect which VM it is running on and perform the
# appropriate checks. Any failures are reported as numbered error codes
# that you can look up in the Troubleshooting section of the activity guide.
#
# Usage: sudo ./automark_activity1.sh
# =============================================================================

# --- Enforce root ---
if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "  [ERROR] This script must be run with sudo."
    echo "          Usage: sudo ./automark_activity1.sh"
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

# =============================================================================
# Per-VM check suites
# =============================================================================

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
echo -e "${BOLD} Activity 1 Automarker — DMZ Networks${NC}"
echo -e "${BOLD} 7015ICT Cyber Security Operation Centres | Griffith University${NC}"
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
        echo "        If no IPs are assigned, start with Error E1 in the guide."
        echo "        If IPs look correct but detection failed, check for typos"
        echo "        in your netplan config and run: sudo netplan apply"
        exit 1
        ;;
esac

print_summary