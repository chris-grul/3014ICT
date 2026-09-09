#!/usr/bin/env python3
"""
lab_lexers.py — custom Pygments lexers + style for the lab-view walkthrough.

Runs as a highlighter for lab-view.zsh:

    printf '%s' "$content" | python3 lab_lexers.py nft
    printf '%s' "$content" | python3 lab_lexers.py systemd
    printf '%s' "$content" | python3 lab_lexers.py yaml    # built-in lexers work too

All output uses LabStyle (below) so every slide shares one colour scheme. Tune
the colours in LabStyle to taste. Keep this file beside lab-view.zsh.
"""

import re
from pygments.filter import Filter
from pygments.lexer import RegexLexer, bygroups, words
from pygments.style import Style
from pygments.token import (Comment, Keyword, Literal, Name, Number, Operator,
                            Punctuation, String, Text, Whitespace, Token)

__all__ = ['NftablesLexer', 'SystemdLexer', 'LabOutputLexer', 'IPAddressFilter', 'LabStyle']

# --- IPv4 / IPv6 address tokens (coloured to match the topology map) ----------
IPv4 = Token.Net.IPv4
IPv6 = Token.Net.IPv6

_MAC_RE = re.compile(r'^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$')
_IP_RE = re.compile(r'''
    (?P<ip6>
        (?:                                                    # longest forms first
            (?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}          # full 8 groups
          | (?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}        # a::x
          | (?:[0-9A-Fa-f]{1,4}:){1,5}(?::[0-9A-Fa-f]{1,4}){1,2}
          | (?:[0-9A-Fa-f]{1,4}:){1,4}(?::[0-9A-Fa-f]{1,4}){1,3}
          | (?:[0-9A-Fa-f]{1,4}:){1,3}(?::[0-9A-Fa-f]{1,4}){1,4}
          | (?:[0-9A-Fa-f]{1,4}:){1,2}(?::[0-9A-Fa-f]{1,4}){1,5}
          | [0-9A-Fa-f]{1,4}:(?::[0-9A-Fa-f]{1,4}){1,6}
          | (?:[0-9A-Fa-f]{1,4}:){1,7}:                        # trailing :: (a::)
          | :(?:(?::[0-9A-Fa-f]{1,4}){1,7}|:)                  # leading ::
        )(?:/\d{1,3})?
    )
  | (?P<ip4>\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?)
''', re.VERBOSE)


class IPAddressFilter(Filter):
    """Recolour IPv4 (violet) and IPv6 (blue) addresses in ANY lexer's output,
    so netplan / ip a / ip route / wireguard / nftables all match the map."""
    def filter(self, lexer, stream):
        for ttype, value in stream:
            pos = 0
            for m in _IP_RE.finditer(value):
                g6 = m.group('ip6')
                if g6 and _MAC_RE.match(g6):
                    continue                       # leave MAC addresses alone
                if m.start() > pos:
                    yield ttype, value[pos:m.start()]
                yield (IPv6 if g6 else IPv4), m.group()
                pos = m.end()
            if pos < len(value):
                yield ttype, value[pos:]

# --- Custom semantic token types for nftables verdicts / actions -------------
# Splitting these out (instead of one "Keyword.Constant") lets the style paint
# accept vs drop/reject differently.
V        = Token.Verdict
V_ACCEPT = V.Accept      # accept
V_DENY   = V.Deny        # drop, reject
V_NAT    = V.Nat         # masquerade, snat, dnat, redirect
V_FLOW   = V.Flow        # jump, goto, return, continue, queue
V_OBS    = V.Observe     # log, counter, ...


