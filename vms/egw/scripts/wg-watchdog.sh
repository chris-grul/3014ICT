#!/bin/sh
healthy() {
  ping -6 -c1 -W3 2001:4860:4860::8888 >/dev/null 2>&1 || \
  ping -6 -c1 -W3 2606:4700:4700::1111 >/dev/null 2>&1
}

healthy && exit 0
sleep 2
healthy && exit 0                       # ride out a single lost packet

logger -t wg-watchdog "IPv6 down — restarting wg-quick@wg0"
systemctl restart wg-quick@wg0
sleep 3
healthy && { logger -t wg-watchdog "recovered after wg0 restart"; exit 0; }

logger -t wg-watchdog "still down — restarting wstunnel-client, then wg0"
systemctl restart wstunnel-client
sleep 3
systemctl restart wg-quick@wg0
