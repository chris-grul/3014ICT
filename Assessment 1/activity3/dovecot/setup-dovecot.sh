#!/bin/bash
# =============================================================================
# Activity 3 - Dovecot Setup Script (Ubuntu Server)
# Downloads Dovecot config templates from GitHub, applies them, and
# walks students through entering the 10-master.conf socket values
# so they understand what each setting does.
# =============================================================================

set -e

REPO="https://raw.githubusercontent.com/7015ICT/SOC-Activities-Project-Griffith/main/activity3/dovecot"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Activity 3 — Dovecot Config Setup${NC}"
echo -e "${BOLD} 7015ICT | Griffith University${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# --- Enforce sudo ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Run this script with sudo: sudo bash setup-dovecot.sh"
    exit 1
fi

# =============================================================================
# Helper — download a template
# =============================================================================
download_template() {
    local name=$1
    local url=$2
    local dest=$3

    if ! curl -fsSL "$url" -o "$dest" 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} Could not download $name from GitHub."
        echo "        URL: $url"
        echo "        Check your internet connection or copy the config manually"
        echo "        from the Activity 3 guide."
        exit 1
    fi
    echo -e "  ${GREEN}[DONE]${NC} $name downloaded"
}

# =============================================================================
# Step 1 — Install Dovecot packages
# =============================================================================
echo -e "${CYAN}[1/6]${NC} Checking Dovecot installation..."

PACKAGES="dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd"
MISSING=""
for pkg in $PACKAGES; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -n "$MISSING" ]; then
    echo -e "  ${YELLOW}[INFO]${NC} Installing missing packages:$MISSING"
    apt-get update -q
    apt-get install -y -q $MISSING
else
    echo -e "  ${GREEN}[DONE]${NC} All Dovecot packages already installed"
fi

echo ""

# =============================================================================
# Step 2 — Download and apply fixed config files
# =============================================================================
echo -e "${CYAN}[2/6]${NC} Downloading and applying config files..."
echo ""
echo "  The following files have fixed values for this lab and require"
echo "  no student input — they are applied directly:"
echo ""
echo "    /etc/dovecot/dovecot.conf    → protocols = imap pop3 lmtp"
echo "    conf.d/10-mail.conf          → mail_location = maildir:~/Maildir"
echo "    conf.d/10-auth.conf          → disable_plaintext_auth = no"
echo "    conf.d/10-ssl.conf           → ssl = no"
echo "    conf.d/20-lmtp.conf          → auth_username_format = %n"
echo ""

TMP=$(mktemp -d)

# Download only the 10-master.conf template — the other files are edited directly
download_template "10-master.template" "$REPO/10-master.conf.template"  "$TMP/10-master.template"

echo ""

# Apply fixed settings directly via sed — no download needed for these
# dovecot.conf — set protocols
if grep -q "^protocols" /etc/dovecot/dovecot.conf 2>/dev/null; then
    sed -i 's/^protocols.*/protocols = imap pop3 lmtp/' /etc/dovecot/dovecot.conf
else
    echo "protocols = imap pop3 lmtp" >> /etc/dovecot/dovecot.conf
fi
echo -e "  ${GREEN}[DONE]${NC} dovecot.conf — protocols = imap pop3 lmtp"

# 10-mail.conf — mail_location and mail_privileged_group
sed -i 's|^#*\s*mail_location\s*=.*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
sed -i 's|^#*\s*mail_privileged_group\s*=.*|mail_privileged_group = mail|' /etc/dovecot/conf.d/10-mail.conf
echo -e "  ${GREEN}[DONE]${NC} 10-mail.conf — mail_location and mail_privileged_group set"

# 10-auth.conf — plaintext auth
sed -i 's|^#*\s*disable_plaintext_auth\s*=.*|disable_plaintext_auth = no|' /etc/dovecot/conf.d/10-auth.conf
sed -i 's|^#*\s*auth_mechanisms\s*=.*|auth_mechanisms = plain login|' /etc/dovecot/conf.d/10-auth.conf
echo -e "  ${GREEN}[DONE]${NC} 10-auth.conf — disable_plaintext_auth and auth_mechanisms set"

# 10-ssl.conf — disable ssl
sed -i 's|^#*\s*ssl\s*=.*|ssl = no|' /etc/dovecot/conf.d/10-ssl.conf
echo -e "  ${GREEN}[DONE]${NC} 10-ssl.conf — ssl = no"

# 20-lmtp.conf — auth_username_format
# Strips @domain from the username so virtual aliases (desktop-user@domain → user1)
# resolve correctly when LMTP hands off to Dovecot. Without this, Dovecot looks
# for a system user literally named "desktop-user@domain" and bounces with
# "User doesn't exist".
LMTPCONF=/etc/dovecot/conf.d/20-lmtp.conf
if [ -f "$LMTPCONF" ]; then
    if grep -q "^auth_username_format" "$LMTPCONF"; then
        sed -i 's|^auth_username_format.*|auth_username_format = %n|' "$LMTPCONF"
    else
        echo "" >> "$LMTPCONF"
        echo "# Strip @domain from username so virtual aliases resolve to system accounts" >> "$LMTPCONF"
        echo "auth_username_format = %n" >> "$LMTPCONF"
    fi
    echo -e "  ${GREEN}[DONE]${NC} 20-lmtp.conf — auth_username_format = %n"
