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
#   --- IPv6 layer (added; mirrors the IPv4 checks) ---
#   E23 — IPv6 addressing wrong/missing on an interface
#   E24 — IPv6 routing (route-get) wrong/missing
#   E25 — IPv6 forwarding not enabled (gateways)
#   E26 — IPv6 nftables rule missing (e.g. v6 SMTP forward accept)
#   E27 — IPv6 connectivity (ping6 to a lab peer) failed
#   E28 — No IPv6 internet access
#   E29 — IPv6 mail service problem (inet_protocols not all/ipv6, or
#         Postfix/Dovecot not listening on IPv6, or SMTP/IMAP/POP3
#         unreachable over IPv6)
#   E30 — IPv6 DNS problem (no AAAA for mail.<domain>, or MX lost)
#   E31 — IPv6 tunnel services problem (wstunnel/WireGuard down or no
#         handshake on the Remote Gateway BinaryLane VM)
#
# Usage: sudo bash automark_activity3_ipv6.sh
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
    if has_ip "112.213.39.252"; then
        echo "remote_gateway"
    elif has_ip "192.168.1.254"; then
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

    # Method 1 — read from local BIND9 config (Internal Gateway). For the MAIL
    # activity, prefer the forward zone whose file actually carries an MX record
    # (the mail domain) — a split-horizon setup may master several zones and only
    # one holds the MX. Fall back to the first zone if none has an MX.
    if [ -f /etc/bind/named.conf.local ]; then
        local z zf cand=""
        for z in $(grep "^zone" /etc/bind/named.conf.local 2>/dev/null \
                    | grep -v 'arpa\|localhost\|hint\|"\."' \
                    | grep -oE '"[^"]+"' | tr -d '"'); do
            [ "$z" = "." ] && continue
            [ -z "$cand" ] && cand="$z"
            for zf in "/etc/bind/zones/db.$z" "/etc/bind/db.$z"; do
                if [ -f "$zf" ] && grep -qE '[[:space:]]MX[[:space:]]' "$zf"; then
                    echo "$z"; return
                fi
            done
        done
        if [ -n "$cand" ]; then echo "$cand"; return; fi
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

