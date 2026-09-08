#!/bin/bash
# =============================================================================
# Automarking Script - Activity 3: Email Server (Postfix + Dovecot + Thunderbird)
# 7015ICT | Griffith University
# =============================================================================
# Run on Internal Gateway, Ubuntu Server, Ubuntu Desktop, or External Gateway.
# The script auto-detects which VM it is running on.
#
# Error code reference (see Activity 3 guide Troubleshooting section):
#   E14 — MX record missing or incorrect
#   E15 — Postfix not starting or misconfigured
#   E16 — Mail not being delivered to mailbox
#   E17 — Dovecot not starting or crashing
#   E18 — LMTP or auth socket missing
#   E19 — Thunderbird cannot connect to server (port not listening)
#   E20 — Virtual alias not working
#   E21 — auth_username_format missing — LMTP rejects with "User doesn't exist"
#   E22 — smtpd_relay_restrictions missing — smtpd crashes on startup
#   E4  — nftables port 25 rules missing on External Gateway
#
# Usage: sudo bash automark_activity3.sh
# =============================================================================

if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "  [ERROR] Please run with sudo: sudo bash automark_activity3.sh"
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
# Detect student domain (used by every VM that runs DNS lookups)
# =============================================================================
detect_domain() {
    local zone

    # Method 1 — read from local BIND9 config (Internal Gateway)
    if [ -f /etc/bind/named.conf.local ]; then
        zone=$(grep "^zone" /etc/bind/named.conf.local 2>/dev/null \
            | grep -v 'arpa\|localhost\|hint\|"\."' \
            | grep '"' | head -1 \
            | sed 's/.*"\(.*\)".*/\1/')
        if [ -n "$zone" ] && [ "$zone" != "." ]; then
            echo "$zone"
            return
        fi
    fi

    # Method 2 — read from Postfix mydomain (Ubuntu Server)
    if command -v postconf >/dev/null 2>&1; then
        zone=$(postconf -h mydomain 2>/dev/null)
        if [ -n "$zone" ] && [ "$zone" != "localdomain" ]; then
            echo "$zone"
            return
        fi
    fi

    # Method 3 — reverse lookup via Internal Gateway
    local ptr
    ptr=$(dig @10.10.1.254 -x 192.168.1.80 +short +time=3 +tries=1 2>/dev/null | head -1)
    if [ -n "$ptr" ]; then
        zone=$(echo "$ptr" | sed 's/^www\.//;s/^mail\.//;s/\.$//')
        echo "$zone"
        return
    fi

    echo ""
}

# =============================================================================
# Internal Gateway — Part A: MX record check
# =============================================================================
run_internal_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: Internal Gateway${NC}"

    section "BIND9 Service"
    if systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null; then
        pass "BIND9 is running"
    else
        fail "E14" "BIND9 not running — run: sudo systemctl restart named"
        return
    fi

    local DOMAIN
    DOMAIN=$(detect_domain)
    if [ -z "$DOMAIN" ]; then
        fail "E14" "Could not detect student domain from /etc/bind/named.conf.local"
        return
    fi
    info "Domain detected: $DOMAIN"

    section "Zone File MX Record"
    local zone_file
    for f in "/etc/bind/zones/db.$DOMAIN" "/etc/bind/db.$DOMAIN"; do
        if [ -f "$f" ]; then
            zone_file="$f"
            break
        fi
    done

    if [ -z "$zone_file" ]; then
        fail "E14" "Zone file not found for $DOMAIN — check /etc/bind/named.conf.local file path"
        return
    fi
    info "Zone file: $zone_file"

    if grep -E "^@\s+IN\s+MX\s+[0-9]+\s+mail\.${DOMAIN}\." "$zone_file" >/dev/null 2>&1; then
        pass "MX record present in zone file (with trailing dot)"
    elif grep -E "^@.*MX.*mail" "$zone_file" >/dev/null 2>&1; then
        fail "E14" "MX record found but missing trailing dot or wrong target"
        info "Expected: @  IN  MX  10  mail.${DOMAIN}."
    else
        fail "E14" "No MX record found in $zone_file"
        info "Add: @  IN  MX  10  mail.${DOMAIN}."
    fi

    section "Zone Validation"
    local check_out
    check_out=$(named-checkzone "$DOMAIN" "$zone_file" 2>&1)
    if echo "$check_out" | grep -q "^OK"; then
        pass "named-checkzone returns OK"
    else
        fail "E14" "Zone file has errors:"
        echo "$check_out" | sed 's/^/         /'
    fi

    section "MX Lookup"
    local mx_result
    mx_result=$(dig @127.0.0.1 "$DOMAIN" MX +short +time=5 +tries=1 2>/dev/null | head -1)
    if echo "$mx_result" | grep -qE "^10 mail\.${DOMAIN}\.?$"; then
        pass "dig MX returns: $mx_result"
    elif [ -n "$mx_result" ]; then
        fail "E14" "MX record exists but wrong format: $mx_result"
        info "Expected: 10 mail.${DOMAIN}."
    else
        fail "E14" "dig @127.0.0.1 $DOMAIN MX returned no answer"
        info "Check serial number was incremented and zone reloaded"
    fi

    section "A Record for mail."
    local mail_a
    mail_a=$(dig @127.0.0.1 "mail.$DOMAIN" +short +time=5 +tries=1 2>/dev/null | head -1)
    if [ "$mail_a" = "192.168.1.80" ]; then
        pass "mail.$DOMAIN → 192.168.1.80"
    else
        fail "E14" "mail.$DOMAIN did not resolve to 192.168.1.80 (got: ${mail_a:-no response})"
    fi
}

