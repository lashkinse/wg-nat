#!/bin/bash
# Verify that apply-nat applied correctly. Writes a full report to $VERIFY_LOG
# (default /tmp/apply-nat-verify.log) AND to stdout. Exit 0 if no FAILs, 1
# otherwise; WARNs do not affect the exit code.

set -uo pipefail
umask 077

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

LOG="${VERIFY_LOG:-/tmp/apply-nat-verify.log}"

# install -m 0600 refuses to follow a symlink at the destination, closing the
# classic /tmp symlink-attack vector for root-run scripts.
install -m 0600 /dev/null "$LOG" 2>/dev/null || die "cannot create $LOG"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
INFO_COUNT=0

# Plain >> avoids forking `tee` per line (called 50+ times).
emit() {
    printf '%s\n' "$*" >>"$LOG"
    printf '%s\n' "$*"
}
pass() {
    emit "[PASS] $*"
    PASS_COUNT=$((PASS_COUNT + 1))
}
wrn() {
    emit "[WARN] $*"
    WARN_COUNT=$((WARN_COUNT + 1))
}
fl() {
    emit "[FAIL] $*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}
inf() {
    emit "[INFO] $*"
    INFO_COUNT=$((INFO_COUNT + 1))
}
hdr() {
    emit ""
    emit "=== $* ==="
}

# --- header ---
emit "=== apply-nat verification log ==="
emit "timestamp: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
emit "host:      $(hostname)"
emit "kernel:    $(uname -r)"
emit "uptime:    $(uptime -p 2>/dev/null || uptime)"
emit "config.toml: $CONF"
emit "nft table: inet $TABLE"

# --- environment ---
hdr "environment"

KREL="$(uname -r)"
K_MAJ="${KREL%%.*}"
K_REST="${KREL#*.}"
K_MIN="${K_REST%%[.-]*}"
if [[ "$K_MAJ" =~ ^[0-9]+$ ]] && [[ "$K_MIN" =~ ^[0-9]+$ ]]; then
    if ((K_MAJ > 5)) || { ((K_MAJ == 5)) && ((K_MIN >= 6)); }; then
        pass "kernel $KREL - NAT-aware flowtable supported"
    else
        wrn "kernel $KREL < 5.6 - flowtable will NOT offload NAT'd flows"
    fi
else
    wrn "cannot parse kernel version: $KREL"
fi

if command -v nft >/dev/null 2>&1; then
    pass "nftables installed: $(nft --version 2>&1 | head -1)"
else
    fl "nft binary not found"
fi

if command -v iptables >/dev/null 2>&1; then
    inf "iptables present: $(iptables --version 2>&1 | head -1)"
fi

# Modules autoload on demand, so a missing entry is only a soft signal.
lsmod_cache=$(lsmod 2>/dev/null | awk 'NR>1 {print $1}')
for mod in nf_conntrack nf_flow_table nf_flow_table_inet; do
    if grep -qx "$mod" <<<"$lsmod_cache"; then
        pass "module loaded: $mod"
    else
        wrn "module not loaded: $mod (autoloads on demand - only a concern if traffic isn't flowing)"
    fi
done

# --- interfaces ---
hdr "interfaces"
for iface in "$EXTERNAL_INTERFACE" "$WIREGUARD_INTERFACE"; do
    linfo=$(ip link show "$iface" 2>/dev/null | head -1) || true
    if [[ -z "$linfo" ]]; then
        fl "interface $iface not found"
        continue
    fi
    read -r state mtu < <(awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "state") s = $(i + 1)
            if ($i == "mtu") m = $(i + 1)
        }
        print s, m
    }' <<<"$linfo")
    if [[ "$state" == "UP" || "$state" == "UNKNOWN" ]]; then
        pass "interface $iface state=$state mtu=$mtu"
    else
        wrn "interface $iface state=$state (expected UP)"
    fi
done

# --- sysctl ---
hdr "sysctl"
check_sysctl() {
    local key="$1" expected="$2"
    local actual
    if ! actual=$(sysctl -n "$key" 2>/dev/null); then
        wrn "sysctl $key not readable (kernel may not expose it)"
        return
    fi
    if [[ "$actual" == "$expected" ]]; then
        pass "sysctl $key = $actual"
    else
        wrn "sysctl $key = $actual (expected $expected)"
    fi
}

check_sysctl net.ipv4.ip_forward 1
check_sysctl net.core.netdev_max_backlog "$TUNING_NETDEV_MAX_BACKLOG"
check_sysctl net.core.netdev_budget "$TUNING_NETDEV_BUDGET"
check_sysctl net.core.netdev_budget_usecs "$TUNING_NETDEV_BUDGET_USECS"
check_sysctl net.core.rmem_max "$TUNING_RMEM_MAX"
check_sysctl net.core.wmem_max "$TUNING_WMEM_MAX"
check_sysctl net.netfilter.nf_conntrack_max "$TUNING_CONNTRACK_MAX"
check_sysctl net.netfilter.nf_conntrack_udp_timeout "$TUNING_UDP_TIMEOUT"
check_sysctl net.netfilter.nf_conntrack_udp_timeout_stream "$TUNING_UDP_TIMEOUT_STREAM"
check_sysctl net.netfilter.nf_conntrack_acct 0
check_sysctl net.netfilter.nf_conntrack_timestamp 0
check_sysctl net.netfilter.nf_conntrack_helper 0

