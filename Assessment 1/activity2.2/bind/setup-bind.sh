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

REPO="https://raw.githubusercontent.com/7015ICT/SOC-Activities-Project-Griffith/main/activity2.2/bind"

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
  "db.YOURDOMAIN.com"
  "db.192.168.1"
  "named.conf.append"
)

for f in "${FILES[@]}"; do
  echo "  - Fetching $f"
  curl -fsSL "$REPO/$f" -o "$TMPDIR/$f"
done

echo "[5/8] Installing configuration files..."
sudo mkdir -p /etc/bind/zones

sudo install -m 644 "$TMPDIR/named.conf.options" /etc/bind/named.conf.options
sudo install -m 644 "$TMPDIR/named.conf.local"   /etc/bind/named.conf.local
sudo install -m 644 "$TMPDIR/db.YOURDOMAIN.com"  /etc/bind/zones/db.YOURDOMAIN.com
sudo install -m 644 "$TMPDIR/db.192.168.1"       /etc/bind/zones/db.192.168.1

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
echo " Download complete. Now finish the required manual steps:"
echo "============================================================"
echo ""
echo " STEP 1 — Edit named.conf.local and replace BOTH instances of YOURDOMAIN:"
echo "   sudo nano /etc/bind/named.conf.local"
echo ""
echo " STEP 2 — Rename the forward zone file to your actual domain:"
echo "   sudo mv /etc/bind/zones/db.YOURDOMAIN.com \\"
echo "           /etc/bind/zones/db.yourname-coursecode.com"
echo ""
echo " STEP 3 — Edit the forward zone file and replace every YOURDOMAIN:"
echo "   sudo nano /etc/bind/zones/db.yourname-coursecode.com"
echo ""
echo " STEP 4 — Edit the reverse zone file and replace every YOURDOMAIN:"
echo "   sudo nano /etc/bind/zones/db.192.168.1"
echo ""
echo " STEP 5 — Validate the BIND configuration and both zones:"
echo "   sudo named-checkconf"
echo "   sudo named-checkzone yourname-coursecode.com \\"
echo "        /etc/bind/zones/db.yourname-coursecode.com"
echo "   sudo named-checkzone 1.168.192.in-addr.arpa \\"
echo "        /etc/bind/zones/db.192.168.1"
echo ""
echo " STEP 6 — Restart named after your edits:"
echo "   sudo systemctl restart named"
echo ""
echo " STEP 7 — Confirm BIND is listening on port 53:"
echo "   sudo ss -tuln | grep 53"
echo ""
echo " STEP 8 — Test local zone resolution:"
echo "   dig @127.0.0.1 www.yourname-coursecode.com"
echo "   dig @127.0.0.1 mail.yourname-coursecode.com"
echo "   dig @127.0.0.1 -x 192.168.1.80"
echo ""
echo " STEP 9 — Test DNSSEC validation:"
echo "   dig @127.0.0.1 google.com +dnssec"
echo "   # Look for: flags: qr rd ra ad"
echo ""
echo " STEP 10 — Test DNSSEC failure enforcement:"
echo "   dig @127.0.0.1 dnssec-failed.org"
echo "   # Expected: status: SERVFAIL"
echo ""
echo " STEP 11 — Then finish the client DNS config on the VMs as required by the activity:"
echo "   - Internal Gateway should point to 127.0.0.1"
echo "   - Ubuntu Desktop should point to 10.10.1.254"
echo "   - Ubuntu Server / External Gateway stay on 8.8.8.8 in this lab"
echo ""
echo "============================================================"
echo " Done: BIND9 bootstrap complete."
echo " Remaining work: domain replacement, validation, dig tests,"
echo " and VM DNS/netplan changes."
echo "============================================================"