# =============================================================================
# Ubuntu Server — Parts B & C: Postfix + Dovecot
# =============================================================================
run_ubuntu_server() {
    echo -e "\n${BOLD}${CYAN}VM detected: Ubuntu Server${NC}"

    local DOMAIN
    DOMAIN=$(detect_domain)
    if [ -n "$DOMAIN" ]; then
        info "Domain detected: $DOMAIN"
    else
        warn "Could not detect domain — some checks will be skipped"
    fi

    # ==== Part B: Postfix ====
    section "Postfix Service"
    if systemctl is-active --quiet postfix 2>/dev/null; then
        pass "Postfix is active"
    else
        fail "E15" "Postfix not running — check: sudo systemctl status postfix"
        info "Common cause: smtpd_relay_restrictions missing in main.cf (E22)"
    fi

    section "Postfix Configuration"
    local mh md mo dest mynet inet hmb mt va
    mh=$(postconf -h myhostname 2>/dev/null)
    md=$(postconf -h mydomain 2>/dev/null)
    mo=$(postconf -h myorigin 2>/dev/null)
    dest=$(postconf -h mydestination 2>/dev/null)
    mynet=$(postconf -h mynetworks 2>/dev/null)
    inet=$(postconf -h inet_interfaces 2>/dev/null)
    hmb=$(postconf -h home_mailbox 2>/dev/null)
    mt=$(postconf -h mailbox_transport 2>/dev/null)
    va=$(postconf -h virtual_alias_maps 2>/dev/null)

    [ "$mh" = "mail.$DOMAIN" ] && pass "myhostname = $mh" || fail "E15" "myhostname is '$mh' (expected mail.$DOMAIN)"
    [ "$md" = "$DOMAIN" ]      && pass "mydomain = $md"   || fail "E15" "mydomain is '$md' (expected $DOMAIN)"

    if echo "$dest" | grep -qw "$DOMAIN"; then
        pass "mydestination includes $DOMAIN"
    else
        fail "E15" "mydestination does not include $DOMAIN (got: $dest)"
    fi

    if [ "$inet" = "all" ]; then
        pass "inet_interfaces = all"
    else
        fail "E15" "inet_interfaces is '$inet' (expected: all)"
    fi

    if [ "$hmb" = "Maildir/" ]; then
        pass "home_mailbox = Maildir/"
    else
        fail "E15" "home_mailbox is '$hmb' (expected: Maildir/)"
    fi

    if echo "$mt" | grep -q "lmtp:unix:private/dovecot-lmtp"; then
        pass "mailbox_transport routes through Dovecot LMTP"
    else
        fail "E15" "mailbox_transport not pointing to Dovecot LMTP (got: $mt)"
    fi

    if echo "$va" | grep -q "/etc/postfix/virtual"; then
        pass "virtual_alias_maps configured"
    else
        fail "E20" "virtual_alias_maps not set (got: $va)"
    fi

    # smtpd_relay_restrictions check — added because of the smtpd crash bug
    section "Postfix Relay Restrictions"
    local relay_r
    relay_r=$(postconf -h smtpd_relay_restrictions 2>/dev/null)
    if echo "$relay_r" | grep -qE 'permit_mynetworks|reject_unauth_destination'; then
        pass "smtpd_relay_restrictions configured"
    else
        fail "E22" "smtpd_relay_restrictions missing or invalid — smtpd will crash on startup"
        info "Add: smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination"
    fi

    section "SMTP Port"
    if ss -tuln 2>/dev/null | grep -qE '0\.0\.0\.0:25 |\*:25 '; then
        pass "Port 25 listening on all interfaces"
    elif ss -tuln 2>/dev/null | grep -q ":25 "; then
        fail "E15" "Port 25 listening but only on loopback — check inet_interfaces"
    else
        fail "E19" "Port 25 not listening — Postfix smtpd may have crashed"
        info "Check: sudo journalctl -u postfix --no-pager | tail -20"
    fi

    section "Virtual Alias Lookup"
    if [ -f /etc/postfix/virtual.db ]; then
        pass "/etc/postfix/virtual.db compiled"
    else
        fail "E20" "/etc/postfix/virtual.db missing — run: sudo postmap /etc/postfix/virtual"
    fi

    if [ -n "$DOMAIN" ]; then
        local r1 r2
        r1=$(postmap -q "desktop-user@${DOMAIN}" hash:/etc/postfix/virtual 2>/dev/null)
        r2=$(postmap -q "server-user@${DOMAIN}" hash:/etc/postfix/virtual 2>/dev/null)

        [ "$r1" = "user1" ] && pass "desktop-user@${DOMAIN} → user1" \
            || fail "E20" "desktop-user@${DOMAIN} did not resolve to user1 (got: ${r1:-empty})"
        [ "$r2" = "user2" ] && pass "server-user@${DOMAIN} → user2" \
            || fail "E20" "server-user@${DOMAIN} did not resolve to user2 (got: ${r2:-empty})"
    fi

    section "System Users"
    for u in user1 user2; do
        if id "$u" &>/dev/null; then
            pass "User $u exists"
        else
            fail "E16" "User $u does not exist — run: sudo adduser $u"
        fi
    done

    # ==== Part C: Dovecot ====
    section "Dovecot Service"
    if systemctl is-active --quiet dovecot 2>/dev/null; then
        pass "Dovecot is active"
    else
        fail "E17" "Dovecot not running — check: sudo journalctl -u dovecot --no-pager | tail -20"
        return
    fi

    section "Dovecot Ports"
    if ss -tuln 2>/dev/null | grep -q ":143 "; then
        pass "IMAP listening on port 143"
    else
        fail "E19" "Port 143 (IMAP) not listening"
    fi

    if ss -tuln 2>/dev/null | grep -q ":110 "; then
        pass "POP3 listening on port 110"
    else
        fail "E19" "Port 110 (POP3) not listening"
    fi

    section "Dovecot Active Configuration"
    local protocols mail_loc plaintext ssl_set
    protocols=$(doveconf -h protocols 2>/dev/null)
    mail_loc=$(doveconf -h mail_location 2>/dev/null)
    plaintext=$(doveconf -h disable_plaintext_auth 2>/dev/null)
    ssl_set=$(doveconf -h ssl 2>/dev/null)

    if echo "$protocols" | grep -q "imap" && echo "$protocols" | grep -q "lmtp"; then
        pass "protocols = $protocols"
    else
        fail "E17" "protocols missing imap or lmtp (got: $protocols)"
    fi

    if [ "$mail_loc" = "maildir:~/Maildir" ]; then
        pass "mail_location = $mail_loc"
    else
        fail "E16" "mail_location is '$mail_loc' (expected: maildir:~/Maildir)"
    fi

    if [ "$plaintext" = "no" ]; then
        pass "disable_plaintext_auth = no"
    else
        warn "disable_plaintext_auth = $plaintext (expected: no for lab)"
    fi

    if [ "$ssl_set" = "no" ]; then
        pass "ssl = no (lab environment)"
    else
        warn "ssl = $ssl_set (expected: no for lab)"
    fi

    # auth_username_format check — the bug we hit during testing
    section "LMTP auth_username_format"
    local auf
    auf=$(doveconf 2>/dev/null | awk '/^protocol lmtp \{/,/^\}/' | grep auth_username_format | awk -F= '{print $2}' | tr -d ' ')
    if [ "$auf" = "%n" ]; then
        pass "auth_username_format = %n (inside protocol lmtp block)"
    else
        fail "E21" "auth_username_format not set to %n in protocol lmtp block"
        info "Edit /etc/dovecot/conf.d/20-lmtp.conf — add inside the protocol lmtp { } block:"
        info "  auth_username_format = %n"
    fi

    section "Postfix-Dovecot Sockets"
    if [ -S /var/spool/postfix/private/dovecot-lmtp ]; then
        pass "LMTP socket exists: /var/spool/postfix/private/dovecot-lmtp"
    else
        fail "E18" "LMTP socket missing — check 10-master.conf service lmtp block"
    fi

    if [ -S /var/spool/postfix/private/auth ]; then
        pass "Auth socket exists: /var/spool/postfix/private/auth"
    else
        fail "E18" "Auth socket missing — check 10-master.conf service auth block"
    fi

    section "Maildir Directories"
    for u in user1 user2; do
        if [ -d "/home/$u/Maildir/new" ] && [ -d "/home/$u/Maildir/cur" ] && [ -d "/home/$u/Maildir/tmp" ]; then
            pass "/home/$u/Maildir structure exists"
        else
            fail "E16" "/home/$u/Maildir incomplete — re-run setup-dovecot.sh"
        fi
    done

    # ==== End-to-end live delivery test ====
    if [ -n "$DOMAIN" ] && id user1 &>/dev/null; then
        section "Live End-to-End Delivery Test"
        info "Sending test email server-user → desktop-user..."

        local mailcount_before mailcount_after
        mailcount_before=$(find /home/user1/Maildir/{new,cur} -type f 2>/dev/null | wc -l)

        echo "Automark test $(date +%s)" | mail -s "Automark Test" \
            -r "server-user@${DOMAIN}" \
            "desktop-user@${DOMAIN}" 2>/dev/null

        # Wait up to 5 seconds for delivery
        local i=0
        while [ $i -lt 5 ]; do
            sleep 1
            mailcount_after=$(find /home/user1/Maildir/{new,cur} -type f 2>/dev/null | wc -l)
            if [ "$mailcount_after" -gt "$mailcount_before" ]; then
                break
            fi
            i=$((i+1))
        done

        if [ "$mailcount_after" -gt "$mailcount_before" ]; then
            pass "Test email delivered to user1 Maildir"
        else
            fail "E16" "Test email did not arrive in user1 Maildir within 5 seconds"
            info "Check: sudo journalctl -u postfix -u dovecot --no-pager | tail -20"
        fi
    fi
}