# --- NIC offloads ---
hdr "NIC offloads"
for iface in "$EXTERNAL_INTERFACE" "$WIREGUARD_INTERFACE"; do
    if ! features=$(ethtool -k "$iface" 2>/dev/null); then
        wrn "$iface: ethtool -k failed"
        continue
    fi
    while IFS=$'\t' read -r feat val; do
        [[ -z "$val" ]] && continue
        case "$val" in
            on) pass "$iface: $feat=on" ;;
            off) wrn "$iface: $feat=off (expected on for CPU reduction)" ;;
            *) inf "$iface: $feat=$val" ;;
        esac
    done < <(awk '
        /^generic-receive-offload:/ ||
        /^generic-segmentation-offload:/ ||
        /^tcp-segmentation-offload:/ {
            sub(":", "", $1); print $1 "\t" $2
        }' <<<"$features")
done

# --- nftables structure ---
hdr "nftables structure"
if ! nft list table inet "$TABLE" >/dev/null 2>&1; then
    fl "nft table 'inet $TABLE' not present - did apply-nat run?"
else
    pass "nft table 'inet $TABLE' present"

    for chain in raw_pre raw_out forward prerouting postrouting; do
        if nft list chain inet "$TABLE" "$chain" >/dev/null 2>&1; then
            pass "chain $chain present"
        else
            fl "chain $chain missing"
        fi
    done

    # Reused by both flowtable checks below.
    nft_ruleset=$(nft list ruleset 2>/dev/null)

    # flowtable definition
    if awk -v t="$TABLE" '
        $1=="table" && $3==t {in_t=1}
        in_t && /^}/ {in_t=0}
        in_t && /flowtable ft/ {found=1}
        END {exit !found}' <<<"$nft_ruleset"; then
        pass "flowtable ft defined in table"
    else
        fl "flowtable ft not defined"
    fi

    # flowtable devices
    if devs=$(awk -v t="$TABLE" '
        $1=="table" && $3==t {in_t=1}
        in_t && /^}/ {in_t=0}
        in_t && /devices =/ {print; exit}' <<<"$nft_ruleset"); then
        if [[ "$devs" == *"$EXTERNAL_INTERFACE"* && "$devs" == *"$WIREGUARD_INTERFACE"* ]]; then
            pass "flowtable devices include both $EXTERNAL_INTERFACE and $WIREGUARD_INTERFACE"
        else
            fl "flowtable devices missing one of {$EXTERNAL_INTERFACE,$WIREGUARD_INTERFACE}: $devs"
        fi
    fi

    # DNAT maps - element counts. `grep -o | wc -l` (not `grep -c`): GNU
    # grep silently ignores `-o` when `-c` is set, undercounting if nft
    # places multiple elements on one line.
    count_dnat_elems() {
        nft list map inet "$TABLE" "$1" 2>/dev/null |
            grep -oE '[0-9]+(-[0-9]+)? : [0-9.]+' | wc -l
    }
    if ((${#TCP_ELEMS[@]} > 0)); then
        tcp_count=$(count_dnat_elems dnat_tcp)
        if [[ "$tcp_count" == "${#TCP_ELEMS[@]}" ]]; then
            pass "map dnat_tcp: $tcp_count elements (matches config.toml)"
        else
            fl "map dnat_tcp: $tcp_count elements, expected ${#TCP_ELEMS[@]}"
        fi
    fi
    if ((${#UDP_ELEMS[@]} > 0)); then
        udp_count=$(count_dnat_elems dnat_udp)
        if [[ "$udp_count" == "${#UDP_ELEMS[@]}" ]]; then
            pass "map dnat_udp: $udp_count elements (matches config.toml)"
        else
            fl "map dnat_udp: $udp_count elements, expected ${#UDP_ELEMS[@]}"
        fi
    fi

    # prerouting DNAT rules
    pre=$(nft list chain inet "$TABLE" prerouting 2>/dev/null)
    ((${#TCP_ELEMS[@]} > 0)) && {
        if [[ "$pre" == *"dnat ip to tcp dport map @dnat_tcp"* ]]; then
            pass "prerouting: TCP DNAT via @dnat_tcp"
        else
            fl "prerouting: TCP DNAT rule missing"
        fi
    }
    ((${#UDP_ELEMS[@]} > 0)) && {
        if [[ "$pre" == *"dnat ip to udp dport map @dnat_udp"* ]]; then
            pass "prerouting: UDP DNAT via @dnat_udp"
        else
            fl "prerouting: UDP DNAT rule missing"
        fi
    }

    # postrouting SNAT/MASQUERADE
    post=$(nft list chain inet "$TABLE" postrouting 2>/dev/null)
    if [[ "$post" == *"oifname \"$EXTERNAL_INTERFACE\" masquerade"* ]]; then
        pass "postrouting: MASQUERADE on $EXTERNAL_INTERFACE"
    elif [[ "$post" =~ oifname[[:space:]]+\"$EXTERNAL_INTERFACE\"[[:space:]]+snat[[:space:]]+ip[[:space:]]+to[[:space:]]+([0-9.]+) ]]; then
        pass "postrouting: SNAT to ${BASH_REMATCH[1]} on $EXTERNAL_INTERFACE"
    else
        fl "postrouting: no MASQUERADE/SNAT rule for $EXTERNAL_INTERFACE"
    fi

    # NOTRACK on the WG transport port - now scoped by iifname.
    raw_pre=$(nft list chain inet "$TABLE" raw_pre 2>/dev/null)
    if [[ "$raw_pre" == *"iifname \"$EXTERNAL_INTERFACE\" udp dport $WIREGUARD_PORT notrack"* ]]; then
        pass "raw_pre: NOTRACK iifname=$EXTERNAL_INTERFACE udp dport $WIREGUARD_PORT"
    elif [[ "$raw_pre" == *"udp dport $WIREGUARD_PORT notrack"* ]]; then
        wrn "raw_pre: NOTRACK present but not iifname-scoped (apply 30-nftables.sh again)"
    else
        fl "raw_pre: NOTRACK rule missing for udp dport $WIREGUARD_PORT"
    fi

    # forward chain: flow add + MSS clamp
    fwd=$(nft list chain inet "$TABLE" forward 2>/dev/null)
    if [[ "$fwd" == *"flow add @ft"* ]]; then
        pass "forward: flow add @ft present"
        if [[ "$fwd" =~ ip[[:space:]]+protocol[[:space:]]+\{[[:space:]]*tcp,[[:space:]]*udp[[:space:]]*\}.*flow[[:space:]]+add[[:space:]]+@ft ]]; then
            fl "forward: TCP is being offloaded to flowtable (must use 'meta l4proto udp')"
        else
            pass "forward: TCP excluded from flowtable offload"
        fi
    else
        fl "forward: flow add @ft missing"
    fi
    if [[ "$fwd" == *"tcp option maxseg size set rt mtu"* ]]; then
        pass "forward: TCP MSS clamp present"
    else
        wrn "forward: TCP MSS clamp missing"
    fi
fi

# --- legacy iptables conflicts ---
hdr "legacy iptables rules"
if command -v iptables >/dev/null 2>&1; then
    for tbl in filter nat mangle raw; do
        rules=$(iptables -t "$tbl" -S 2>/dev/null | grep -vE '^-[PN] ')
        if [[ -n "$rules" ]]; then
            lines=$(wc -l <<<"$rules")
            wrn "iptables -t $tbl: $lines user rule(s) present - may conflict with nftables"
            # shellcheck disable=SC2001 # bash ${var//re/repl} can't prefix every line of a multi-line string.
            sed 's/^/    /' <<<"$rules" >>"$LOG"
        else
            pass "iptables -t $tbl: no user rules"
        fi
    done
fi

# --- runtime state ---
hdr "runtime state"

ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo N/A)
ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo N/A)
inf "conntrack: $ct_count / $ct_max"

# flowtable offload entries via conntrack OFFLOAD state.
if command -v conntrack >/dev/null 2>&1; then
    offload_count=$(conntrack -L 2>/dev/null | awk '/OFFLOAD/ {c++} END {print c+0}')
    if ((offload_count > 0)); then
        pass "conntrack: $offload_count flows marked OFFLOAD (flowtable is working)"
    else
        wrn "conntrack: 0 flows marked OFFLOAD (either no traffic, or offload not kicking in)"
    fi
else
    inf "conntrack(8) not installed - skipped OFFLOAD count"
fi

# Interface byte counters snapshot
for iface in "$EXTERNAL_INTERFACE" "$WIREGUARD_INTERFACE"; do
    emit ""
    emit "--- ip -s link show $iface ---"
    ip_out=$(ip -s link show "$iface" 2>/dev/null)
    printf '%s\n' "$ip_out" >>"$LOG"
    printf '%s\n' "$ip_out" | sed 's/^/  /'
done

# CPU / softirq snapshot (1 second sample, /proc fallback if no mpstat).
if command -v mpstat >/dev/null 2>&1; then
    emit ""
    emit "--- mpstat -P ALL 1 1 ---"
    mpstat -P ALL 1 1 2>/dev/null | tee -a "$LOG"
else
    emit ""
    emit "--- /proc/softirqs (top lines) ---"
    head -20 /proc/softirqs | tee -a "$LOG"
fi

# --- summary ---
hdr "summary"
emit "PASS: $PASS_COUNT"
emit "WARN: $WARN_COUNT"
emit "FAIL: $FAIL_COUNT"
emit "INFO: $INFO_COUNT"
emit "full log: $LOG"

if ((FAIL_COUNT > 0)); then
    exit 1
fi
exit 0
