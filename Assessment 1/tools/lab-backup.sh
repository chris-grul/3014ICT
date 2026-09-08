#!/usr/bin/env bash
# =============================================================================
# lab-backup.sh — back up each VM's relevant config to GitHub
#
#   Repo layout produced (only the categories a given VM actually has):
#     vms/<vm>/nftables/    vms/<vm>/wireguard/   vms/<vm>/netplan/
#     vms/<vm>/sysctl/      vms/<vm>/systemd/     vms/<vm>/scripts/
#     vms/<vm>/squid/       vms/<vm>/pam/         vms/<vm>/ssh/
#     vms/<vm>/bind/        vms/<vm>/postfix/     vms/<vm>/dovecot/
#     vms/<vm>/apache/      vms/<vm>/openvpn/
#     vms/<vm>/state/       vms/<vm>/README.md
#
#   state/ also captures secret-free effective dumps where the service exists:
#     postfix-postconf.txt, dovecot-doveconf.txt, apache-vhosts.txt,
#     apache-modules.txt, apache-sites-enabled.txt, bind-named-effective.txt,
#     listeners.txt
#
#   Usage (run WITH sudo — needs root to read /etc/wireguard etc.):
#     sudo ./lab-backup.sh                 # detect this VM and back it up
#     ./lab-backup.sh install-pat <TOKEN>  # idempotently write ~/gh-pat.key (600)
#
#   The GitHub PAT is read from ~/gh-pat.key (see PAT_FILE resolution below).
#   PAT needs, at minimum, Contents read/write on the target repo. If the repo
#   doesn't exist yet, the script tries to create it PRIVATE (needs repo-create
#   scope); otherwise create it manually first.
#
#   SECURITY: WireGuard private/preshared keys are REDACTED, and Squid ssl_cert
#   keys are never copied. Keep the repo PRIVATE regardless — it maps your whole
#   network. Set INCLUDE_SECRETS=1 to disable redaction (NOT recommended).
# =============================================================================
set -euo pipefail
shopt -s nullglob

# ---------------- configuration ----------------
OWNER="chris-grul"
REPO="${LAB_BACKUP_REPO:-3014ICT_backup}"   # <-- change if your repo differs
BRANCH="main"
GIT_USER_NAME="lab-backup-bot"
GIT_USER_EMAIL="lab-backup@localhost"

# Resolve the PAT file: prefer $HOME, fall back to the sudo-invoking user's home
PAT_FILE="${GH_PAT_FILE:-$HOME/gh-pat.key}"
if [ ! -f "$PAT_FILE" ] && [ -n "${SUDO_USER:-}" ]; then
    alt="$(eval echo "~${SUDO_USER}")/gh-pat.key"
    [ -f "$alt" ] && PAT_FILE="$alt"
fi

