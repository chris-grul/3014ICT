#!/bin/bash
# =============================================================================
# Automarking Script - Activity 4-2: VPN with OpenVPN
# 7015ICT | Griffith University
# =============================================================================
# Run on Internal Gateway, External Gateway, or OpenVPN Client VM.
# The script auto-detects which VM it is running on.
#
# Error code reference (see Activity 4-2 guide Troubleshooting section):
#   E1 — OpenVPN or Easy-RSA not installed / missing files
#   E2 — PKI not initialised or certificates missing
#   E3 — Files not copied to /etc/openvpn correctly
#   E4 — server.conf missing or misconfigured
#   E5 — IP forwarding not enabled (runtime or persistent)
#   E6 — OpenVPN service not running or not enabled
#   E7 — tun0 interface missing or wrong IP
#   E8 — Client certificates or .ovpn bundle missing
#   E9 — nftables UDP 1194 rules missing on External Gateway
#   E10 — VPN not connected on Client VM (tun0 absent or wrong IP)
#
# Usage: sudo bash automark_activity4.2.sh
# =============================================================================

if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "  [ERROR] Please run with sudo: sudo bash automark_activity4.2.sh"
    echo ""
    exit 1
fi

# -----------------------------------------------------------------------------
REAL_USER="${SUDO_USER:-user}"
USER_HOME=$(eval echo "~$REAL_USER")

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

has_ip() {
    ip addr show 2>/dev/null | grep -q "$1"
}

# =============================================================================
# Detect VM
# =============================================================================
detect_vm() {
    if has_ip "192.168.1.1" && has_ip "10.10.1.254"; then
        echo "internal_gateway"
        return
    fi

    if has_ip "192.168.1.254"; then
        echo "external_gateway"
        return
    fi

    if command -v openvpn >/dev/null 2>&1; then
        echo "openvpn_client"
        return
    fi

    echo "unknown"
}