else
    echo -e "  ${YELLOW}[WARN]${NC} 20-lmtp.conf not found — skipping auth_username_format"
fi

echo ""

# =============================================================================
# Step 3 — Interactive 10-master.conf setup
# =============================================================================
echo -e "${CYAN}[3/6]${NC} Configure 10-master.conf — Socket Settings"
echo ""
echo "  The 10-master.conf file defines the Unix sockets that connect"
echo "  Postfix and Dovecot. You will be asked to enter each value."
echo "  Read the explanation for each one before answering."
echo ""
echo -e "  ${YELLOW}Press Enter to use the correct answer shown in [brackets].${NC}"
echo ""

# --- IMAP port ---
echo -e "  ${BOLD}IMAP listener port${NC}"
echo "  Dovecot listens for IMAP connections on this port."
echo "  Standard IMAP port is 143. Thunderbird will connect here."
read -rp "  Enter IMAP port [143]: " IMAP_PORT
IMAP_PORT=${IMAP_PORT:-143}
if [ "$IMAP_PORT" != "143" ]; then
    echo -e "  ${YELLOW}[NOTE]${NC} Non-standard port entered: $IMAP_PORT"
    echo "         Standard is 143 — make sure Thunderbird matches."
fi
echo ""

# --- LMTP socket mode ---
echo -e "  ${BOLD}LMTP socket mode (dovecot-lmtp)${NC}"
echo "  This socket is used by Postfix to hand mail to Dovecot."
echo "  mode = 0600 means only the owner (postfix) can read/write."
echo "  This prevents other system users from injecting mail directly."
read -rp "  Enter LMTP socket mode [0600]: " LMTP_MODE
LMTP_MODE=${LMTP_MODE:-0600}
if [ "$LMTP_MODE" != "0600" ]; then
    echo -e "  ${YELLOW}[WARN]${NC} Expected 0600 for security — got $LMTP_MODE"
fi
echo ""

# --- LMTP socket user ---
echo -e "  ${BOLD}LMTP socket owner (user)${NC}"
echo "  The socket must be owned by the postfix system user so"
echo "  Postfix can write to it."
read -rp "  Enter LMTP socket user [postfix]: " LMTP_USER
LMTP_USER=${LMTP_USER:-postfix}
echo ""

# --- LMTP socket group ---
echo -e "  ${BOLD}LMTP socket group${NC}"
echo "  The socket group should also be postfix so the Postfix"
echo "  process can connect to it."
read -rp "  Enter LMTP socket group [postfix]: " LMTP_GROUP
LMTP_GROUP=${LMTP_GROUP:-postfix}
echo ""

# --- Auth socket mode ---
echo -e "  ${BOLD}Auth socket mode (/var/spool/postfix/private/auth)${NC}"
echo "  This socket lets Postfix ask Dovecot to verify user passwords."
echo "  mode = 0666 allows both postfix and dovecot to connect to it."
echo "  Without this, Postfix cannot authenticate users."
read -rp "  Enter auth socket mode [0666]: " AUTH_MODE
AUTH_MODE=${AUTH_MODE:-0666}
if [ "$AUTH_MODE" != "0666" ]; then
    echo -e "  ${YELLOW}[WARN]${NC} Expected 0666 so Postfix can connect — got $AUTH_MODE"
fi
echo ""

# --- Auth socket user ---
echo -e "  ${BOLD}Auth socket owner (user)${NC}"
echo "  postfix must own this socket so the Postfix process has access."
read -rp "  Enter auth socket user [postfix]: " AUTH_USER
AUTH_USER=${AUTH_USER:-postfix}
echo ""

# --- Auth socket group ---
echo -e "  ${BOLD}Auth socket group${NC}"
read -rp "  Enter auth socket group [postfix]: " AUTH_GROUP
AUTH_GROUP=${AUTH_GROUP:-postfix}
echo ""

# --- auth-userdb mode ---
echo -e "  ${BOLD}auth-userdb socket mode${NC}"
echo "  This is Dovecot's internal user lookup socket — not used by"
echo "  Postfix directly. mode = 0600 restricts access to Dovecot only."
read -rp "  Enter auth-userdb socket mode [0600]: " USERDB_MODE
USERDB_MODE=${USERDB_MODE:-0600}
echo ""

# --- auth-userdb user ---
echo -e "  ${BOLD}auth-userdb socket owner${NC}"
echo "  This socket is owned by the dovecot system user."
read -rp "  Enter auth-userdb socket user [dovecot]: " USERDB_USER
USERDB_USER=${USERDB_USER:-dovecot}
echo ""

