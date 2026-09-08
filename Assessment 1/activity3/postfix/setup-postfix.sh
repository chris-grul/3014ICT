#!/bin/bash
# =============================================================================
# Activity 3 - Postfix Setup Script (Ubuntu Server)
# Downloads main.cf and virtual alias templates from GitHub,
# prompts for student domain, substitutes it in, and places files.
# =============================================================================

set -e

REPO="https://raw.githubusercontent.com/7015ICT/SOC-Activities-Project-Griffith/main/activity3/postfix"
MAINCF_URL="$REPO/main.cf.template"
VIRTUAL_URL="$REPO/virtual.template"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Activity 3 — Postfix Config Setup${NC}"
echo -e "${BOLD} 7015ICT | Griffith University${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# --- Enforce sudo ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Run this script with sudo: sudo bash setup-postfix.sh"
    exit 1
fi

# =============================================================================
# Step 1 — Get student domain
# =============================================================================

echo -e "${CYAN}[1/5]${NC} Enter your domain name (e.g. example7015ict.com):"
echo -e "      This is the domain you configured in Activity 2 BIND9."
echo ""
read -rp "      Domain: " STUDENT_DOMAIN

# Strip whitespace
STUDENT_DOMAIN=$(echo "$STUDENT_DOMAIN" | tr -d '[:space:]')

if [ -z "$STUDENT_DOMAIN" ]; then
    echo -e "${RED}[ERROR]${NC} Domain cannot be empty."
    exit 1
fi

echo ""
echo -e "      Using domain: ${BOLD}${STUDENT_DOMAIN}${NC}"
echo ""

# =============================================================================
# Step 2 — Download templates from GitHub
# =============================================================================

echo -e "${CYAN}[2/5]${NC} Downloading config templates from GitHub..."

TMP_DIR=$(mktemp -d)

if ! curl -fsSL "$MAINCF_URL" -o "$TMP_DIR/main.cf.template" 2>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Failed to download main.cf template."
    echo "        Check your internet connection or visit:"
    echo "        $MAINCF_URL"
    echo ""
    echo "        If GitHub is unreachable, copy the template from the"
    echo "        Activity 3 guide and create /etc/postfix/main.cf manually."
    exit 1
fi

if ! curl -fsSL "$VIRTUAL_URL" -o "$TMP_DIR/virtual.template" 2>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Failed to download virtual template."
    echo "        URL: $VIRTUAL_URL"
    exit 1
fi

echo -e "  ${GREEN}[DONE]${NC} Templates downloaded."
echo ""

# =============================================================================
# Step 3 — Show templates and confirm before substituting
# =============================================================================

echo -e "${CYAN}[3/5]${NC} Review what will be installed:"
echo ""
echo -e "  ${BOLD}--- /etc/postfix/main.cf ---${NC}"
sed "s/DOMAIN/$STUDENT_DOMAIN/g" "$TMP_DIR/main.cf.template" | sed 's/^/  /'
echo ""
echo -e "  ${BOLD}--- /etc/postfix/virtual ---${NC}"
sed "s/DOMAIN/$STUDENT_DOMAIN/g" "$TMP_DIR/virtual.template" | sed 's/^/  /'
echo ""

read -rp "  Does this look correct? (yes/no): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo ""
    echo -e "${YELLOW}[CANCELLED]${NC} No files were written. Edit the templates on GitHub and re-run."
    exit 0
fi

echo ""

# =============================================================================
# Step 4 — Substitute domain and install files
# =============================================================================

echo -e "${CYAN}[4/5]${NC} Installing config files..."

# Back up existing main.cf if it exists
if [ -f /etc/postfix/main.cf ]; then
    cp /etc/postfix/main.cf /etc/postfix/main.cf.backup
    echo -e "  ${YELLOW}[BACKUP]${NC} Existing main.cf saved to /etc/postfix/main.cf.backup"
fi

# Write main.cf
sed "s/DOMAIN/$STUDENT_DOMAIN/g" "$TMP_DIR/main.cf.template" > /etc/postfix/main.cf
echo -e "  ${GREEN}[DONE]${NC} /etc/postfix/main.cf written"