class NftablesLexer(RegexLexer):
    """Highlighter for nftables rulesets / nftables.conf."""
    name = 'nftables'
    aliases = ['nft', 'nftables']
    filenames = ['*.nft', 'nftables.conf']

    _structure = ('table', 'chain', 'map', 'set', 'element', 'flush', 'add',
                  'delete', 'insert', 'replace', 'rename', 'create', 'list',
                  'define', 'redefine', 'undefine', 'include')
    _families  = ('ip', 'ip6', 'inet', 'arp', 'bridge', 'netdev')
    _chainspec = ('type', 'hook', 'priority', 'policy', 'device', 'devices',
                  'flags', 'filter', 'route', 'nat')
    _hooks     = ('prerouting', 'input', 'forward', 'output', 'postrouting',
                  'ingress', 'egress')

    # Semantic verdict/action groups
    _accept  = ('accept',)
    _deny    = ('drop', 'reject')
    _nat     = ('masquerade', 'snat', 'dnat', 'redirect')
    _flow    = ('queue', 'continue', 'return', 'jump', 'goto')
    _observe = ('log', 'counter', 'notrack', 'nftrace', 'limit', 'quota',
                'synproxy', 'dup', 'fwd', 'tproxy')

    _matches = ('iifname', 'oifname', 'iif', 'oif', 'meta', 'ct', 'tcp', 'udp',
                'udplite', 'icmp', 'icmpv6', 'igmp', 'ah', 'esp', 'comp',
                'sctp', 'dccp', 'ether', 'vlan', 'saddr', 'daddr', 'sport',
                'dport', 'protocol', 'state', 'status', 'mark', 'l4proto',
                'nfproto', 'length', 'ttl', 'hoplimit', 'dscp', 'pkttype',
                'skuid', 'skgid', 'rt', 'frag', 'dst', 'hbh')
    _states  = ('established', 'related', 'new', 'invalid', 'untracked')

    def _w(seq):
        return words(seq, prefix=r'\b', suffix=r'\b')

    tokens = {
        'root': [
            (r'\s+', Whitespace),
            (r'#.*?$', Comment.Single),
            (r'/\*', Comment.Multiline, 'comment'),
            (r'"[^"]*"', String.Double),
            (_w(_structure), Keyword.Declaration),
            (_w(_hooks),     Name.Builtin),
            (_w(_families),  Keyword.Type),
            (_w(_chainspec), Keyword),
            (_w(_accept),    V_ACCEPT),
            (_w(_deny),      V_DENY),
            (_w(_nat),       V_NAT),
            (_w(_flow),      V_FLOW),
            (_w(_observe),   V_OBS),
            (_w(_states),    Name.Constant),
            (_w(_matches),   Name.Attribute),
            # IPv6 address / prefix (>=2 colons to avoid false hits)
            (r'\b(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(?:/\d{1,3})?', Number.Hex),
            # IPv4 address / CIDR
            (r'\b\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?\b', Number.Integer),
            # ports / priorities / plain numbers (allow negative priority)
            (r'-?\b\d+\b', Number),
            # bare identifiers (chain/table/set names, unquoted values)
            (r'[@$]?[A-Za-z_][\w./-]*', Name),
            (r'[{}()\[\],;]', Punctuation),
            (r'[=!<>]=?|[-+*/&|~]', Operator),
            (r'\S', Text),
        ],
        'comment': [
            (r'[^*/]+', Comment.Multiline),
            (r'\*/', Comment.Multiline, '#pop'),
            (r'[*/]', Comment.Multiline),
        ],
    }


class SystemdLexer(RegexLexer):
    """Highlighter for systemd unit files (.service/.socket/.timer/...)."""
    name = 'systemd'
    aliases = ['systemd']
    filenames = ['*.service', '*.socket', '*.timer', '*.target', '*.mount',
                 '*.path', '*.slice', '*.device']

    tokens = {
        'root': [
            (r'\s+', Whitespace),
            (r'[#;].*?$', Comment.Single),
            (r'^\[[^\]]+\]', Keyword.Namespace),          # [Unit], [Service], ...
            (r'^([A-Za-z0-9_-]+)(\s*=\s*)',
             bygroups(Name.Attribute, Operator), 'value'),
            (r'.', Text),
        ],
        'value': [
            (r'\\\n', String.Escape),                     # line continuation
            (r'\n', Text, '#pop'),
            (r'%[a-zA-Z%]', String.Interpol),             # specifiers: %i %n %H ...
            (r'"[^"]*"', String.Double),
            (r'[^\\\n%"]+', String),
            (r'\\', String),
        ],
    }


# --- Custom colour scheme -----------------------------------------------------
HEAD = Token.Lab.Head          # "== section ==" banners in command output


class LabOutputLexer(RegexLexer):
    """Generic highlighter for command OUTPUT (curl headers, ss/systemctl, squid
    logs, tcpdump -X hex, ip a/route). Not a real grammar — it just paints the
    tokens that matter for the walkthrough so plain 'text' slides are readable.
    IPv4/IPv6 are recoloured afterwards by IPAddressFilter."""
    name = 'laboutput'
    aliases = ['laboutput', 'labout', 'output', 'out']
    flags = re.MULTILINE

    tokens = {
        'root': [
            (r'\n', Whitespace),
            # line-anchored patterns FIRST (before the whitespace consumer, so a
            # leading tab doesn't get eaten before these can match at ^):
            # hex dump lines (tcpdump -X): grey offset, then the bytes are ciphertext
            (r'^[ \t]*0x[0-9a-fA-F]+:', Comment, 'hexline'),
            (r'^[ \t]*-{2,}[ \t]*$', Comment),
            (r'[ \t]+', Whitespace),
            # our own "== section ==" banners
            (r'==[^=\n]*==', HEAD),
            # HTTP status lines, coloured by class
            (r'HTTP/\d(?:\.\d)?\s+2\d\d\b[^\n]*', V_ACCEPT),
            (r'HTTP/\d(?:\.\d)?\s+3\d\d\b[^\n]*', Name.Builtin),
            (r'HTTP/\d(?:\.\d)?\s+[45]\d\d\b[^\n]*', V_DENY),
            # HTTP/response header name at start of line
            (r'^([A-Za-z][A-Za-z0-9-]*)(:)(?=[ \t])', bygroups(Name.Attribute, Punctuation)),
            # squid-style /403 /503 vs /200 result codes
            (r'/[45]\d\d\b', V_DENY),
            (r'/2\d\d\b', V_ACCEPT),
            # keep whole IPs as single tokens so IPAddressFilter can recolour them
            # (fragmenting into digits would defeat the filter). Emit as Text; the
            # filter repaints real IPv4/IPv6 and skips MACs.
            (r'\b\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?\b', Text),                 # IPv4
            (r'(?:[0-9A-Fa-f]{1,4})?(?::[0-9A-Fa-f]{0,4}){2,}(?:/\d{1,3})?', Text),  # IPv6 (incl ::)
            # verdict / status keywords
            (r'\b(?:UP|LISTEN|ESTAB|ESTABLISHED)\b', V_ACCEPT),
            (r'(?i)\b(?:pass(?:ed)?|active|enabled|running|listening|present|match|success(?:ful)?|succeeded|valid|reachable|allow(?:ed)?|ok)\b', V_ACCEPT),
            (r'(?i)\b(?:fail(?:ed)?|inactive|disabled|dead|denied|tcp_denied|drop(?:ped)?|reject(?:ed)?|blocked|refused|unreachable|servfail|missing|timeout|invalid|error|down)\b', V_DENY),
            # TLS / crypto vocabulary
            (r'(?i)\b(?:TLSv1\.\d|TLS|SSL|Application Data|Client Hello|Server Hello|Handshake|Encrypted|ciphertext|Change Cipher Spec)\b', Name.Constant),
            (r':\d{2,5}\b', Number),
            (r'\b\d+\b', Number),
            (r'[A-Za-z_][\w.-]*', Text),
            (r'.', Text),
        ],
        'hexline': [
            (r'[^\n]+', Number),       # the whole byte/ascii body = ciphertext
            (r'\n', Whitespace, '#pop'),
        ],
    }


