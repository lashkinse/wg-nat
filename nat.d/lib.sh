# shellcheck shell=bash
# Shared helpers + config loader for apply-nat stages. Sourced, not executed.

CONF="${NAT_CONF:-/etc/wg-nat/config.toml}"
TABLE="${NFT_TABLE:-wg_nat}"

# Even in minimal mode (teardown) we still need TABLE for `nft delete table`.
[[ "$TABLE" =~ ^[A-Za-z_][A-Za-z0-9_]{0,31}$ ]] || {
    printf '[!] invalid NFT_TABLE: %s\n' "$TABLE" >&2
    exit 1
}

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() {
    warn "$*"
    exit 1
}

# regex-first to avoid bash's name-based arithmetic substitution if $1 is non-numeric
_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535)); }

_valid_ipv4() {
    local IFS=. octets o
    read -ra octets <<<"$1"
    ((${#octets[@]} == 4)) || return 1
    for o in "${octets[@]}"; do
        # forbid leading zeros (inet_aton(3) interprets them as octal)
        [[ "$o" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
        ((o >= 0 && o <= 255)) || return 1
    done
}

# IFNAMSIZ - 1 = 15. Match what `iifname` parses cleanly: no `:` (alias),
# no `@` (kernel rename suffix in some tools). Reject `.` / `..` explicitly:
# they pass the regex AND the `[[ -d /sys/class/net/$name ]]` check
# (/sys/class/net/. = /sys/class/net/, /sys/class/net/.. = /sys/class/) but
# the kernel's dev_valid_name() rejects them, so `iifname "."` would silently
# match nothing.
_valid_ifname() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] && [[ "$1" != "." && "$1" != ".." ]]
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

strip_inline_comment() {
    local s="$1" out="" ch prev="" in_quote=0 i
    for ((i = 0; i < ${#s}; i++)); do
        ch="${s:i:1}"
        if [[ "$ch" == '"' && "$prev" != "\\" ]]; then
            if ((in_quote)); then
                in_quote=0
            else
                in_quote=1
            fi
        fi
        [[ "$ch" == "#" && $in_quote -eq 0 ]] && break
        out+="$ch"
        prev="$ch"
    done
    trim "$out"
}

parse_toml_value() {
    local raw
    raw="$(trim "$1")"
    # strict: forbid embedded `"` and trailing junk after the closing quote
    if [[ "$raw" =~ ^\"([^\"]*)\"$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf '%s' "$raw"
    else
        return 1
    fi
}

finish_port_rule() {
    [[ "${section:-}" == "port_rules" ]] || return 0
    [[ -n "${rule_protocol:-}" ]] || die "[[port_rules]] entry at $CONF:$rule_line missing protocol"
    [[ -n "${rule_target:-}" ]] || die "[[port_rules]] entry at $CONF:$rule_line missing target"
    [[ -n "${rule_ports:-}" ]] || die "[[port_rules]] entry at $CONF:$rule_line missing ports"
    _valid_ipv4 "$rule_target" ||
        die "[[port_rules]] entry at $CONF:$rule_line target must be IPv4 (octets 0-255): $rule_target"
    [[ "$rule_ports" =~ ^[0-9]+(-[0-9]+)?$ ]] ||
        die "[[port_rules]] entry at $CONF:$rule_line ports must be a port or range: $rule_ports"
    local p_start="${rule_ports%-*}" p_end="${rule_ports#*-}"
    if ! _valid_port "$p_start" || ! _valid_port "$p_end" || ((p_start > p_end)); then
        die "[[port_rules]] entry at $CONF:$rule_line ports must be 1-65535 with start <= end: $rule_ports"
    fi
    case "$rule_protocol" in
        tcp)
            TCP_ELEMS+=("$rule_ports : $rule_target")
            TCP_ELEM_LINES+=("$rule_line")
            ;;
        udp)
            UDP_ELEMS+=("$rule_ports : $rule_target")
            UDP_ELEM_LINES+=("$rule_line")
            ;;
        *) die "[[port_rules]] entry at $CONF:$rule_line protocol must be tcp or udp: $rule_protocol" ;;
    esac
}

# Reject overlapping intervals within the same protocol; nft -f - would
# otherwise fail with `conflicting intervals specified` and no source line.
check_port_overlaps() {
    local proto="$1"
    local -n elems="$2"
    local -n lines="$3"
    ((${#elems[@]} >= 2)) || return 0
    local i j a_start a_end b_start b_end pa pb
    for ((i = 0; i < ${#elems[@]}; i++)); do
        pa="${elems[i]%% : *}"
        a_start="${pa%-*}"
        a_end="${pa#*-}"
        for ((j = i + 1; j < ${#elems[@]}; j++)); do
            pb="${elems[j]%% : *}"
            b_start="${pb%-*}"
            b_end="${pb#*-}"
            if ((a_start <= b_end && b_start <= a_end)); then
                die "[[port_rules]] $proto intervals overlap: $CONF:${lines[i]} ($pa) vs $CONF:${lines[j]} ($pb)"
            fi
        done
    done
}

load_config() {
    local line_no=0 raw line key raw_value value next_section
    local section="" rule_protocol="" rule_target="" rule_ports="" rule_line=0

    WIREGUARD_INTERFACE=""
    WIREGUARD_PORT=""
    EXTERNAL_INTERFACE=""
    EXTERNAL_IP=""
    TUNING_CONNTRACK_MAX=""
    TUNING_CONNTRACK_HASHSIZE=""
    TUNING_RMEM_MAX=""
    TUNING_WMEM_MAX=""
    TUNING_NETDEV_MAX_BACKLOG=""
    TUNING_NETDEV_BUDGET=""
    TUNING_NETDEV_BUDGET_USECS=""
    TUNING_UDP_TIMEOUT=""
    TUNING_UDP_TIMEOUT_STREAM=""
    # -g: visible to finish_port_rule (caller scope) and later stages.
    declare -ga TCP_ELEMS=()
    declare -ga UDP_ELEMS=()
    declare -ga TCP_ELEM_LINES=()
    declare -ga UDP_ELEM_LINES=()

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line_no=$((line_no + 1))
        line="$(strip_inline_comment "$raw")"
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^\[\[([[:alnum:]_.-]+)\]\]$ ]]; then
            next_section="${BASH_REMATCH[1]}"
            finish_port_rule
            section="$next_section"
            [[ "$section" == "port_rules" ]] || die "unknown TOML array section at $CONF:$line_no: $section"
            rule_protocol=""
            rule_target=""
            rule_ports=""
            rule_line="$line_no"
            continue
        fi

        if [[ "$line" =~ ^\[([[:alnum:]_.-]+)\]$ ]]; then
            next_section="${BASH_REMATCH[1]}"
            finish_port_rule
            section="$next_section"
            case "$section" in
                wireguard | external | tuning) ;;
                *) die "unknown TOML section at $CONF:$line_no: $section" ;;
            esac
            continue
        fi

        [[ "$line" =~ ^([[:alpha:]_][[:alnum:]_-]*)[[:space:]]*=[[:space:]]*(.*)$ ]] ||
            die "invalid TOML line at $CONF:$line_no: $raw"

        key="${BASH_REMATCH[1]}"
        raw_value="${BASH_REMATCH[2]}"
        value="$(parse_toml_value "$raw_value")" ||
            die "invalid TOML value at $CONF:$line_no: $raw_value"

        case "$section:$key" in
            wireguard:interface) WIREGUARD_INTERFACE="$value" ;;
            wireguard:port) WIREGUARD_PORT="$value" ;;
            external:interface) EXTERNAL_INTERFACE="$value" ;;
            external:ip) EXTERNAL_IP="$value" ;;
            tuning:conntrack_max) TUNING_CONNTRACK_MAX="$value" ;;
            tuning:conntrack_hashsize) TUNING_CONNTRACK_HASHSIZE="$value" ;;
            tuning:rmem_max) TUNING_RMEM_MAX="$value" ;;
            tuning:wmem_max) TUNING_WMEM_MAX="$value" ;;
            tuning:netdev_max_backlog) TUNING_NETDEV_MAX_BACKLOG="$value" ;;
            tuning:netdev_budget) TUNING_NETDEV_BUDGET="$value" ;;
            tuning:netdev_budget_usecs) TUNING_NETDEV_BUDGET_USECS="$value" ;;
            tuning:udp_timeout) TUNING_UDP_TIMEOUT="$value" ;;
            tuning:udp_timeout_stream) TUNING_UDP_TIMEOUT_STREAM="$value" ;;
            port_rules:protocol) rule_protocol="$value" ;;
            port_rules:target) rule_target="$value" ;;
            port_rules:ports) rule_ports="$value" ;;
            :*) die "key outside TOML section at $CONF:$line_no: $key" ;;
            *) die "unknown TOML key at $CONF:$line_no: $section.$key" ;;
        esac
    done <"$CONF"

    finish_port_rule
    check_port_overlaps tcp TCP_ELEMS TCP_ELEM_LINES
    check_port_overlaps udp UDP_ELEMS UDP_ELEM_LINES
}

