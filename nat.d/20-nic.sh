#!/bin/bash
# NIC offloads (GRO/GSO/TSO) and external-interface RPS for multi-queue virtio.
# Idempotent - safe to re-run.

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
    ethtool -K "$WIREGUARD_INTERFACE" gro on gso on >/dev/null 2>&1 ||
        warn "ethtool -K $WIREGUARD_INTERFACE failed (WG tunnel may not expose all offloads)"
fi

# RPS spreads softirq work across CPUs; pure overhead on a single-core box.
NPROC=$(nproc)

# rps_cpus is comma-separated 32-bit hex words; naive (1<<n)-1 overflows at n>=32.
rps_mask() {
    local n="$1"
    local full=$((n / 32)) rem=$((n % 32)) out="" i
    ((rem > 0)) && out=$(printf '%x' $(((1 << rem) - 1)))
    for ((i = 0; i < full; i++)); do
        out="${out:+$out,}ffffffff"
    done
    printf '%s' "$out"
}

if ((NPROC > 1)); then
    cpus=$(rps_mask "$NPROC")
    wrote_any=0
    for q in /sys/class/net/"$EXTERNAL_INTERFACE"/queues/rx-*/rps_cpus; do
        if [[ -w "$q" ]] && echo "$cpus" >"$q" 2>/dev/null; then
            wrote_any=1
        fi
    done
    if ((wrote_any)); then
        log "NIC offloads + external RPS applied (external.interface=$EXTERNAL_INTERFACE, wireguard.interface=$WIREGUARD_INTERFACE)"
    else
        warn "$EXTERNAL_INTERFACE: no rps_cpus written (no rx queues writable; multiqueue may be off)"
    fi
else
    log "NIC offloads applied; RPS skipped (nproc=$NPROC, no benefit on single-core)"
fi
