#!/bin/bash
# =============================================================================
# Activity 2 - SSL Config Setup
# 3821ICT | Griffith University
# =============================================================================

BASE_URL="https://raw.githubusercontent.com/7015ICT/SOC-Activities-Project-Griffith/main/activity2.1"

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} Please run with sudo: sudo ./setup_ssl.sh"
    exit 1
fi

echo ""
echo -e "${BOLD}=== Activity 2 SSL Config Setup ===${NC}"
echo ""

# Backup and replace default-ssl.conf
echo -e "[1/2] Configuring SSL Virtual Host..."
cp /etc/apache2/sites-available/default-ssl.conf \
   /etc/apache2/sites-available/default-ssl-original.conf 2>/dev/null

wget -q -O /etc/apache2/sites-available/default-ssl.conf \
  "$BASE_URL/default-ssl.conf"

if [ $? -eq 0 ]; then
    echo -e "      ${GREEN}[DONE]${NC} default-ssl.conf installed (original backed up)"
else
    echo -e "      ${RED}[FAIL]${NC} Could not download default-ssl.conf"
    exit 1
fi

# Download ssl-params.conf
echo -e "[2/2] Configuring SSL Parameters..."
wget -q -O /etc/apache2/conf-available/ssl-params.conf \
  "$BASE_URL/ssl-params.conf"

if [ $? -eq 0 ]; then
    echo -e "      ${GREEN}[DONE]${NC} ssl-params.conf installed"
else
    echo -e "      ${RED}[FAIL]${NC} Could not download ssl-params.conf"
    exit 1
fi

echo ""
echo -e "${GREEN}${BOLD}All SSL config files installed successfully.${NC}"
echo -e "Continue to the next step in the activity guide."
echo ""