# ============================================================================
#  Activity-3-specific IPv6 helper (not in the shared block).
#  Raw TCP reachability over IPv6 — curl can't test SMTP/IMAP/POP3, so we use
#  bash's /dev/tcp against a literal v6 address. Bash accepts a bare IPv6
#  address (no brackets) in /dev/tcp/<addr>/<port>.
# ============================================================================
# check_tcp6 <v6addr> <port> <label> <code>
check_tcp6() {
    local host=$1 port=$2 label=$3 code=$4
    if timeout 3 bash -c "cat </dev/null >/dev/tcp/$host/$port" 2>/dev/null; then
        pass "$label reachable over IPv6 ([$host]:$port)"
    else
        fail "$code" "$label not reachable over IPv6 ([$host]:$port)"
    fi
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

    # =========================================================================
    # IPv6 layer (mirrors the IPv4 checks above) — Internal Gateway
    # =========================================================================
    section "IPv6 Addressing (Internal Gateway)"
    # eth0 = DMZ side, eth1 = internal side (mirrors 192.168.1.1 / 10.10.1.254)
    check_ip6 eth0 2404:9400:29c1:df10::1/64 E23
    check_ip6 eth1 2404:9400:29c1:df20::254/64 E23

    section "IPv6 Forwarding (Internal Gateway)"
    check_ip6_forward E25

    section "IPv6 Routing (Internal Gateway)"
    # Default route to the internet is via the External Gateway (DMZ side)
    check_route6_get 2001:4860:4860::8888 "via 2404:9400:29c1:df10::254" E24 "internet (via ExtGW)"

    section "IPv6 Connectivity (Internal Gateway)"
    check_ping6 2404:9400:29c1:df10::254 "External Gateway" E27
    check_ping6 2404:9400:29c1:df10::80  "Ubuntu Server"    E27
    check_ping6 2404:9400:29c1:df20::1   "Ubuntu Desktop"   E27

    section "IPv6 Internet (Internal Gateway)"
    check_internet6 E28

    # ---- Activity-3 IPv6 DNS: AAAA for mail.<domain> ----
    # ASSUMPTION: the student added an AAAA record for mail.<domain> pointing to
    # the server's IPv6 address 2404:9400:29c1:df10::80. If the zone is still
    # IPv4-only this will (correctly) fail until the AAAA record is added.
    if [ -n "$DOMAIN" ]; then
        section "IPv6 DNS — AAAA for mail.$DOMAIN"
        check_aaaa "mail.$DOMAIN" 127.0.0.1 E30
        # MX must still resolve (regression) — mail routing is unchanged by v6
        local mx6
        mx6=$(dig @127.0.0.1 "$DOMAIN" MX +short +time=5 +tries=1 2>/dev/null | head -1)
        if echo "$mx6" | grep -qE "^10 mail\.${DOMAIN}\.?$"; then
            pass "MX record still resolves: $mx6"
        else
            fail "E30" "MX record no longer resolves after IPv6 changes (got: ${mx6:-empty})"
        fi
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

    # =========================================================================
    # IPv6 layer (mirrors the IPv4 checks above) — Ubuntu Server
    # =========================================================================
    section "IPv6 Addressing (Ubuntu Server)"
    check_ip6 eth0 2404:9400:29c1:df10::80/64 E23

    section "IPv6 Routing (Ubuntu Server)"
    # Default gateway is the External Gateway (DMZ side)
    check_route6_get 2001:4860:4860::8888 "via 2404:9400:29c1:df10::254" E24 "internet (via ExtGW)"

    section "IPv6 Connectivity (Ubuntu Server)"
    check_ping6 2404:9400:29c1:df10::254 "External Gateway" E27
    check_ping6 2404:9400:29c1:df10::1   "Internal Gateway" E27

    section "IPv6 Internet (Ubuntu Server)"
    check_internet6 E28

    # ---- Activity-3 IPv6 mail service checks ----
    # Postfix must speak IPv6. The lab template ships inet_protocols = ipv4, so
    # this check (correctly) fails until the student sets it to 'all' or 'ipv6'.
    section "IPv6 Postfix — inet_protocols"
    local inet_p
    inet_p=$(postconf -h inet_protocols 2>/dev/null)
    if echo "$inet_p" | grep -qwE 'all|ipv6'; then
        pass "inet_protocols = $inet_p (IPv6 enabled)"
    else
        fail "E29" "inet_protocols is '$inet_p' — set to 'all' (or 'ipv6') in /etc/postfix/main.cf for IPv6"
        info "Edit /etc/postfix/main.cf: inet_protocols = all , then: sudo systemctl restart postfix"
    fi

    section "IPv6 Mail Listeners (Ubuntu Server)"
    # Postfix SMTP on [::]:25. ASSUMPTION: submission (587) is NOT configured in
    # this lab (main.cf template has no submission service), so only 25 is checked.
    check_listen6 25  "Postfix SMTP" E29
    # Dovecot IMAP/POP3. ASSUMPTION: ssl = no in this lab (10-ssl.conf), so the
    # implicit-TLS ports 993/995 are NOT expected — only 143 and 110 are checked.
    check_listen6 143 "Dovecot IMAP" E29
    check_listen6 110 "Dovecot POP3" E29

    section "IPv6 Mail Reachability (Ubuntu Server → self)"
    # SMTP/IMAP/POP3 over IPv6 to the server's own v6 address (curl can't do SMTP,
    # so use a raw /dev/tcp connect to the literal IPv6 address).
    check_tcp6 2404:9400:29c1:df10::80 25  "SMTP (25)"  E29
    check_tcp6 2404:9400:29c1:df10::80 143 "IMAP (143)" E29
    check_tcp6 2404:9400:29c1:df10::80 110 "POP3 (110)" E29
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

    # =========================================================================
    # IPv6 layer (mirrors the IPv4 checks above) — Ubuntu Desktop
    # =========================================================================
    section "IPv6 Addressing (Ubuntu Desktop)"
    check_ip6 eth0 2404:9400:29c1:df20::1/64 E23

    section "IPv6 Routing (Ubuntu Desktop)"
    # Default gateway is the Internal Gateway (internal side)
    check_route6_get 2001:4860:4860::8888 "via 2404:9400:29c1:df20::254" E24 "internet (via IntGW)"

    section "IPv6 Connectivity (Ubuntu Desktop)"
    check_ping6 2404:9400:29c1:df20::254 "Internal Gateway" E27
    check_ping6 2404:9400:29c1:df10::80  "Ubuntu Server"    E27

    section "IPv6 Internet (Ubuntu Desktop)"
    check_internet6 E28

    # ---- Activity-3 IPv6 DNS: AAAA / MX via the Internal Gateway resolver ----
    # ASSUMPTION: the Desktop resolves DNS via the Internal Gateway (10.10.1.254),
    # matching the IPv4 MX check above.
    if [ -n "$DOMAIN" ]; then
        section "IPv6 DNS via Internal Gateway (mail.$DOMAIN)"
        check_aaaa "mail.$DOMAIN" 10.10.1.254 E30
        local mx6d
        mx6d=$(dig @10.10.1.254 "$DOMAIN" MX +short +time=5 +tries=1 2>/dev/null | head -1)
        if echo "$mx6d" | grep -qE "^10 mail\.${DOMAIN}\.?$"; then
            pass "MX still resolves via 10.10.1.254: $mx6d"
        else
            fail "E30" "MX lookup via 10.10.1.254 failed (got: ${mx6d:-empty})"
        fi
    fi

    section "IPv6 Mail Reachability (Ubuntu Desktop → Server)"
    # curl can't test SMTP/IMAP/POP3 — use raw /dev/tcp to the server's v6 address.
    check_tcp6 2404:9400:29c1:df10::80 25  "SMTP (25)"  E29
    check_tcp6 2404:9400:29c1:df10::80 143 "IMAP (143)" E29
    check_tcp6 2404:9400:29c1:df10::80 110 "POP3 (110)" E29
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

    # =========================================================================
    # IPv6 layer (mirrors the IPv4 checks above) — External Gateway
    # =========================================================================
    section "IPv6 Addressing (External Gateway)"
    # wg0 = transit tunnel, eth1 = DMZ side (mirrors 192.168.1.254)
    check_ip6 wg0  2404:9400:29c1:df00::1/64   E23
    check_ip6 eth1 2404:9400:29c1:df10::254/64 E23

    section "IPv6 Forwarding (External Gateway)"
    check_ip6_forward E25

    section "IPv6 Routing (External Gateway)"
    # Default route to the internet leaves via the wireguard tunnel (table 51820)
    check_route6_get 2001:4860:4860::8888 "dev wg0" E24 "internet (dev wg0)"
    # Route to the internal network is via the Internal Gateway (DMZ side)
    check_route6_get 2404:9400:29c1:df20::1 "via 2404:9400:29c1:df10::1" E24 "internal net (via IntGW)"

    section "IPv6 Connectivity (External Gateway)"
    check_ping6 2404:9400:29c1:df10::1  "Internal Gateway" E27
    check_ping6 2404:9400:29c1:df10::80 "Ubuntu Server"    E27
    check_ping6 2404:9400:29c1:df20::1  "Ubuntu Desktop"   E27

    section "IPv6 Internet (External Gateway)"
    check_internet6 E28

    # ---- Tunnel services (present on the External Gateway in this lab topology) ----
    # ASSUMPTION: the External Gateway reaches the lab via a wstunnel + WireGuard
    # tunnel (as in the other activities). If this VM is a plain gateway without
    # the tunnel, ignore these three checks.
    section "IPv6 Tunnel Services (External Gateway)"
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        pass "wg-quick@wg0 is active"
    else
        fail "E27" "wg-quick@wg0 not active — IPv6 transit tunnel is down"
    fi
    if systemctl is-active --quiet wstunnel-client 2>/dev/null; then
        pass "wstunnel-client is active"
    else
        warn "wstunnel-client not active (ASSUMPTION: this service name may differ in your setup)"
    fi
    local hs
    hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -1)
    if [ -n "$hs" ] && [ "$hs" -gt 0 ] 2>/dev/null; then
        pass "WireGuard peer has a recent handshake (wg0)"
    else
        warn "No WireGuard handshake seen on wg0 (ASSUMPTION: tunnel may be idle or not present)"
    fi

    # ---- Activity-3 IPv6 nft: SMTP (port 25) forward accept to the DMZ ----
    # Mirrors the IPv4 rule 'iif "eth0" oif "eth1" tcp dport 25 ct state new accept'.
    # In this lab that rule lives in 'table inet filter', which already covers IPv6,
    # so a v6 SMTP forward accept is expected.
    # ASSUMPTION: IPv6 uses native routing (global addresses), so a plain forward
    # accept is expected rather than a v6 DNAT. The v6 ingress interface may be wg0
    # (tunnel) or eth0 (uplink), so both are accepted below.
    # This is only required if you accept EXTERNAL inbound mail over IPv6. This
    # lab's mail is internal (desktop/server users) with outbound relay, so there
    # is deliberately no inbound-SMTP forward rule — absence is a warn, not a fail.
    section "IPv6 nftables — SMTP forward accept (port 25) [optional]"
    if nft list ruleset 2>/dev/null | tr -s ' \t\n' ' ' \
        | grep -qE 'iif(name)? "(eth0|wg0)" oif(name)? "eth1" tcp dport 25 ct state new accept'; then
        pass "IPv6 forward accept for SMTP (port 25) to DMZ present"
    else
        warn "No IPv6 SMTP(25) forward-to-DMZ rule — expected only if you accept external inbound mail; this lab's mail is internal + outbound relay, so its absence is fine."
    fi
}