# =============================================================================
# Ubuntu Desktop — Part D: Thunderbird connectivity
# =============================================================================
run_ubuntu_desktop() {
    echo -e "\n${BOLD}${CYAN}VM detected: Ubuntu Desktop${NC}"

    local DOMAIN
    DOMAIN=$(detect_domain)
    if [ -n "$DOMAIN" ]; then
        info "Domain detected: $DOMAIN"
    fi

    section "MX Lookup via Internal Gateway"
    if [ -n "$DOMAIN" ]; then
        local mx_result
        mx_result=$(dig @10.10.1.254 "$DOMAIN" MX +short +time=5 +tries=1 2>/dev/null | head -1)
        if echo "$mx_result" | grep -qE "^10 mail\.${DOMAIN}\.?$"; then
            pass "MX lookup via 10.10.1.254: $mx_result"
        else
            fail "E14" "MX lookup via 10.10.1.254 failed (got: ${mx_result:-empty})"
        fi
    else
        warn "Domain not detected — skipping MX check"
    fi

    section "Thunderbird Installed"
    if command -v thunderbird >/dev/null 2>&1; then
        pass "Thunderbird is installed"
    else
        fail "E19" "Thunderbird not installed — run: sudo apt install thunderbird -y"
    fi

    section "SMTP Connectivity to Mail Server"
    if (echo > /dev/tcp/192.168.1.80/25) 2>/dev/null; then
        pass "TCP 192.168.1.80:25 (SMTP) reachable"
    else
        fail "E19" "Cannot reach 192.168.1.80:25 — check Postfix on Ubuntu Server"
    fi

    section "IMAP Connectivity to Mail Server"
    if (echo > /dev/tcp/192.168.1.80/143) 2>/dev/null; then
        pass "TCP 192.168.1.80:143 (IMAP) reachable"
    else
        fail "E19" "Cannot reach 192.168.1.80:143 — check Dovecot on Ubuntu Server"
    fi

    section "POP3 Connectivity to Mail Server"
    if (echo > /dev/tcp/192.168.1.80/110) 2>/dev/null; then
        pass "TCP 192.168.1.80:110 (POP3) reachable"
    else
        fail "E19" "Cannot reach 192.168.1.80:110 — check Dovecot on Ubuntu Server"
    fi

    section "Thunderbird Profiles"
    local profile_dir="/home/user/.thunderbird"
    if [ -d "$profile_dir" ]; then
        local account_count
        account_count=$(find "$profile_dir" -name 'prefs.js' -exec grep -hc 'mail.account.account' {} \; 2>/dev/null | sort -nr | head -1)
        account_count=${account_count:-0}
        if [ "$account_count" -ge 4 ]; then
            pass "Thunderbird has multiple mail accounts configured"
        elif [ "$account_count" -ge 2 ]; then
            warn "Thunderbird has at least one account — challenging question requires two"
        else
            warn "Thunderbird profile exists but no mail accounts detected"
            info "Configure desktop-user and server-user accounts manually"
        fi
    else
        warn "Thunderbird profile not found (~/.thunderbird) — launch Thunderbird and add accounts"
    fi
}