# =============================================================================
# Internal Gateway
# =============================================================================
run_internal_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: Internal Gateway${NC}"

    OPENVPN_CA="$USER_HOME/openvpn-ca"
    CLIENT_CONFIGS="$USER_HOME/client-configs"

    # -------------------------------------------------------------------------
    section "OpenVPN Installation"

    if command -v openvpn >/dev/null 2>&1; then
        pass "OpenVPN installed"
    else
        fail "E1" "OpenVPN not installed — run: sudo apt install openvpn -y"
    fi

    if [ -f "$OPENVPN_CA/easyrsa" ]; then
        pass "Easy-RSA present ($OPENVPN_CA/easyrsa)"
    else
        fail "E1" "Easy-RSA missing — expected at $OPENVPN_CA/easyrsa"
    fi

    if [ -f "$OPENVPN_CA/vars" ]; then
        pass "vars file present"
    else
        fail "E1" "vars file missing from $OPENVPN_CA/"
    fi

    # -------------------------------------------------------------------------
    section "PKI"

    if [ -d "$OPENVPN_CA/pki" ]; then
        pass "PKI directory exists"
    else
        fail "E2" "PKI not initialised — run: cd $OPENVPN_CA && ./easyrsa init-pki"
    fi

    if [ -f "$OPENVPN_CA/pki/ca.crt" ]; then
        pass "CA certificate exists"
    else
        fail "E2" "CA certificate missing — run: ./easyrsa build-ca"
    fi

    if [ -f "$OPENVPN_CA/pki/issued/server.crt" ]; then
        pass "Server certificate exists"
    else
        fail "E2" "Server certificate missing — run: ./easyrsa gen-req server nopass && ./easyrsa sign-req server server"
    fi

    if [ -f "$OPENVPN_CA/pki/private/server.key" ]; then
        pass "Server key exists"
    else
        fail "E2" "Server key missing — regenerate with: ./easyrsa gen-req server nopass"
    fi

    if [ -f "$OPENVPN_CA/pki/dh.pem" ]; then
        pass "DH parameters exist"
    else
        fail "E2" "DH parameters missing — run: ./easyrsa gen-dh (takes 1–3 min)"
    fi

    if [ -f "$OPENVPN_CA/ta.key" ]; then
        pass "TLS auth key exists"
    else
        fail "E2" "TLS auth key missing — run: openvpn --genkey secret $OPENVPN_CA/ta.key"
    fi

    # -------------------------------------------------------------------------
    section "Files Copied to /etc/openvpn"

    for f in ca.crt server.crt server.key dh2048.pem ta.key; do
        if [ -f "/etc/openvpn/$f" ]; then
            pass "$f present in /etc/openvpn"
        else
            fail "E3" "$f missing from /etc/openvpn — check the copy commands in Part B"
        fi
    done

    # -------------------------------------------------------------------------
    section "server.conf"

    if [ -f /etc/openvpn/server.conf ]; then
        pass "server.conf exists"

        CONF=$(cat /etc/openvpn/server.conf)

        for directive in \
            "port 1194" \
            "proto udp" \
            "dev tun" \
            "server 10.8.0.0" \
            "tls-auth ta.key"
        do
            if echo "$CONF" | grep -q "$directive"; then
                pass "  server.conf: '$directive' found"
            else
                fail "E4" "server.conf: '$directive' missing or commented out"
            fi
        done

    else
        fail "E4" "server.conf missing from /etc/openvpn — copy sample: sudo cp /usr/share/doc/openvpn/examples/sample-config-files/server.conf /etc/openvpn/"
    fi

    # -------------------------------------------------------------------------
    section "IP Forwarding"

    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
        pass "IP forwarding enabled (runtime)"
    else
        fail "E5" "IP forwarding disabled — run: sudo sysctl -w net.ipv4.ip_forward=1"
    fi

    if grep -Eq "net.ipv4.ip_forward *= *1" /etc/sysctl.conf; then
        pass "Persistent IP forwarding set in /etc/sysctl.conf"
    else
        fail "E5" "Persistent IP forwarding missing — add 'net.ipv4.ip_forward=1' to /etc/sysctl.conf then run: sudo sysctl -p"
    fi

    # -------------------------------------------------------------------------
    section "OpenVPN Service"

    if systemctl is-active --quiet openvpn@server; then
        pass "OpenVPN service active"
    else
        fail "E6" "OpenVPN service not running — check: sudo journalctl -u openvpn@server --no-pager | tail -30"
        info "Common causes: wrong certificate path, missing dh2048.pem, or /var/log/openvpn not created"
    fi

    if systemctl is-enabled --quiet openvpn@server; then
        pass "OpenVPN service enabled at boot"
    else
        fail "E6" "OpenVPN service not enabled — run: sudo systemctl enable openvpn@server"
    fi

    # -------------------------------------------------------------------------
    section "tun0 Interface"

    if ip addr show tun0 >/dev/null 2>&1; then
        TUNIP=$(ip -4 addr show tun0 | awk '/inet / {print $2}' | cut -d/ -f1 | tr -d '[:space:]')
        if [[ "$TUNIP" == "10.8.0.1" ]]; then
            pass "tun0 has correct IP (10.8.0.1)"
        else
            fail "E7" "tun0 has wrong IP ($TUNIP) — expected 10.8.0.1; check 'server' directive in server.conf"
        fi
    else
        fail "E7" "tun0 interface missing — OpenVPN service must be running to create it"
    fi

    # -------------------------------------------------------------------------
    section "Client Certificates"

    if [ -f "$OPENVPN_CA/pki/issued/client1.crt" ]; then
        pass "client1.crt exists"
    else
        fail "E8" "client1.crt missing — run: ./easyrsa gen-req client1 nopass && ./easyrsa sign-req client client1"
    fi

    if [ -f "$OPENVPN_CA/pki/private/client1.key" ]; then
        pass "client1.key exists"
    else
        fail "E8" "client1.key missing — regenerate with: ./easyrsa gen-req client1 nopass"
    fi

    if [ -f "$CLIENT_CONFIGS/files/client1.ovpn" ]; then
        pass "client1.ovpn bundle exists"
    else
        fail "E8" "client1.ovpn missing from $CLIENT_CONFIGS/files/ — run make_config.sh and check all keys are in ~/client-configs/keys/"
    fi

    if [ -f "$CLIENT_CONFIGS/base.conf" ]; then
        REMOTE=$(grep '^remote ' "$CLIENT_CONFIGS/base.conf")
        if echo "$REMOTE" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
            pass "base.conf 'remote' IP configured"
        else
            fail "E8" "base.conf 'remote' IP not set — replace [ETH0_IP] with the External Gateway's eth0 IP"
        fi
    else
        fail "E8" "base.conf missing from $CLIENT_CONFIGS/ — copy sample client config and edit it"
    fi
}

