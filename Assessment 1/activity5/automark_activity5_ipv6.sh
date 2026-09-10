#!/bin/bash
# =============================================================================
# Automarking Script — Activity 5: Endpoint Detection & Response (Rustinel EDR)
# 3014ICT Assessment 1 | Chris Grul (s5501035)
# -----------------------------------------------------------------------------
# Runs on ovc (the OpenVPN client). Read-only / non-destructive: it verifies that
# Rustinel is installed, the eBPF prerequisites are met, the managed service is
# running and healthy, the Essential pack + the two custom Activity-5 rules are
# present, the scanners/IOC are enabled, and alerts are being written.
#
#   E1 — Rustinel not installed
#   E2 — eBPF prerequisites missing (kernel < 5.8 or no BTF)
#   E3 — Rustinel service not running
#   E4 — `rustinel doctor` reports a problem
#   E5 — Essential pack rules missing (reverse-shell Sigma / EICAR IOC)
#   E6 — Custom Activity-5 rules missing (SSH brute-force Sigma / EICAR YARA)
#   E7 — Scanners or IOC matching disabled in config.toml
#   E8 — No alert output (pipeline not writing ECS NDJSON)
#
# Usage: sudo bash automark_activity5_ipv6.sh
# =============================================================================
if [ "$EUID" -ne 0 ]; then echo "  [ERROR] run with sudo"; exit 1; fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0; ERRORS=()
pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}[FAIL]${NC} $2"; echo -e "         ${YELLOW}→ Error $1${NC}"; ERRORS+=("$1"); ((FAIL++)) || true; }
info() { echo -e "  ${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
section() { echo ""; echo -e "${BOLD}--- $1 ---${NC}"; }

# Detect the layout: `rustinel setup` may produce the system layout
# (/etc/rustinel + /var/log/rustinel) or leave the package-local layout under
# /opt/rustinel. Resolve config, rules root and alert dir for whichever exists.
CONFIG=""; for c in /etc/rustinel/config.toml /opt/rustinel/config.toml; do
    [ -f "$c" ] && CONFIG="$c" && break
done
CONFIG="${CONFIG:-/etc/rustinel/config.toml}"
if [ "$CONFIG" = /etc/rustinel/config.toml ]; then RROOT=/var/lib/rustinel/rules; LOGDEF=/var/log/rustinel
else RROOT=/opt/rustinel/rules; LOGDEF=/opt/rustinel/logs; fi
# Resolve the Rustinel binary (never on PATH: the installer places it by path).
RB="$(command -v rustinel 2>/dev/null || true)"
[ -n "$RB" ] || for p in /opt/rustinel/rustinel /usr/local/bin/rustinel /usr/bin/rustinel; do
    [ -x "$p" ] && RB="$p" && break
done
echo -e "\n${BOLD}${CYAN}VM detected: OpenVPN Client (ovc) — Activity 5 EDR${NC}"

section "Rustinel Installation"
if [ -n "$RB" ]; then
    pass "Rustinel installed ($("$RB" --version 2>/dev/null | head -1); $RB)"
else
    fail "E1" "Rustinel not installed — run activity5/setup-rustinel.sh"
fi

section "eBPF Prerequisites"
KREL="$(uname -r)"; KMAJ="${KREL%%.*}"; KMIN="$(echo "$KREL" | cut -d. -f2)"
if [ "$KMAJ" -gt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -ge 8 ]; }; then
    pass "kernel $KREL (>= 5.8)"
else
    fail "E2" "kernel $KREL is < 5.8 — eBPF collector needs 5.8+"
fi
if [ -r /sys/kernel/btf/vmlinux ]; then pass "kernel BTF present"; else fail "E2" "no /sys/kernel/btf/vmlinux (BTF missing)"; fi

section "Managed Service"
if "$RB" service status 2>/dev/null | grep -qi running || systemctl is-active --quiet rustinel 2>/dev/null; then
    pass "Rustinel service running"
else
    fail "E3" "Rustinel service not running — 'sudo rustinel service start' / check journalctl -u rustinel"
fi