# nft iifname/oifname matches the exact kernel name; ip link show would
# also accept alias syntax (eth0:0). The format check also blocks
# path-traversal / quote-injection into nft heredocs.
check_iface() {
    local key="$1" name="$2"
    _valid_ifname "$name" ||
        die "$key '$name' has an invalid interface-name format (allowed: [A-Za-z0-9_.-], 1-15 chars)"
    [[ -d "/sys/class/net/$name" ]] ||
        die "$key '$name' is not a kernel network interface (run 'ip -br link' to see real names; address labels / aliases like 'eth0:0' are not interfaces)"
}

# NAT_LIB_MINIMAL=1 skips config + interface validation (teardown).
if [[ "${NAT_LIB_MINIMAL:-0}" != "1" ]]; then
    [[ -r "$CONF" ]] || die "cannot read $CONF"
    load_config

    [[ "${WIREGUARD_INTERFACE:-}" ]] || die "wireguard.interface not set in $CONF"
    [[ "${EXTERNAL_INTERFACE:-}" ]] || die "external.interface not set in $CONF"
    if ! [[ "${WIREGUARD_PORT:-}" =~ ^[0-9]+$ ]] || ! _valid_port "$WIREGUARD_PORT"; then
        die "wireguard.port must be 1-65535: ${WIREGUARD_PORT:-}"
    fi
    if [[ -n "${EXTERNAL_IP:-}" ]] && ! _valid_ipv4 "$EXTERNAL_IP"; then
        die "external.ip must be IPv4 (octets 0-255) or empty: ${EXTERNAL_IP}"
    fi

    check_iface wireguard.interface "$WIREGUARD_INTERFACE"
    check_iface external.interface "$EXTERNAL_INTERFACE"

    # [tuning] defaults: sized for a 1-core / 512 MB VPS. Override per-host.
    : "${TUNING_CONNTRACK_MAX:=32768}"
    : "${TUNING_CONNTRACK_HASHSIZE:=32768}"
    : "${TUNING_RMEM_MAX:=1048576}"
    : "${TUNING_WMEM_MAX:=1048576}"
    : "${TUNING_NETDEV_MAX_BACKLOG:=4096}"
    : "${TUNING_NETDEV_BUDGET:=300}"
    : "${TUNING_NETDEV_BUDGET_USECS:=2000}"
    : "${TUNING_UDP_TIMEOUT:=5}"
    : "${TUNING_UDP_TIMEOUT_STREAM:=120}"

    for k in TUNING_CONNTRACK_MAX TUNING_CONNTRACK_HASHSIZE \
        TUNING_RMEM_MAX TUNING_WMEM_MAX TUNING_NETDEV_MAX_BACKLOG \
        TUNING_NETDEV_BUDGET TUNING_NETDEV_BUDGET_USECS \
        TUNING_UDP_TIMEOUT TUNING_UDP_TIMEOUT_STREAM; do
        if ! [[ "${!k}" =~ ^[0-9]+$ ]] || ((${!k} <= 0)); then
            kn="${k#TUNING_}"
            die "tuning.${kn,,} must be a positive integer: ${!k}"
        fi
    done
fi

# --- helpers ---

join_csv() {
    local IFS=','
    echo "$*"
}

# Apply a sysctl; warn rather than die if the kernel doesn't expose it.
sset() {
    local key="$1" val="$2"
    sysctl -wq "$key=$val" 2>/dev/null || warn "$key not applied (kernel may not expose it)"
}

# Require root for stages that mutate kernel/network state.
require_root() {
    ((EUID == 0)) || die "must run as root (try: sudo $0)"
}

# Stage-wide hardening: fail-fast + ERR-trap with line number. Stages that
# intentionally collect failures (40-verify.sh) opt out and use `set -uo pipefail`.
strict_mode() {
    set -Eeuo pipefail
    trap 'die "stage failed at ${BASH_SOURCE[0]:-?}:${LINENO}"' ERR
}