# =============================================================================
# Remote Gateway (BinaryLane VM) — IPv6 tunnel uplink
# =============================================================================
run_remote_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: Remote Gateway (BinaryLane VM — IPv6 uplink)${NC}"

    section "Network Interfaces"
    for _i in eth0 wg0; do
        if ip link show "$_i" &>/dev/null; then pass "Interface $_i exists"
        else fail "E23" "Interface $_i not found"; fi
    done

    section "IPv4 Addressing"
    if has_ip "112.213.39.252"; then pass "eth0 has public IPv4 (112.213.39.252)"
    else fail "E23" "public IPv4 112.213.39.252 not found"; fi

    section "IPv6 Addressing"
    check_ip6 "wg0" "2404:9400:29c1:df00::254/64" "E23"
    check_ip6_has_global "eth0" "E23"

    section "IPv6 Routing"
    check_route6_get "2404:9400:29c1:df10::80" "dev wg0"  "E24" "lab /56 (down the tunnel)"
    check_route6_get "2001:4860:4860::8888"    "dev eth0" "E24" "internet (own uplink)"

    section "IPv6 Forwarding"
    check_ip6_forward "E25"

    section "Tunnel Services"
    for _svc in wstunnel-server wg-quick@wg0; do
        if systemctl is-active --quiet "$_svc" 2>/dev/null; then pass "service $_svc is active"
        else fail "E31" "service $_svc is not active"; fi
    done
    _hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | sort -nr | head -1)
    if [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null; then
        pass "WireGuard handshake present ($(( $(date +%s) - _hs ))s ago)"
    else fail "E31" "no WireGuard handshake on wg0 — tunnel not established"; fi

    section "IPv6 Connectivity — Lab"
    check_ping6 "2404:9400:29c1:df00::1"  "External Gateway (wg0)" "E27"
    check_ping6 "2404:9400:29c1:df10::80" "Ubuntu Server"          "E27"
    check_ping6 "2404:9400:29c1:df20::1"  "Ubuntu Desktop"         "E27"

    section "IPv6 Internet Access"
    check_internet6 "E28"
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
    remote_gateway)   run_remote_gateway ;;
    internal_gateway) run_internal_gateway ;;
    ubuntu_server)    run_ubuntu_server ;;
    ubuntu_desktop)   run_ubuntu_desktop ;;
    external_gateway) run_external_gateway ;;
    *)
        echo ""
        echo -e "${RED}[ERROR]${NC} Could not detect which VM this is."
        echo ""
        echo "        Expected IP addresses:"
        echo "          Remote Gateway   — public IPv4 112.213.39.252"
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