# =============================================================================
# Step 4 — Build and show 10-master.conf, then confirm
# =============================================================================
echo -e "${CYAN}[4/6]${NC} Building 10-master.conf with your values..."
echo ""

MASTER_CONF=$(sed \
    -e "s/IMAP_PORT/$IMAP_PORT/g" \
    -e "s/LMTP_MODE/$LMTP_MODE/g" \
    -e "s/LMTP_USER/$LMTP_USER/g" \
    -e "s/LMTP_GROUP/$LMTP_GROUP/g" \
    -e "s/AUTH_MODE/$AUTH_MODE/g" \
    -e "s/AUTH_USER/$AUTH_USER/g" \
    -e "s/AUTH_GROUP/$AUTH_GROUP/g" \
    -e "s/USERDB_MODE/$USERDB_MODE/g" \
    -e "s/USERDB_USER/$USERDB_USER/g" \
    "$TMP/10-master.template")

echo -e "  ${BOLD}--- /etc/dovecot/conf.d/10-master.conf (will be appended) ---${NC}"
echo "$MASTER_CONF" | sed 's/^/  /'
echo ""

read -rp "  Do these values look correct? (yes/no): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
    echo ""
    echo -e "${YELLOW}[CANCELLED]${NC} No changes written. Re-run the script to try again."
    rm -rf "$TMP"
    exit 0
fi

echo ""

# Apply 10-master.conf — append our service blocks to the existing file
# (the existing file has many other service definitions we must not overwrite)
cp /etc/dovecot/conf.d/10-master.conf /etc/dovecot/conf.d/10-master.conf.backup
echo "" >> /etc/dovecot/conf.d/10-master.conf
echo "# --- Activity 3 additions below ---" >> /etc/dovecot/conf.d/10-master.conf
echo "$MASTER_CONF" >> /etc/dovecot/conf.d/10-master.conf

echo -e "  ${GREEN}[DONE]${NC} 10-master.conf updated (backup at 10-master.conf.backup)"
echo ""

# Clean up
rm -rf "$TMP"

# =============================================================================
# Step 5 — Create Maildir directories for users
# =============================================================================
echo -e "${CYAN}[5/6]${NC} Creating Maildir directories for user1 and user2..."
echo ""

for USERNAME in user1 user2; do
    if id "$USERNAME" &>/dev/null; then
        sudo -u "$USERNAME" mkdir -p /home/"$USERNAME"/Maildir/{new,cur,tmp} 2>/dev/null || true
        chown -R "$USERNAME":"$USERNAME" /home/"$USERNAME"/Maildir
        echo -e "  ${GREEN}[DONE]${NC} /home/$USERNAME/Maildir created"
    else
        echo -e "  ${YELLOW}[SKIP]${NC} User $USERNAME does not exist — create with sudo adduser $USERNAME first"
    fi
done

echo ""

# =============================================================================
# Step 6 — Restart services and verify
# =============================================================================
echo -e "${CYAN}[6/6]${NC} Restarting Dovecot and Postfix..."
echo ""

systemctl restart dovecot
systemctl restart postfix
systemctl enable dovecot

echo ""
echo -e "  ${BOLD}Service status:${NC}"
if systemctl is-active --quiet dovecot; then
    echo -e "  ${GREEN}[PASS]${NC} dovecot is active"
else
    echo -e "  ${RED}[FAIL]${NC} dovecot failed to start"
    echo "         Run: sudo journalctl -u dovecot --no-pager | tail -20"
fi

if systemctl is-active --quiet postfix; then
    echo -e "  ${GREEN}[PASS]${NC} postfix is active"
else
    echo -e "  ${RED}[FAIL]${NC} postfix failed to start"
fi

echo ""
echo -e "  ${BOLD}Port verification:${NC}"
for PORT in 25 143 110; do
    if ss -tuln 2>/dev/null | grep -q ":$PORT "; then
        echo -e "  ${GREEN}[PASS]${NC} Port $PORT is listening"
    else
        echo -e "  ${RED}[FAIL]${NC} Port $PORT not listening — check service status"
    fi
done

echo ""
echo -e "  ${BOLD}Socket verification:${NC}"
for SOCK in dovecot-lmtp auth; do
    if [ -e "/var/spool/postfix/private/$SOCK" ]; then
        echo -e "  ${GREEN}[PASS]${NC} Socket exists: /var/spool/postfix/private/$SOCK"
    else
        echo -e "  ${RED}[FAIL]${NC} Socket missing: /var/spool/postfix/private/$SOCK"
        echo "         → Re-check 10-master.conf service blocks and restart dovecot"
    fi
done

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Next step — test end-to-end delivery:${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo '  echo "Test email" | mail -s "Test" \'
echo '    -r server-user@yourdomain.com \'
echo '    desktop-user@yourdomain.com'
echo ""
echo "  Then check: ls -la /home/user1/Maildir/new/"
echo "  And:        sudo tail -f /var/log/mail.log"
echo ""
