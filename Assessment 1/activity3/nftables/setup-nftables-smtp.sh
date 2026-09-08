#!/bin/bash
# =============================================================================
# Activity 3 - nftables SMTP Update (External Gateway)
# Downloads the updated nftables.conf from GitHub (adds port 25 SMTP
# forwarding and DNAT to the Activity 2 ruleset) and applies it.
#
# Run on: External Gateway
# Usage:  sudo bash setup-nftables-smtp.sh
# =============================================================================

set -e

REPO="https://raw.githubusercontent.com/7015ICT/SOC-Activities-Project-Griffith/main/activity3/nftables"
CONF_URL="$REPO/nftables.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Activity 3 — nftables SMTP Update${NC}"
echo -e "${BOLD} 7015ICT | Griffith University${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# --- Enforce root ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Run with sudo: sudo bash setup-nftables-smtp.sh"
    exit 1
fi

# Ensure stdin works even if script was piped
if [ ! -t 0 ]; then exec < /dev/tty; fi

# =============================================================================
# Step 1 — Show current ruleset
# =============================================================================
echo -e "${CYAN}[1/4]${NC} Current nftables ruleset:"
echo ""
nft list ruleset 2>/dev/null | sed 's/^/  /' || echo "  (empty or nftables not running)"
echo ""

# =============================================================================
# Step 2 — Download and show the new config
# =============================================================================
echo -e "${CYAN}[2/4]${NC} Downloading updated nftables.conf from GitHub..."
echo "      (adds port 25 SMTP forward rule and DNAT to existing Activity 2 ruleset)"
echo ""

TMP=$(mktemp)

if ! curl -fsSL "$CONF_URL" -o "$TMP" 2>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Could not download nftables.conf from GitHub."
    echo "        URL: $CONF_URL"
    echo ""
    echo "        If GitHub is unreachable, review the full ruleset in"
    echo "        the Activity 3 guide and update /etc/nftables.conf manually."
    rm -f "$TMP"
    exit 1
fi

echo -e "  ${GREEN}[DONE]${NC} Downloaded. Review before applying:"
echo ""
cat "$TMP" | sed 's/^/  /'
echo ""

# =============================================================================
# Step 3 — Confirm and apply
# =============================================================================
echo -e "${CYAN}[3/4]${NC} What changed from Activity 2:"
echo ""
echo "  chain forward — new rule added:"
echo "    iif \"eth0\" oif \"eth1\" tcp dport 25 ct state new accept"
echo "    → Allows inbound SMTP connections through the External Gateway"
echo ""
echo "  chain prerouting — new DNAT rule added:"
echo "    iif \"eth0\" tcp dport 25 dnat to 192.168.1.80:25"
echo "    → Forwards port 25 traffic to the Ubuntu Server mail server"
echo ""
echo -e "  ${YELLOW}Note:${NC} In this lab you cannot test inbound SMTP from an external"
echo "  sender — the network is not exposed to the public internet for"
echo "  inbound mail. Validation is done via nft list ruleset only."
echo ""

echo -e "  ${YELLOW}[INFO]${NC} Applying ruleset now..."
echo ""

# Back up existing config
cp /etc/nftables.conf /etc/nftables.conf.activity2.backup
echo -e "  ${YELLOW}[BACKUP]${NC} Existing config saved to /etc/nftables.conf.activity2.backup"

# Install and apply
cp "$TMP" /etc/nftables.conf
rm -f "$TMP"

nft -f /etc/nftables.conf
echo -e "  ${GREEN}[DONE]${NC} Ruleset applied"

# =============================================================================
# Step 4 — Verify
# =============================================================================
echo ""
echo -e "${CYAN}[4/4]${NC} Verifying updated ruleset..."
echo ""

# Check SMTP forward rule
if nft list ruleset | grep -q "dport 25"; then
    echo -e "  ${GREEN}[PASS]${NC} Port 25 rule found in ruleset"
else
    echo -e "  ${RED}[FAIL]${NC} Port 25 rule not found — re-check /etc/nftables.conf"
fi

# Check DNAT for port 25
if nft list ruleset | grep -q "dport 25.*dnat\|dnat.*192.168.1.80"; then
    echo -e "  ${GREEN}[PASS]${NC} DNAT rule for port 25 → 192.168.1.80 found"
else
    echo -e "  ${RED}[FAIL]${NC} DNAT rule for port 25 not found"
fi

# Check Activity 2 rules still intact
if nft list ruleset | grep -q "dport { 80, 443 }"; then
    echo -e "  ${GREEN}[PASS]${NC} Activity 2 HTTP/HTTPS rules still intact"
else
    echo -e "  ${YELLOW}[WARN]${NC} HTTP/HTTPS rules not found — check Activity 2 rules survived"
fi

if nft list ruleset | grep -q "masquerade"; then
    echo -e "  ${GREEN}[PASS]${NC} NAT masquerade rule still intact"
else
    echo -e "  ${RED}[FAIL]${NC} NAT masquerade missing — internet will not work"
fi

# Check persistence
if systemctl is-enabled nftables &>/dev/null; then
    echo -e "  ${GREEN}[PASS]${NC} nftables service enabled — rules persist on reboot"
else
    echo -e "  ${YELLOW}[WARN]${NC} nftables service not enabled"
    echo "         Fix: sudo systemctl enable nftables"
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Part E complete.${NC}"
echo ""
echo "  Validate with:"
echo "    sudo nft list ruleset"
echo ""
echo "  Confirm the following are all present:"
echo "    1. chain forward — dport 25 accept rule"
echo "    2. chain prerouting — dport 25 dnat to 192.168.1.80:25"
echo "    3. chain forward — dport { 80, 443 } rules (Activity 2)"
echo "    4. chain postrouting — masquerade on eth0"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
