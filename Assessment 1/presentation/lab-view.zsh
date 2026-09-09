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
VALID_ACTS=(1 2.1 2.2 3 4.1 4.2)

typeset -A ACT_NAME
ACT_NAME=(
  1   "DMZ Networks"
  2.1 "Secure Web Server (NAT, SSL, Proxy)"
  2.2 "DNS Server (BIND9)"
  3   "Email Server (Postfix + Dovecot)"
  4.1 "Firewalls (nftables)"
  4.2 "VPN (OpenVPN)"
)

# Which hosts to walk per activity (trim/expand to suit your time limit).
typeset -A ACT_HOSTS
ACT_HOSTS=(
  1   "rgw egw igw srv dkt"
  2.1 "egw srv igw dkt"
  2.2 "igw srv dkt"
  3   "srv igw dkt"
  4.1 "egw rgw"
  4.2 "igw egw ovc"
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
            # Not 'direct': the desktop's :443 is transparently redirected into
            # Squid ssl-bump. Request by NAME so SNI is present (a bare IP has no
            # SNI and Squid returns 503). This shows DNS -> transparent proxy ->
            # server, on both stacks.
            slide "Web by name (via transparent proxy)" "DNS name -> Squid ssl-bump -> server, IPv4 + IPv6" text "echo '== IPv4 =='; curl -4 -sSik https://www.${LAB_DOMAIN}/ | head -10; echo; echo '== IPv6 =='; curl -6 -sSik https://www.${LAB_DOMAIN}/ | head -10"
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
            slide "Recursion + DNSSEC" "upstream resolve, ad flag, bogus SERVFAIL" ip "dig +short @127.0.0.1 google.com; echo '-- +dnssec (expect ad) --'; dig @127.0.0.1 google.com +dnssec | grep -E '^;; flags'; echo '-- dnssec-failed (expect SERVFAIL) --'; dig @127.0.0.1 dnssec-failed.org | grep 'status:'"
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
            slide "nftables — full ruleset" "policies, DNAT/SNAT, ICMPv6, port-forward 80/443/25" nft "sudo nft list ruleset"
            slide "DMZ web reachable via DNAT" "http/https to 192.168.1.80 (ping is blocked by design)" text "echo '== HTTP =='; curl -sSI http://192.168.1.80 | head -5; echo '== HTTPS =='; curl -sSIk https://192.168.1.80 | head -5"
            slide "Internet egress (IPv4 + IPv6)" "return path works on both stacks" text "echo '== IPv4 =='; curl -sSI https://google.com | head -4; echo '== IPv6 =='; curl -6 -sSI https://google.com | head -4"
            ;;
          rgw)
            slide "nftables — tunnel edge" "IPv6 forward + masquerade to the /56" nft "sudo nft list ruleset"
            ;;
        esac
        ;;
      # ---- Activity 4.2: VPN (OpenVPN server on IntGW, client = ovc) --------
      4.2)
        case "$H" in
          igw)
            slide "OpenVPN — server.conf" "proto / dev / server / push (+ IPv6)" ini "sudo grep -vE '^[[:space:]]*[#;]|^[[:space:]]*\$' /etc/openvpn/server.conf"
            slide "OpenVPN — service + tun0" "server up, tunnel 10.8.0.1 / df80::1" text "systemctl is-active 'openvpn@server' 'openvpn-server@server' 2>/dev/null; echo; ip -brief addr show tun0 2>/dev/null || echo 'no tun0'"
            ;;
          egw)
            slide "nftables — OpenVPN forward" "UDP 1194 permitted / forwarded" nft "sudo nft list ruleset | grep -iB1 -A1 1194 || sudo nft list ruleset"
            ;;
          ovc)
            slide "VPN client — tunnel up" "tun0 addressed 10.8.0.x / df80::x" text "ip -brief addr show tun0 2>/dev/null || echo 'no tun0 — is the client connected?'"
            slide "Reach across the tunnel" "ping the server (10.8.0.1) and the DMZ web server" text "ping -c3 -W2 10.8.0.1 2>&1 | tail -3; echo; ping -c3 -W2 192.168.1.80 2>&1 | tail -3"
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
    run "$H" "sudo $(remote_automark)"
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
