#!/bin/bash
# Remove the nft NAT/forward table.
# Sysctl/external RPS settings are NOT reverted - they reset on reboot.

umask 077

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Skip TOML/iface validation so --down still works after the WG iface is gone.
export NAT_LIB_MINIMAL=1
# shellcheck source=lib.sh
source "$DIR/lib.sh"

strict_mode
require_root

if nft list table inet "$TABLE" >/dev/null 2>&1; then
    nft delete table inet "$TABLE"
    log "nftables table 'inet $TABLE' removed"
else
    log "nftables table 'inet $TABLE' not present, nothing to remove"
fi