section "Health (rustinel doctor)"
# doctor exits non-zero on WARN as well as FAIL, but WARN is non-fatal (e.g. a
# telemetry snapshot not yet written). Grade on the reported Status, not the exit
# code: PASS/WARN are healthy, only FAIL (or no status) is a problem.
"$RB" doctor >/tmp/rustinel_doctor.$$ 2>&1 || true
dstat="$(grep -oiE 'Status:[[:space:]]*(PASS|WARN|FAIL)' /tmp/rustinel_doctor.$$ 2>/dev/null | grep -oiE 'PASS|WARN|FAIL' | head -1 | tr '[:lower:]' '[:upper:]')"
case "$dstat" in
    PASS) pass "doctor reports healthy (PASS)" ;;
    WARN) pass "doctor healthy with warnings (WARN — non-fatal)" ;;
    *)    fail "E4" "doctor reported a problem:"; sed 's/^/           /' /tmp/rustinel_doctor.$$ | head -8 ;;
esac
rm -f /tmp/rustinel_doctor.$$ 2>/dev/null

# Resolve rule dirs from config, with the detected layout's defaults.
sigdir="$(awk -F\" '/^[[:space:]]*sigma_rules_path/{print $2}' "$CONFIG" 2>/dev/null)"; sigdir="${sigdir:-$RROOT/sigma}"
yardir="$(awk -F\" '/^[[:space:]]*yara_rules_path/{print $2}'  "$CONFIG" 2>/dev/null)"; yardir="${yardir:-$RROOT/yara}"
RULES_ROOT="$RROOT"

section "Essential Pack Rules"
if grep -rqiE 'dev/tcp|reverse[ _-]?shell' "$RULES_ROOT" 2>/dev/null; then
    pass "reverse-shell Sigma rule present (Essential)"
else
    fail "E5" "reverse-shell Sigma rule not found under $RULES_ROOT — is the Essential pack installed? (rustinel setup --pack essential)"
fi
if grep -rqi 'eicar' "$RULES_ROOT" 2>/dev/null; then
    pass "EICAR detection content present (IOC/YARA)"
else
    fail "E5" "no EICAR content under $RULES_ROOT — Essential pack ships the EICAR IOC set"
fi

section "Custom Activity-5 Rules"
if grep -rqi 'unix_chkpwd' "$sigdir" 2>/dev/null; then
    pass "SSH brute-force Sigma rule installed (unix_chkpwd)"
else
    fail "E6" "SSH brute-force rule missing from $sigdir — re-run setup-rustinel.sh"
fi
if grep -rqi 'EICAR_Test_File' "$yardir" 2>/dev/null; then
    pass "EICAR YARA rule installed"
else
    warn "custom EICAR YARA rule not found in $yardir (Essential IOC set still covers EICAR)"
fi

section "Scanners / IOC Enabled"
en_ok=1
grep -qE '^[[:space:]]*sigma_enabled[[:space:]]*=[[:space:]]*true' "$CONFIG" 2>/dev/null || en_ok=0
grep -qE '^[[:space:]]*yara_enabled[[:space:]]*=[[:space:]]*true'  "$CONFIG" 2>/dev/null || en_ok=0
grep -qE '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true'       "$CONFIG" 2>/dev/null || en_ok=0
if [ "$en_ok" = 1 ]; then pass "sigma + yara + ioc enabled in $CONFIG"; else fail "E7" "a scanner/IOC is not enabled in $CONFIG"; fi

section "Alert Pipeline (ECS NDJSON)"
# Search the known alert dirs directly rather than parsing the config (the managed
# config has several `directory =` keys, so an awk match could grab the wrong one).
ALERTDIR=""
for d in "$LOGDEF" /var/log/rustinel /opt/rustinel/logs; do
    [ -n "$d" ] && ls "$d"/alerts.json* >/dev/null 2>&1 && ALERTDIR="$d" && break
done
if [ -n "$ALERTDIR" ]; then
    n=$(cat "$ALERTDIR"/alerts.json* 2>/dev/null | wc -l)
    pass "alerts written to $ALERTDIR/alerts.json* ($n line(s))"
else
    fail "E8" "no alert file in /var/log/rustinel or /opt/rustinel/logs — trigger a detection (or 'whoami') with the agent up"
fi

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Summary${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "  Passed : ${GREEN}${PASS}${NC}"
echo -e "  Failed : ${RED}${FAIL}${NC}"
[ "${#ERRORS[@]}" -gt 0 ] && echo -e "  Errors : ${YELLOW}${ERRORS[*]}${NC}"
exit 0