# =============================================================================
# External Gateway
# =============================================================================
run_external_gateway() {
    echo -e "\n${BOLD}${CYAN}VM detected: External Gateway${NC}"

    RULESET=$(nft list ruleset 2>/dev/null)

    section "nftables — UDP 1194 Rules"

    if echo "$RULESET" | grep -q "udp dport 1194"; then
        pass "UDP 1194 forward rule present"
    else
        fail "E9" "UDP 1194 forward rule missing — add to forward chain: iif \"eth0\" oif \"eth1\" udp dport 1194 ct state new accept"
    fi

    if echo "$RULESET" | grep -q "dnat to 192.168.1.1"; then
        pass "DNAT rule present (→ 192.168.1.1)"
    else
        fail "E9" "DNAT rule missing — add to prerouting chain: iif \"eth0\" udp dport 1194 dnat to 192.168.1.1"
    fi

    if echo "$RULESET" | grep -q "snat to 192.168.1.254"; then
        pass "SNAT rule present (→ 192.168.1.254)"
    else
        fail "E9" "SNAT rule missing — add to postrouting chain: oif \"eth1\" udp dport 1194 snat to 192.168.1.254"
    fi

    section "Existing Rules (regression check)"

    if echo "$RULESET" | grep -qE 'tcp dport (80|\{ 80, 443|25)'; then
        pass "Previous activity port rules still present"
    else
        warn "HTTP/HTTPS/SMTP forward rules may be missing — verify Activity 4-1 rules were not overwritten"
    fi
}

# =============================================================================
# OpenVPN Client VM
# =============================================================================
run_openvpn_client() {
    echo -e "\n${BOLD}${CYAN}VM detected: OpenVPN Client${NC}"

    section "OpenVPN Installation"

    if command -v openvpn >/dev/null 2>&1; then
        pass "OpenVPN installed"
    else
        fail "E10" "OpenVPN not installed — run: sudo apt install openvpn -y"
    fi

    if [ -f "$USER_HOME/client1.ovpn" ]; then
        pass "client1.ovpn present in home directory"
    else
        fail "E8" "client1.ovpn missing — copy it from the Internal Gateway to ~/"
    fi

    section "VPN Connection"

    if ip addr show tun0 >/dev/null 2>&1; then
        TUNIP=$(ip addr show tun0 | grep inet | awk '{print $2}' | cut -d/ -f1)
        if echo "$TUNIP" | grep -q "^10.8.0\."; then
            pass "tun0 connected with IP $TUNIP"
        else
            fail "E10" "tun0 exists but has unexpected IP ($TUNIP) — expected 10.8.0.x"
        fi

        if ping -c 2 10.8.0.1 >/dev/null 2>&1; then
            pass "Ping to Internal Gateway (10.8.0.1) successful"
        else
            fail "E10" "Cannot ping 10.8.0.1 — check nftables UDP 1194 rules on External Gateway (E9)"
        fi
    else
        fail "E10" "VPN not connected (tun0 absent) — check remote IP in client1.ovpn matches current External Gateway eth0 IP"
        info "Connect via terminal: sudo openvpn --config ~/client1.ovpn"
        info "Check TLS auth direction: server.conf must use 'tls-auth ta.key 0', base.conf must use 'tls-auth ta.key 1'"
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
        echo -e "  ${YELLOW}Refer to the Troubleshooting section of the Activity 4-2 guide.${NC}"
        echo ""
    else
        echo ""
        echo -e "  ${GREEN}${BOLD}All checks passed! Activity 4-2 configuration looks correct.${NC}"
        echo ""
    fi
}

# =============================================================================
# Main
# =============================================================================
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Activity 4-2 Automarker — VPN with OpenVPN${NC}"
echo -e "${BOLD} 7015ICT | Griffith University${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

VM=$(detect_vm)

case "$VM" in
    internal_gateway) run_internal_gateway ;;
    external_gateway) run_external_gateway ;;
    openvpn_client)   run_openvpn_client ;;
    *)
        echo ""
        echo -e "${RED}[ERROR]${NC} Could not detect which VM this is."
        echo ""
        echo "        Expected IP addresses:"
        echo "          Internal Gateway — eth0 at 192.168.1.1 AND eth1 at 10.10.1.254"
        echo "          External Gateway — eth1 at 192.168.1.254"
        echo "          OpenVPN Client   — openvpn command present"
        echo ""
        echo "        Your current addresses:"
        ip -brief addr show 2>/dev/null | sed 's/^/          /'
        exit 1
        ;;
esac

print_summary
