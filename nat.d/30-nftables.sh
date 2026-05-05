#!/bin/bash
# Generate and atomically apply the nftables ruleset (chains: raw, forward,
# prerouting/postrouting; flowtable for established UDP). The full topology
# is documented in README.md.

umask 077

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

strict_mode
require_root

command -v nft >/dev/null || die "nft not installed"

TCP_MAP_ELEMS=""
UDP_MAP_ELEMS=""
[[ ${#TCP_ELEMS[@]} -gt 0 ]] && TCP_MAP_ELEMS=$(join_csv "${TCP_ELEMS[@]}")
[[ ${#UDP_ELEMS[@]} -gt 0 ]] && UDP_MAP_ELEMS=$(join_csv "${UDP_ELEMS[@]}")

TCP_MAP_BLOCK=""
UDP_MAP_BLOCK=""
TCP_DNAT_RULE="# (no tcp port_rules)"
UDP_DNAT_RULE="# (no udp port_rules)"

if [[ -n "$TCP_MAP_ELEMS" ]]; then
    TCP_MAP_BLOCK=$(
        cat <<EOF
    map dnat_tcp {
        type inet_service : ipv4_addr
        flags interval
        elements = { $TCP_MAP_ELEMS }
    }
EOF
    )
    TCP_DNAT_RULE="iifname \"$EXTERNAL_INTERFACE\" meta l4proto tcp dnat ip to tcp dport map @dnat_tcp"
fi

if [[ -n "$UDP_MAP_ELEMS" ]]; then
    UDP_MAP_BLOCK=$(
        cat <<EOF
    map dnat_udp {
        type inet_service : ipv4_addr
        flags interval
        elements = { $UDP_MAP_ELEMS }
    }
EOF
    )
    UDP_DNAT_RULE="iifname \"$EXTERNAL_INTERFACE\" meta l4proto udp dnat ip to udp dport map @dnat_udp"
fi

if [[ -n "${EXTERNAL_IP:-}" ]]; then
    SNAT_RULE="oifname \"$EXTERNAL_INTERFACE\" snat ip to $EXTERNAL_IP"
else
    SNAT_RULE="oifname \"$EXTERNAL_INTERFACE\" masquerade"
fi

MAPS=""
[[ -n "$TCP_MAP_BLOCK" ]] && MAPS+="$TCP_MAP_BLOCK"$'\n'
[[ -n "$UDP_MAP_BLOCK" ]] && MAPS+="$UDP_MAP_BLOCK"$'\n'

NFT_RULESET=$(
    cat <<EOF
# idempotent atomic replace: stub-create, delete, recreate -- all in one tx
table inet $TABLE
delete table inet $TABLE

table inet $TABLE {
    flowtable ft {
        hook ingress priority filter
        devices = { $EXTERNAL_INTERFACE, $WIREGUARD_INTERFACE }
    }
${MAPS:+
$MAPS}
    chain raw_pre {
        type filter hook prerouting priority raw; policy accept;
        iifname "$EXTERNAL_INTERFACE" udp dport $WIREGUARD_PORT notrack
    }

    chain raw_out {
        type filter hook output priority raw; policy accept;
        oifname "$EXTERNAL_INTERFACE" udp sport $WIREGUARD_PORT notrack
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
        meta l4proto udp ct state established,related flow add @ft
        tcp flags syn / syn,rst tcp option maxseg size set rt mtu
    }

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        $TCP_DNAT_RULE
        $UDP_DNAT_RULE
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        $SNAT_RULE
    }
}
EOF
)

# `nft -f -` is one transaction: any error rolls the whole thing back, so a
# separate `nft -c` pre-check would just re-parse the same input.
if ! printf '%s\n' "$NFT_RULESET" | nft -f -; then
    warn "nft apply failed; generated source:"
    printf '%s\n' "$NFT_RULESET" >&2
    exit 1
fi

log "nftables table 'inet $TABLE' applied"
if [[ -n "${EXTERNAL_IP:-}" ]]; then
    log "SNAT mode: SNAT to $EXTERNAL_IP"
else
    log "SNAT mode: MASQUERADE"
fi
