#!/bin/bash
# Orchestrator: runs every nat.d/<NN>-*.sh stage in order.
# Each stage can also be invoked individually via --only <name>.

set -Eeuo pipefail
trap 'printf "[!] apply-nat failed at %s:%d\n" "${BASH_SOURCE[0]:-?}" "$LINENO" >&2' ERR
umask 077

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NATD="$DIR/nat.d"

# Adding a stage = one line in STAGES + one entry in ORDER.
declare -A STAGES=(
    [sysctl]=10-sysctl.sh
    [nic]=20-nic.sh
    [nftables]=30-nftables.sh
)
ORDER=(sysctl nic nftables)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--config <path>] [--table <name>] [--only <stage>] [--down] [--verify]

Stages (run in numeric order by default):
  sysctl    kernel/conntrack tuning  (nat.d/${STAGES[sysctl]})
  nic       NIC offloads             (nat.d/${STAGES[nic]})
  nftables  apply nft ruleset        (nat.d/${STAGES[nftables]})

Special modes:
  --down     remove nft table        (nat.d/99-teardown.sh)
  --verify   check that everything   (nat.d/40-verify.sh)
             applied correctly

CLI flags (override env vars below):
  --config <path>   path to config.toml (sets NAT_CONF)
  --table  <name>   nft table name      (sets NFT_TABLE)

Environment:
  NAT_CONF    path to config.toml   (default: /etc/tun-nat/config.toml)
  NFT_TABLE   nft table name        (default: tun_nat)
  VERIFY_LOG  path to verify log      (default: /tmp/apply-nat-verify.log)
EOF
}

require_arg() { [[ -n "${2:-}" ]] || {
    echo "error: $1 requires a value" >&2
    usage
    exit 2
}; }

ONLY=""
MODE="up"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            require_arg "$1" "${2:-}"
            export NAT_CONF="$2"
            shift 2
            ;;
        --table)
            require_arg "$1" "${2:-}"
            export NFT_TABLE="$2"
            shift 2
            ;;
        --only)
            require_arg "$1" "${2:-}"
            ONLY="$2"
            shift 2
            ;;
        --down)
            MODE="down"
            shift
            ;;
        --verify)
            MODE="verify"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            usage
            exit 2
            ;;
    esac
done

((EUID == 0)) || {
    echo "error: must run as root (try: sudo $0)" >&2
    exit 1
}

# Stages exit non-zero on failure; propagate so the next one doesn't run
# against a half-applied state.
run_stage() {
    local script="$1"
    [[ -x "$NATD/$script" ]] || {
        echo "[!] missing or not executable: $NATD/$script" >&2
        exit 1
    }
    "$NATD/$script" || exit $?
}

case "$MODE" in
    down)
        run_stage 99-teardown.sh
        exit 0
        ;;
    verify)
        run_stage 40-verify.sh
        exit 0
        ;;
esac

if [[ -z "$ONLY" ]]; then
    for s in "${ORDER[@]}"; do
        run_stage "${STAGES[$s]}"
    done
elif [[ -n "${STAGES[$ONLY]:-}" ]]; then
    run_stage "${STAGES[$ONLY]}"
else
    echo "unknown stage: $ONLY" >&2
    usage
    exit 2
fi