# Verify no unreplaced placeholders remain
if grep -qw "DOMAIN" /etc/postfix/main.cf; then
    echo -e "  ${RED}[FAIL]${NC} Unreplaced placeholders found in main.cf — substitution failed:"
    grep -nw "DOMAIN" /etc/postfix/main.cf | sed 's/^/         /'
    rm -rf "$TMP_DIR"
    exit 1
fi
echo -e "  ${GREEN}[DONE]${NC} No unreplaced placeholders in main.cf"

# Write virtual
sed "s/DOMAIN/$STUDENT_DOMAIN/g" "$TMP_DIR/virtual.template" > /etc/postfix/virtual
echo -e "  ${GREEN}[DONE]${NC} /etc/postfix/virtual written"

# Verify no unreplaced placeholders remain
if grep -qw "DOMAIN" /etc/postfix/virtual; then
    echo -e "  ${RED}[FAIL]${NC} Unreplaced placeholders found in virtual — substitution failed:"
    grep -nw "DOMAIN" /etc/postfix/virtual | sed 's/^/         /'
    rm -rf "$TMP_DIR"
    exit 1
fi
echo -e "  ${GREEN}[DONE]${NC} No unreplaced placeholders in virtual"

# Compile virtual alias database
postmap /etc/postfix/virtual
echo -e "  ${GREEN}[DONE]${NC} /etc/postfix/virtual.db compiled"

# Clean up temp files
rm -rf "$TMP_DIR"

echo ""

# =============================================================================
# Step 5 — Verify
# =============================================================================

echo -e "${CYAN}[5/5]${NC} Verifying configuration..."
echo ""

# Check postfix config
echo -e "  ${BOLD}postfix check:${NC}"
if postfix_out=$(postfix check 2>&1); then
    if [ -z "$postfix_out" ]; then
        echo -e "  ${GREEN}[PASS]${NC} No errors found"
    else
        echo -e "  ${YELLOW}[WARN]${NC} $postfix_out"
    fi
else
    echo -e "  ${RED}[FAIL]${NC} postfix check returned errors:"
    echo "$postfix_out" | sed 's/^/         /'
fi

echo ""

# Check key values
echo -e "  ${BOLD}Key settings confirmed:${NC}"
echo -e "  myhostname      = $(postconf -h myhostname 2>/dev/null)"
echo -e "  mydomain        = $(postconf -h mydomain 2>/dev/null)"
echo -e "  inet_interfaces = $(postconf -h inet_interfaces 2>/dev/null)"
echo -e "  home_mailbox    = $(postconf -h home_mailbox 2>/dev/null)"

echo ""

# Check virtual alias mapping
echo -e "  ${BOLD}Virtual alias lookup:${NC}"
RESULT1=$(postmap -q "desktop-user@${STUDENT_DOMAIN}" hash:/etc/postfix/virtual 2>/dev/null)
RESULT2=$(postmap -q "server-user@${STUDENT_DOMAIN}" hash:/etc/postfix/virtual 2>/dev/null)

if [ "$RESULT1" = "user1" ]; then
    echo -e "  ${GREEN}[PASS]${NC} desktop-user@${STUDENT_DOMAIN} → user1"
else
    echo -e "  ${RED}[FAIL]${NC} desktop-user@${STUDENT_DOMAIN} did not resolve to user1 (got: ${RESULT1:-nothing})"
fi

if [ "$RESULT2" = "user2" ]; then
    echo -e "  ${GREEN}[PASS]${NC} server-user@${STUDENT_DOMAIN} → user2"
else
    echo -e "  ${RED}[FAIL]${NC} server-user@${STUDENT_DOMAIN} did not resolve to user2 (got: ${RESULT2:-nothing})"
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Next steps:${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  1. Create system users (if not done already):"
echo "       sudo adduser user1"
echo "       sudo adduser user2"
echo ""
echo "  2. Restart Postfix:"
echo "       sudo systemctl restart postfix"
echo ""
echo "  3. Continue to Part C — run setup-dovecot.sh to install Dovecot."
echo "     The LMTP socket doesn't exist until Dovecot is configured,"
echo "     so end-to-end delivery will not work until that step is done."
echo ""