# =============================================================================
# External Gateway — Part E: nftables port 25
# =============================================================================
run_external_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: External Gateway${NC}"

    section "nftables Service"
    if systemctl is-active --quiet nftables 2>/dev/null; then
        pass "nftables service is active"
    else
        warn "nftables service not active — rules may still be loaded"
    fi

    section "Port 25 Forward Rule"
    local ruleset
    ruleset=$(nft list ruleset 2>/dev/null)

    if echo "$ruleset" | grep -A20 'chain forward' | grep -E 'tcp dport 25|tcp dport \{ [^}]*25' >/dev/null; then
        pass "Port 25 forward rule found in forward chain"
    else
        fail "E4" "Port 25 forward rule missing — add to forward chain:"
        info '  iif "eth0" oif "eth1" tcp dport 25 ct state new accept'
    fi

    section "Port 25 DNAT Rule"
    if echo "$ruleset" | grep -A20 'chain prerouting' | grep -E 'tcp dport 25.*dnat to 192\.168\.1\.80' >/dev/null; then
        pass "Port 25 DNAT rule forwards to 192.168.1.80"
    else
        fail "E4" "Port 25 DNAT rule missing in prerouting chain"
        info '  iif "eth0" tcp dport 25 dnat to 192.168.1.80:25'
    fi

    section "Existing Port Forwarding (regression check)"
    if echo "$ruleset" | grep -E 'tcp dport (80|\{ 80, 443)' >/dev/null; then
        pass "HTTP/HTTPS forward rules still present"
    else
        warn "HTTP/HTTPS forward rules missing — Activity 2 rules may have been overwritten"
    fi

    if echo "$ruleset" | grep -E 'dnat to 192\.168\.1\.80:80' >/dev/null; then
        pass "HTTP DNAT still present"
    else
        warn "HTTP DNAT rule missing — Activity 2 may need re-applying"
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
        echo -e "  ${YELLOW}Refer to the Troubleshooting section of the Activity 3 guide.${NC}"
        echo ""
    else
        echo ""
        echo -e "  ${GREEN}${BOLD}All checks passed! Activity 3 configuration looks correct.${NC}"
        echo ""
    fi
}

# =============================================================================
# Main
# =============================================================================
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Activity 3 Automarker — Email Server${NC}"
echo -e "${BOLD} 7015ICT | Griffith University${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

VM=$(detect_vm)

case "$VM" in
    internal_gateway) run_internal_gateway ;;
    ubuntu_server)    run_ubuntu_server ;;
    ubuntu_desktop)   run_ubuntu_desktop ;;
    external_gateway) run_external_gateway ;;
    *)
        echo ""
        echo -e "${RED}[ERROR]${NC} Could not detect which VM this is."
        echo ""
        echo "        Expected IP addresses:"
        echo "          External Gateway — eth1 at 192.168.1.254"
        echo "          Internal Gateway — eth0 at 192.168.1.1 AND eth1 at 10.10.1.254"
        echo "          Ubuntu Server    — eth0 at 192.168.1.80"
        echo "          Ubuntu Desktop   — eth0 at 10.10.1.1"
        echo ""
        echo "        Your current addresses:"
        ip -brief addr show 2>/dev/null | sed 's/^/          /'
        exit 1
        ;;
esac

print_summary
