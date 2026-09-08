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
