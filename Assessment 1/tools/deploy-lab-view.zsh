#!/bin/zsh
# =============================================================================
# deploy-lab-view.zsh  —  one-time provisioning, run LOCALLY
# -----------------------------------------------------------------------------
# Per host (prompts for your sudo password once, over an SSH TTY), as root:
#   1. git-clones (or updates) the 3014ICT repo into ~PRINCIPAL/3014ICT, owned
#      by PRINCIPAL, so the presentation runs the automarkers straight from the
#      checkout and teaching staff can verify the exact scripts used
#      (git -C ~/3014ICT log/status).
#   2. installs /etc/sudoers.d/lab-view granting PRINCIPAL passwordless sudo on:
#        - the repo automarkers for the activities THIS host is walked for, and
#        - the read-only diagnostics lab-view.zsh runs on this host,
#      built from the EXACT files/binaries present on that host (no wildcards —
#      newer sudo rejects '*' in command arguments), space-escaped for the
#      "Assessment 1" path, and validated with `visudo -cf` BEFORE activation so
#      a bad file can never lock you out.
#
# The provisioning script is delivered inside the SSH command (base64) so your
# local stdin stays free for sudo's password prompt.
#
# SECURITY NOTE — running an automarker that lives in a user-writable checkout
# under passwordless sudo is, by design, equivalent to NOPASSWD on arbitrary
# root code for PRINCIPAL (PRINCIPAL can edit the script it is allowed to run as
# root). That is an accepted trade-off here for provenance ("the repo script is
# what ran"). Keep the checkout pristine and have staff confirm integrity with
# `git -C ~/3014ICT status --porcelain` (empty) and `git -C ~/3014ICT log -1`.
# For a hardened variant, install root-owned copies outside PRINCIPAL's home and
# NOPASSWD those instead (loses the "ran from ~ checkout" property).
# =============================================================================

set -o pipefail

# ---- Config ----------------------------------------------------------------
HOSTS=(rgw egw igw srv dkt)          # set to e.g. (igw) to re-run just one host

PRINCIPAL="user"                                   # account granted NOPASSWD + repo owner
REPO_URL="https://github.com/chris-grul/3014ICT.git"
REPO_REF="main"                                    # branch/tag to check out
REPO_SUBDIR="Assessment 1"                         # activities live here in the repo
LAB_DOMAIN="3014ict.chris.grul.me"                 # for the named-checkzone demo grant
PAT_FILE="gh-pat.key"                              # in ~PRINCIPAL; used if the repo is private

# Which activities each host is walked for in lab-view.zsh (mirrors ACT_HOSTS).
# Only the automarkers for these activities are authorised on that host.
typeset -A HOST_ACTS
HOST_ACTS=(
  rgw "1 4.1"
  egw "1 2.1 4.1 4.2"
  igw "1 2.1 2.2 3 4.2"
  srv "1 2.1 2.2 3"
  dkt "1 2.1 2.2"
)

# ---- Remote provisioning script (quoted heredoc = built on the remote) -----
# Runs under `sudo bash -s -- "<activities>"`; $1 is this host's activity list.
read -r -d '' REMOTE_TEMPLATE <<'RS'
set -eu
ACTS="${1:-}"
PRINCIPAL="__PRINCIPAL__"
REPO_URL="__REPO_URL__"
REPO_REF="__REPO_REF__"
REPO_SUBDIR="__REPO_SUBDIR__"
LAB_DOMAIN="__LAB_DOMAIN__"
PAT_FILE="__PAT_FILE__"

HOME_DIR="$(getent passwd "$PRINCIPAL" | cut -d: -f6)"
[ -n "$HOME_DIR" ] || { echo "  [!!] no home directory for $PRINCIPAL"; exit 1; }
REPO_DIR="$HOME_DIR/3014ICT"

# --- 0. ensure git ---
if ! command -v git >/dev/null 2>&1; then
    echo "  [..] installing git"
    apt-get update -q && apt-get install -y -q git
fi

# --- 1. clone / update the repo AS the principal (owned by them, inspectable) ---
TOKEN=""
[ -f "$HOME_DIR/$PAT_FILE" ] && TOKEN="$(tr -d ' \t\r\n' < "$HOME_DIR/$PAT_FILE")"
AUTH=()
if [ -n "$TOKEN" ]; then
    B64="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
    AUTH=(-c "http.extraHeader=Authorization: Basic $B64")   # keeps token out of .git/config
fi
asuser() { runuser -u "$PRINCIPAL" -- "$@"; }

if [ -d "$REPO_DIR/.git" ]; then
    asuser git "${AUTH[@]}" -C "$REPO_DIR" fetch --quiet origin "$REPO_REF"
    asuser git -C "$REPO_DIR" checkout --quiet "$REPO_REF"
    asuser git "${AUTH[@]}" -C "$REPO_DIR" reset --hard --quiet "origin/$REPO_REF"
    echo "  [ok] updated $REPO_DIR -> origin/$REPO_REF"
else
    if ! asuser git "${AUTH[@]}" clone --quiet --branch "$REPO_REF" "$REPO_URL" "$REPO_DIR"; then
        echo "  [!!] clone failed for $REPO_URL"
        echo "       If the repo is private, put a read-capable PAT at $HOME_DIR/$PAT_FILE"
        echo "       (e.g. reuse the lab-backup token) and re-run."
        exit 1
    fi
    echo "  [ok] cloned $REPO_URL -> $REPO_DIR ($REPO_REF)"
fi

# make sure the automarkers are executable (needed for `sudo <script>`)
find "$REPO_DIR/$REPO_SUBDIR" -type f -name 'automark_*_ipv6.sh' -exec chmod +x {} + 2>/dev/null || true

