#!/bin/bash
# Kernel/conntrack tuning for the WireGuard NAT forwarder.
# Values come from [tuning] in config.toml.

umask 077

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

strict_mode
require_root

# Mandatory: NAT/forward cannot work without this.
sset net.ipv4.ip_forward 1

sset net.core.netdev_max_backlog "$TUNING_NETDEV_MAX_BACKLOG"
sset net.core.rmem_max "$TUNING_RMEM_MAX"
sset net.core.wmem_max "$TUNING_WMEM_MAX"

# conntrack capacity + per-flow memory savings (no acct/timestamp/helper).
sset net.netfilter.nf_conntrack_max "$TUNING_CONNTRACK_MAX"
sset net.netfilter.nf_conntrack_udp_timeout "$TUNING_UDP_TIMEOUT"
sset net.netfilter.nf_conntrack_udp_timeout_stream "$TUNING_UDP_TIMEOUT_STREAM"
sset net.netfilter.nf_conntrack_acct 0
sset net.netfilter.nf_conntrack_timestamp 0
sset net.netfilter.nf_conntrack_helper 0

# hashsize is a module parameter, not a sysctl.
echo "$TUNING_CONNTRACK_HASHSIZE" >/sys/module/nf_conntrack/parameters/hashsize 2>/dev/null ||
    warn "nf_conntrack hashsize not applied"

log "sysctl tuning applied"
