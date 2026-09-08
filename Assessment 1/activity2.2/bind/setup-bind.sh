#!/bin/bash
# Activity 2 - BIND9 Setup Script (Internal Gateway)
# Downloads config files from GitHub, places them correctly,
# and prints the remaining manual steps required for marking.
#
# For upgraded Activity 2.1 / Activity 2 Part B:
# - Installs BIND9 + dig/nslookup tools
# - Downloads named configs and zone templates from GitHub
# - Adds TCP-only upstream server blocks once only
# - Enables and starts named
# - Prints exact follow-up steps for domain replacement, validation, and DNSSEC testing

set -euo pipefail

# Fetch the as-built zone/config files from this repo. Assumes the
# "Assessment 1" tree has been merged to main; change the branch segment if
# you are pulling from a feature branch. LAB_DOMAIN drives the follow-up hints.
LAB_DOMAIN="3014ict.chris.grul.me"
REPO="https://raw.githubusercontent.com/chris-grul/3014ICT/main/Assessment%201/activity2.2/bind"

echo "============================================================"
echo " Activity 2 - BIND9 Setup (Internal Gateway)"
echo "============================================================"
echo ""

echo "[1/8] Checking internet access..."
if ! curl -I -s --max-time 10 https://google.com >/dev/null; then
  echo "ERROR: No internet connectivity detected."
  echo "Fix routing/NAT first, then re-run this script."
  exit 1
fi

echo "[2/8] Installing BIND9 and DNS tools..."
sudo apt update -q
sudo DEBIAN_FRONTEND=noninteractive apt install -y -q \
  bind9 bind9utils bind9-doc dnsutils curl

echo "[3/8] Creating temporary download workspace..."
TMPDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "[4/8] Downloading required files from GitHub..."
FILES=(
  "named.conf.options"
  "named.conf.local"
  "db.3014ict.chris.grul.me"
  "db.192.168.1"
  "db.df10.ip6"
  "named.conf.append"
)

for f in "${FILES[@]}"; do
  echo "  - Fetching $f"
  curl -fsSL "$REPO/$f" -o "$TMPDIR/$f"
done

echo "[5/8] Installing configuration files..."
sudo mkdir -p /etc/bind/zones

sudo install -m 644 "$TMPDIR/named.conf.options"          /etc/bind/named.conf.options
sudo install -m 644 "$TMPDIR/named.conf.local"           /etc/bind/named.conf.local
sudo install -m 644 "$TMPDIR/db.3014ict.chris.grul.me"   /etc/bind/zones/db.3014ict.chris.grul.me
sudo install -m 644 "$TMPDIR/db.192.168.1"               /etc/bind/zones/db.192.168.1
sudo install -m 644 "$TMPDIR/db.df10.ip6"                /etc/bind/zones/db.df10.ip6

echo "[6/8] Adding TCP-only upstream blocks if not already present..."
if grep -q 'tcp-only yes' /etc/bind/named.conf 2>/dev/null; then
  echo "  TCP-only upstream block already present. Skipping append."
else
  sudo tee -a /etc/bind/named.conf > /dev/null < "$TMPDIR/named.conf.append"
  echo "  TCP-only upstream block appended to /etc/bind/named.conf"
fi

echo "[7/8] Enabling and starting named..."
sudo systemctl enable named >/dev/null
sudo systemctl start named

echo "[8/8] Showing current service state..."
sudo systemctl --no-pager --full status named | sed -n '1,12p' || true

echo ""
echo "============================================================"
echo " Download complete. The zone files are already populated for"
echo " ${LAB_DOMAIN} (no YOURDOMAIN replacement needed). Now validate:"
echo "============================================================"
echo ""
echo " STEP 1 — Validate the BIND configuration and all zones:"
echo "   sudo named-checkconf"
echo "   sudo named-checkzone ${LAB_DOMAIN} \\"
echo "        /etc/bind/zones/db.3014ict.chris.grul.me"
echo "   sudo named-checkzone 1.168.192.in-addr.arpa \\"
echo "        /etc/bind/zones/db.192.168.1"
echo "   sudo named-checkzone 0.1.f.d.1.c.9.2.0.0.4.9.4.0.4.2.ip6.arpa \\"
echo "        /etc/bind/zones/db.df10.ip6"
echo ""
echo " STEP 2 — Restart named:"
echo "   sudo systemctl restart named"
echo ""
echo " STEP 3 — Confirm BIND is listening on port 53 (v4 + v6):"
echo "   sudo ss -tuln | grep ':53'"
echo ""
echo " STEP 4 — Test local zone resolution (A + AAAA + PTR):"
echo "   dig +short @127.0.0.1 www.${LAB_DOMAIN}"
echo "   dig +short @127.0.0.1 AAAA www.${LAB_DOMAIN}"
echo "   dig +short @127.0.0.1 ${LAB_DOMAIN} MX"
echo "   dig +short @127.0.0.1 -x 192.168.1.80"
echo "   dig +short @127.0.0.1 -x 2404:9400:29c1:df10::80"
echo ""
echo " STEP 5 — Test DNSSEC validation:"
echo "   dig @127.0.0.1 google.com +dnssec"
echo "   # Look for: flags: qr rd ra ad"
echo ""
echo " STEP 6 — Test DNSSEC failure enforcement:"
echo "   dig @127.0.0.1 dnssec-failed.org"
echo "   # Expected: status: SERVFAIL"
echo ""
echo " STEP 7 — Confirm client DNS on the VMs (as required by the activity):"
echo "   - Internal Gateway (igw)  -> 127.0.0.1"
echo "   - Ubuntu Desktop  (dkt)   -> 10.10.1.254   (igw internal leg)"
echo "   - Ubuntu Server / ExtGW stay on 8.8.8.8 in this lab"
echo ""
echo "============================================================"
echo " Done: BIND9 bootstrap complete for ${LAB_DOMAIN}."
echo "============================================================"