die(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ---------------- PAT install (idempotent) ----------------
install_pat(){
    local token="${1:-}"
    [ -n "$token" ] || die "usage: $0 install-pat <TOKEN>"
    local target="${GH_PAT_FILE:-$HOME/gh-pat.key}"
    umask 077
    if [ -f "$target" ] && [ "$(tr -d ' \t\r\n' < "$target")" = "$token" ]; then
        echo "PAT already present at $target (unchanged)."
    else
        printf '%s\n' "$token" > "$target"
        chmod 600 "$target"
        echo "PAT written to $target (mode 600)."
    fi
}

# ---------------- detect which VM this is ----------------
has_ip(){ grep -qF "inet $1" <<< "$(ip addr show 2>/dev/null)"; }
detect_vm(){
    if   has_ip "112.213.39.252";                    then echo "rgw"
    elif has_ip "192.168.1.254";                     then echo "egw"
    elif has_ip "192.168.1.1" && has_ip "10.10.1.254"; then echo "igw"
    elif has_ip "192.168.1.80";                      then echo "srv"
    elif has_ip "10.10.1.1";                         then echo "dkt"
    else echo "unknown"; fi
}

# ---------------- collect config into the snapshot ----------------
# add <category> <path...> — copies each existing path into vms/<vm>/<category>/
add(){
    local cat="$1"; shift
    local existing=()
    local p
    for p in "$@"; do [ -e "$p" ] && existing+=("$p"); done
    [ "${#existing[@]}" -gt 0 ] || return 0
    local d="$DEST/$cat"
    mkdir -p "$d"
    cp -a "${existing[@]}" "$d/"
}

collect(){
    add nftables  /etc/nftables.conf /etc/nftables.d
    add wireguard /etc/wireguard/*.conf
    add netplan   /etc/netplan/*.yaml /etc/netplan/*.yml
    add sysctl    /etc/sysctl.conf /etc/sysctl.d/*.conf
    add systemd   /etc/systemd/system/wstunnel-*.service \
                  /etc/systemd/system/wg-watchdog.service \
                  /etc/systemd/system/wg-watchdog.timer \
                  /etc/systemd/system/wg-quick@wg0.service.d
    add scripts   /usr/local/sbin/wg-watchdog.sh /usr/local/sbin/dbus-session-check
    add pam       /etc/pam.d/sshd
    add ssh       /etc/ssh/sshd_config
    add squid     /etc/squid/squid.conf        # config only — NOT ssl_cert keys
    add radvd     /etc/radvd.conf

    # ---- service configs (each VM only has the ones it runs) ----
    # BIND9 (igw): named configs + zone files ONLY. Deliberately NOT the whole
    # /etc/bind — that would drag in rndc.key / session.key (HMAC secrets that
    # are NOT PEM and would slip past scrub_pem_keys). Those are removed below.
    add bind      /etc/bind/named.conf \
                  /etc/bind/named.conf.options \
                  /etc/bind/named.conf.local \
                  /etc/bind/named.conf.default-zones \
                  /etc/bind/zones \
                  /etc/bind/db.*

    # Postfix (srv): main map files (skip *.db lookup tables)
    add postfix   /etc/postfix/main.cf \
                  /etc/postfix/master.cf \
                  /etc/postfix/virtual \
                  /etc/postfix/virtual_domains \
                  /etc/postfix/transport

    # Dovecot (srv): main config + conf.d. Excludes /etc/dovecot/private (SSL
    # key + dh). Any inline PEM is scrubbed by scrub_pem_keys as a backstop.
    add dovecot   /etc/dovecot/dovecot.conf /etc/dovecot/conf.d

    # Apache (srv): global + ports + vhosts (sites-available holds the real
    # files; sites-enabled are symlinks, captured as a listing in state).
    add apache    /etc/apache2/apache2.conf \
                  /etc/apache2/ports.conf \
                  /etc/apache2/sites-available \
                  /etc/apache2/conf-available

    # OpenVPN (Activity 4.2, when built): configs only. *.key/*.crt/*.pem and
    # the pki/ tree are excluded below; inline keys scrubbed as a backstop.
    add openvpn   /etc/openvpn/*.conf \
                  /etc/openvpn/server/*.conf \
                  /etc/openvpn/client/*.conf
}

# ---------------- redact secrets ----------------
redact_wireguard(){
    [ "${INCLUDE_SECRETS:-0}" = "1" ] && return 0
    local f
    for f in "$DEST"/wireguard/*.conf; do
        sed -i -E 's/^([[:space:]]*(PrivateKey|PresharedKey)[[:space:]]*=).*/\1 <REDACTED>/' "$f"
    done
}
# Catch-all: strip any PEM private key that made it into the snapshot
scrub_pem_keys(){
    [ "${INCLUDE_SECRETS:-0}" = "1" ] && return 0
    local hits f
    hits="$(grep -rlIE 'BEGIN [A-Z0-9 ]*PRIVATE KEY' "$DEST" 2>/dev/null || true)"
    [ -n "$hits" ] || return 0
    while IFS= read -r f; do
        echo "<REDACTED private key material — not backed up>" > "$f"
        echo "  scrubbed private key: ${f#$SNAP/}" >&2
    done <<< "$hits"
}
# Remove non-PEM secret files by name/location (HMAC keys, cert/key material,
# lookup DBs) that scrub_pem_keys can't recognise. Runs even with
# INCLUDE_SECRETS=1 for the truly-sensitive ones is NOT desired, so honour it.
scrub_secret_files(){
    [ "${INCLUDE_SECRETS:-0}" = "1" ] && return 0
    # BIND control/session HMAC keys, if a broad path ever pulled them in
    rm -f "$DEST"/bind/rndc.key "$DEST"/bind/session.key 2>/dev/null || true
    # Dovecot private key/dh material
    rm -rf "$DEST"/dovecot/conf.d/private "$DEST"/dovecot/private 2>/dev/null || true
    # OpenVPN PKI / key material
    rm -rf "$DEST"/openvpn/pki "$DEST"/openvpn/server/pki "$DEST"/openvpn/easy-rsa 2>/dev/null || true
    # Any stray key/cert/lookup-db files anywhere in the snapshot
    find "$DEST" -type f \( \
            -name '*.key' -o -name '*.pem' -o -name '*.p12' -o -name '*.pfx' \
         -o -name '*.crt' -o -name '*.cer' -o -name '*.db' \
         -o -name 'dovecot.pem' \) -print -delete 2>/dev/null \
         | sed "s#^#  removed secret/binary artefact: #; s#$SNAP/##" >&2 || true
}

# ---------------- state snapshot (for reference/restore) ----------------
snapshot_state(){
    local d="$DEST/state"; mkdir -p "$d"
    ip -br addr                   > "$d/ip-addr.txt"          2>&1 || true
    ip route                      > "$d/routes-v4.txt"        2>&1 || true
    ip -6 route                   > "$d/routes-v6.txt"        2>&1 || true
    ip -6 route show table 51820  > "$d/routes-v6-t51820.txt" 2>&1 || true
    have nft && nft list ruleset  > "$d/nft-ruleset.txt"      2>&1 || true
    have wg  && wg show           > "$d/wg-show.txt"          2>&1 || true   # public keys only
    systemctl list-unit-files --state=enabled > "$d/enabled-units.txt" 2>&1 || true
    ss -tulnH                     > "$d/listeners.txt"        2>&1 || true
    uname -a                      > "$d/uname.txt"            2>&1 || true

    # Effective service config (safe, secret-free dumps — only present where the
    # service is installed). These complement the raw files and survive even if
    # a config is split across many drop-ins.
    have postconf     && postconf -n            > "$d/postfix-postconf.txt"  2>&1 || true
    have doveconf     && doveconf -n            > "$d/dovecot-doveconf.txt"  2>&1 || true
    have apache2ctl   && apache2ctl -S          > "$d/apache-vhosts.txt"     2>&1 || true
    have apache2ctl   && apache2ctl -M          > "$d/apache-modules.txt"    2>&1 || true
    # -p prints the effective config; redact any HMAC secret defensively.
    have named-checkconf && named-checkconf -p 2>&1 \
        | sed -E 's/(secret[[:space:]]+)"[^"]*"/\1"<REDACTED>"/' \
        > "$d/bind-named-effective.txt" || true
    # Which apache sites are enabled (sites-enabled are symlinks)
    [ -d /etc/apache2/sites-enabled ] && ls -l /etc/apache2/sites-enabled > "$d/apache-sites-enabled.txt" 2>&1 || true
}

# ---------------- ensure the repo exists (best effort) ----------------
ensure_repo(){
    have curl || return 0
    local code
    code="$(curl -fsS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $TOKEN" \
        "https://api.github.com/repos/$OWNER/$REPO" 2>/dev/null || echo 000)"
    [ "$code" = "200" ] && return 0
    echo "Repo $OWNER/$REPO not found — attempting to create it (private)…"
    curl -fsS -o /dev/null -H "Authorization: Bearer $TOKEN" \
        -d "{\"name\":\"$REPO\",\"private\":true}" \
        "https://api.github.com/user/repos" 2>/dev/null \
        || die "could not create $OWNER/$REPO — create it manually (private) or grant the PAT repo-create scope"
}