class LabStyle(Style):
    """Dark scheme tuned for the walkthrough. Verdicts are the headline:
    accept = green, drop/reject = red, nat = orange."""
    background_color = "#1e1e1e"
    styles = {
        Token:               "#ecf0f1",
        Comment:             "italic #7f8c8d",
        Comment.Multiline:   "italic #7f8c8d",

        Keyword:             "bold #5dade2",   # chainspec: type/hook/priority/policy
        Keyword.Declaration: "bold #5dade2",   # table/chain/set/...
        Keyword.Type:        "#48c9b0",        # families: ip/ip6/inet
        Keyword.Namespace:   "bold #48c9b0",   # systemd [Section]

        Name:                "#ecf0f1",        # bare identifiers
        Name.Builtin:        "bold #5499c7",   # hooks: forward/input/...
        Name.Attribute:      "#85c1e9",        # matches: iifname/ct/tcp/dport, systemd keys
        Name.Constant:       "#f5b041",        # ct states: established/related
        Name.Tag:            "#85c1e9",        # yaml keys (netplan)
        Literal:             "#f7dc6f",        # yaml scalar values
        Literal.Scalar:      "#f7dc6f",

        String:              "#f7dc6f",        # unit values
        String.Double:       "#f7dc6f",        # "eth0" interface names
        String.Interpol:     "#e67e22",        # systemd %i specifiers
        String.Escape:       "#e67e22",

        Number:              "#bb8fce",         # ports / priorities

        # IP addresses — same hues as the topology map (violet=IPv4, blue=IPv6),
        # but LIGHTER variants: the map's #8700ff / #0000ff sit on light host
        # boxes; here they're on a black terminal, so lift them to stay readable.
        IPv4:                "bold #af5fff",    # light violet (map: #8700ff)
        IPv6:                "bold #5f87ff",    # light blue   (map: #0000ff)

        Operator:            "#95a5a6",
        Punctuation:         "#95a5a6",

        # nftables verdicts — the important bit
        V_ACCEPT:            "bold #2ecc71",    # accept  -> green
        V_DENY:              "bold #e74c3c",    # drop/reject -> red
        V_NAT:               "bold #e67e22",    # masquerade/snat/dnat -> orange
        V_FLOW:              "bold #f4d03f",    # jump/goto/return -> yellow
        V_OBS:               "#af7ac5",         # log/counter -> purple

        HEAD:                "bold #f39c12",    # "== section ==" banners -> amber
    }


# --- CLI entry point ----------------------------------------------------------
def _main():
    import sys
    from pygments import highlight
    from pygments.formatters import Terminal256Formatter
    from pygments.lexers import get_lexer_by_name
    from pygments.lexers.special import TextLexer

    name = sys.argv[1] if len(sys.argv) > 1 else "text"
    data = sys.stdin.read()

    custom = {'nft': NftablesLexer, 'nftables': NftablesLexer,
              'systemd': SystemdLexer}
    if name in custom:
        lexer = custom[name]()
    elif name in ('ip', 'iproute', 'text', 'plain', 'out', 'output', 'labout', 'laboutput'):
        lexer = LabOutputLexer()       # generic command-output colouriser
    else:
        try:
            lexer = get_lexer_by_name(name)
        except Exception:
            lexer = TextLexer()

    lexer.add_filter(IPAddressFilter())   # colour IPv4/IPv6 in every output
    sys.stdout.write(highlight(data, lexer, Terminal256Formatter(style=LabStyle)))


if __name__ == "__main__":
    _main()