# --- 2. assemble the exact command list for THIS host ---
esc() { printf '%s' "$1" | sed 's/ /\\ /g'; }   # escape spaces for sudoers
CMDS=()

# 2a. repo automarkers for the activities this host is walked for
for a in $ACTS; do
    f="$REPO_DIR/$REPO_SUBDIR/activity$a/automark_activity${a}_ipv6.sh"
    [ -f "$f" ] && CMDS+=("$(esc "$f")")
done

# 2b. read-only diagnostics lab-view.zsh runs (added only if present on host)
CAT="$(command -v cat || true)"
NFT="$(command -v nft || true)"
SS="$(command -v ss || true)"
SC="$(command -v systemctl || true)"
NCC="$(command -v named-checkconf || true)"
NCZ="$(command -v named-checkzone || true)"

if [ -n "$CAT" ]; then
    for y in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        [ -e "$y" ] && CMDS+=("$CAT $(esc "$y")")
    done
    [ -e /etc/wireguard/wg0.conf ] && CMDS+=("$CAT /etc/wireguard/wg0.conf")
fi
if [ -n "$NFT" ]; then
    CMDS+=("$NFT list ruleset")
    CMDS+=("$NFT list table inet nat")
fi
if [ -n "$SS" ]; then
    CMDS+=("$SS -tuln")
    CMDS+=("$SS -tlnp")
fi
if [ -n "$SC" ]; then
    CMDS+=("$SC is-enabled nftables")
    # only where BIND is present (named-checkconf ships with bind9utils)
    if [ -n "$NCC" ]; then CMDS+=("$SC is-enabled named"); fi
fi
[ -n "$NCC" ] && CMDS+=("$NCC")
ZONE="/etc/bind/zones/db.$LAB_DOMAIN"
[ -n "$NCZ" ] && [ -e "$ZONE" ] && CMDS+=("$NCZ $LAB_DOMAIN $ZONE")

if [ "${#CMDS[@]}" -eq 0 ]; then
    echo "  [!!] no commands resolved for this host - refusing to write empty sudoers"
    exit 1
fi

# --- 3. build the sudoers file ---
umask 077
TMP="$(mktemp /etc/sudoers.d/.lab-view.XXXXXX)"   # leading dot => sudo ignores if left behind
{
    echo "# /etc/sudoers.d/lab-view - installed by deploy-lab-view.zsh"
    echo "# Passwordless read-only diagnostics + repo automarkers for lab-view.zsh."
    echo "Cmnd_Alias LABVIEW = \\"
    n="${#CMDS[@]}"
    i=0
    for c in "${CMDS[@]}"; do
        i=$((i+1))
        if [ "$i" -lt "$n" ]; then printf '    %s, \\\n' "$c"; else printf '    %s\n' "$c"; fi
    done
    echo "$PRINCIPAL ALL=(root) NOPASSWD: LABVIEW"
} > "$TMP"
chown root:root "$TMP"
chmod 0440 "$TMP"

# --- 4. validate BEFORE activating ---
if OUT="$(visudo -cf "$TMP" 2>&1)"; then
    mv "$TMP" /etc/sudoers.d/lab-view
    echo "  [ok] installed /etc/sudoers.d/lab-view (validated):"
    sed 's/^/          /' /etc/sudoers.d/lab-view
else
    echo "  [!!] sudoers check FAILED (existing config left untouched):"
    echo "$OUT" | sed 's/^/          visudo: /'
    echo "  ----- rejected file (cat -A shows hidden bytes) -----"
    cat -A "$TMP" | sed 's/^/          /'
    rm -f "$TMP"
    exit 1
fi
echo "  [ok] $(hostname) provisioned"
RS

# ---- Fill placeholders, encode once ----------------------------------------
REMOTE_SCRIPT="${REMOTE_TEMPLATE//__PRINCIPAL__/$PRINCIPAL}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__REPO_URL__/$REPO_URL}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__REPO_REF__/$REPO_REF}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__REPO_SUBDIR__/$REPO_SUBDIR}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__LAB_DOMAIN__/$LAB_DOMAIN}"
REMOTE_SCRIPT="${REMOTE_SCRIPT//__PAT_FILE__/$PAT_FILE}"
RUN_B64=$(printf '%s' "$REMOTE_SCRIPT" | base64 | tr -d '\n')

# ---- Drive each host -------------------------------------------------------
typeset -a OK FAILED
for H in "${HOSTS[@]}"; do
    print -P "%B%F{045}=== $H ===%f%b"
    ACTS="${HOST_ACTS[$H]}"
    if ssh -t "$H" "printf '%s' '$RUN_B64' | base64 -d | sudo bash -s -- '$ACTS'"; then
        OK+=("$H")
    else
        FAILED+=("$H")
        print -P "%F{196}  deploy failed on $H%f"
    fi
    echo
done

# ---- Summary ---------------------------------------------------------------
print -P "%B=== Summary ===%b"
print -P "  %F{046}provisioned:%f ${OK:-none}"
(( ${#FAILED} )) && print -P "  %F{196}failed:%f      ${FAILED}"
print -P "\nVerify (as $PRINCIPAL, should print NOPASSWD-ok with no prompt):"
print -P "  ssh ${PRINCIPAL}@igw \"sudo -n /home/${PRINCIPAL}/3014ICT/'${REPO_SUBDIR}'/activity2.2/automark_activity2.2_ipv6.sh >/dev/null 2>&1 && echo NOPASSWD-ok\""
print -P "  ssh ${PRINCIPAL}@igw 'git -C ~/3014ICT log -1 --oneline'   # provenance"