# ---------------- main backup flow ----------------
run_backup(){
    have git  || die "git not installed (sudo apt install -y git)"
    [ -f "$PAT_FILE" ] || die "PAT file not found at $PAT_FILE — run: $0 install-pat <TOKEN>"
    TOKEN="$(tr -d ' \t\r\n' < "$PAT_FILE")"; [ -n "$TOKEN" ] || die "PAT file $PAT_FILE is empty"

    VM="$(detect_vm)"
    [ "$VM" != "unknown" ] || die "could not detect which VM this is (check IP addressing)"

    ensure_repo

    # Auth via header so the token never lands in .git/config or the remote URL
    local b64 auth
    b64="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
    auth=( -c "http.extraHeader=Authorization: Basic $b64" )
    local url="https://github.com/$OWNER/$REPO.git"

    SNAP="$(mktemp -d)"; trap 'rm -rf "$SNAP"' EXIT
    git "${auth[@]}" clone --quiet "$url" "$SNAP" || die "clone failed for $url (check PAT scope / repo)"
    cd "$SNAP"
    git config user.name  "$GIT_USER_NAME"
    git config user.email "$GIT_USER_EMAIL"
    git checkout -q -B "$BRANCH"

    # Rebuild only THIS vm's directory
    DEST="$SNAP/vms/$VM"
    rm -rf "$DEST"; mkdir -p "$DEST"
    collect
    redact_wireguard
    scrub_pem_keys
    scrub_secret_files
    snapshot_state
    {
        echo "# $VM — config backup"
        echo
        echo "- Host: \`$(hostname)\`"
        echo "- Last backup (UTC): \`$(date -u +%FT%TZ)\`"
        echo "- Captures: nftables, wireguard, netplan, sysctl, systemd, ssh/pam,"
        echo "  squid, bind, postfix, dovecot, apache, openvpn (where present)."
        echo "- Secrets: WireGuard priv/PSK redacted; PEM private keys scrubbed;"
        echo "  rndc/session/TLS key files and *.db/*.crt/*.pem excluded."
    } > "$DEST/README.md"

    git add -A
    if git diff --cached --quiet; then
        echo "No changes for $VM — nothing to commit."
        return 0
    fi
    git commit -q -m "backup($VM): $(date -u +%FT%TZ)"

    # Push, tolerating concurrent pushes from other VMs
    local tries=0
    until git "${auth[@]}" push --quiet "$url" "$BRANCH"; do
        tries=$((tries + 1)); [ "$tries" -le 5 ] || die "push failed after $tries retries"
        echo "push rejected — rebasing and retrying ($tries)…"
        git "${auth[@]}" pull --rebase --quiet "$url" "$BRANCH" || true
    done
    echo "Backed up $VM → $OWNER/$REPO (vms/$VM)."
}

# ---------------- entrypoint ----------------
case "${1:-}" in
    install-pat) install_pat "${2:-}" ;;
    ""|backup)   run_backup ;;
    *)           die "unknown command '$1' (use: install-pat <TOKEN> | backup)" ;;
esac
