#!/bin/bash
# NIC offloads (GRO/GSO/TSO). Idempotent - safe to re-run.

umask 077

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

strict_mode
require_root

if ! command -v ethtool >/dev/null 2>&1; then
    warn "ethtool not installed; skipping NIC offloads (apt install ethtool)"
else
    ethtool -K "$EXTERNAL_INTERFACE" gro on gso on tso on >/dev/null 2>&1 ||
        warn "ethtool -K $EXTERNAL_INTERFACE failed (driver may not support all of gro/gso/tso)"
    ethtool -K "$TUNNEL_INTERFACE" gro on gso on >/dev/null 2>&1 ||
        warn "ethtool -K $TUNNEL_INTERFACE failed (tunnel may not expose all offloads)"
    log "NIC offloads applied (external.interface=$EXTERNAL_INTERFACE, tunnel.interface=$TUNNEL_INTERFACE)"
fi
