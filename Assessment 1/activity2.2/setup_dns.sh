#!/bin/bash
# =============================================================================
# Activity 2.2 - BIND9 DNS Setup Script
# 3821ICT | Griffith University
# =============================================================================
# Run this on the Internal Gateway after completing Activity 1.
# Usage: sudo bash setup_dns.sh
# =============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Please run with sudo: sudo bash setup_dns.sh"
    exit 1
fi

echo ""
echo -e "${BOLD}=== Activity 2.2 — BIND9 DNS Setup ===${NC}"
echo -e "${BOLD}3821ICT | Griffith University${NC}"
echo ""

echo -e "${CYAN}Enter your domain name (e.g. johnsmith3821ict.com):${NC}"
read -r DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}[ERROR]${NC} Domain name cannot be empty."
    exit 1
fi

echo ""
echo -e "  Domain set to: ${BOLD}$DOMAIN${NC}"
echo ""

echo -e "[1/6] Installing BIND9..."
apt-get update > /dev/null 2>&1
apt-get install -y bind9 bind9utils bind9-doc dnsutils > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "      ${GREEN}[DONE]${NC} BIND9 installed"
else
    echo -e "      ${RED}[FAIL]${NC} BIND9 installation failed — check internet connectivity"
    exit 1
fi

echo -e "[2/6] Configuring named.conf.options..."
cat > /etc/bind/named.conf.options << 'EOF'
options {
    directory "/var/cache/bind";

    forwarders {
        8.8.8.8;
        8.8.4.4;
    };

    forward only;

    dnssec-validation yes;

    listen-on { 127.0.0.1; 192.168.1.1; 10.10.1.254; };
    listen-on-v6 { none; };
};
EOF
echo -e "      ${GREEN}[DONE]${NC} named.conf.options configured"

mkdir -p /etc/bind/zones

echo -e "[3/6] Creating zone definitions..."
cat > /etc/bind/named.conf.local << EOF
zone "$DOMAIN" {
    type master;
    file "/etc/bind/zones/db.$DOMAIN";
};

zone "1.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.192.168.1";
};
EOF
echo -e "      ${GREEN}[DONE]${NC} Zone definitions created"

echo -e "[4/6] Creating forward zone file..."
cat > /etc/bind/zones/db.$DOMAIN << EOF
;
; BIND forward zone file for $DOMAIN
;
\$TTL 604800
@ IN SOA ns1.$DOMAIN. admin.$DOMAIN. (
                  3         ; Serial
             604800         ; Refresh
              86400         ; Retry
            2419200         ; Expire
             604800 )       ; Negative Cache TTL
;
@     IN  NS   ns1.$DOMAIN.

ns1   IN  A    192.168.1.1
@     IN  A    192.168.1.80
www   IN  A    192.168.1.80
mail  IN  A    192.168.1.80
EOF
echo -e "      ${GREEN}[DONE]${NC} Forward zone file created: /etc/bind/db.$DOMAIN"

echo -e "[5/6] Creating reverse zone file..."
cat > /etc/bind/zones/db.192.168.1 << EOF
;
; BIND reverse zone file for 192.168.1.0/24
;
\$TTL 604800
@ IN SOA ns1.$DOMAIN. admin.$DOMAIN. (
                  3         ; Serial
             604800         ; Refresh
              86400         ; Retry
            2419200         ; Expire
             604800 )       ; Negative Cache TTL
;
@ IN NS ns1.$DOMAIN.

1   IN PTR ns1.$DOMAIN.
80  IN PTR www.$DOMAIN.
254 IN PTR gateway.$DOMAIN.
EOF
echo -e "      ${GREEN}[DONE]${NC} Reverse zone file created"

echo -e "[6/6] Validating and restarting BIND9..."

named-checkconf 2>/tmp/bind_err
if [ $? -ne 0 ]; then
    echo -e "      ${RED}[FAIL]${NC} named.conf error:"; cat /tmp/bind_err; exit 1
fi

named-checkzone "$DOMAIN" "/etc/bind/zones/db.$DOMAIN" > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "      ${RED}[FAIL]${NC} Forward zone file has errors:"
    named-checkzone "$DOMAIN" "/etc/bind/zones/db.$DOMAIN"; exit 1
fi

named-checkzone "1.168.192.in-addr.arpa" /etc/bind/zones/db.192.168.1 > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "      ${RED}[FAIL]${NC} Reverse zone file has errors:"
    named-checkzone "1.168.192.in-addr.arpa" /etc/bind/zones/db.192.168.1; exit 1
fi

systemctl enable named > /dev/null 2>&1
systemctl restart named 2>/dev/null || systemctl restart bind9 2>/dev/null
sleep 2

if systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null; then
    echo -e "      ${GREEN}[DONE]${NC} BIND9 running successfully"
else
    echo -e "      ${RED}[FAIL]${NC} BIND9 failed to start — run: journalctl -u named --no-pager"
    exit 1
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} DNS Setup Complete${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Domain    : ${GREEN}$DOMAIN${NC}"
echo -e "  DNS Server: ${GREEN}127.0.0.1 / 192.168.1.1 / 10.10.1.254${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Set DNS to 192.168.1.1 on Ubuntu Server (netplan)"
echo "  2. Set DNS to 10.10.1.254 on Ubuntu Desktop (network settings)"
echo "  3. Test from Internal Gateway: dig @127.0.0.1 www.$DOMAIN"
echo "  4. Open http://www.$DOMAIN and https://www.$DOMAIN in Firefox on Desktop"
echo ""
