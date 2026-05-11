# tun-nat - nftables NAT/forwarding for any tunnel interface

TOML-configured nftables NAT with software flowtable offload, O(1) DNAT
interval maps, and conntrack/NIC tuning split into numbered stages.

Forwarding only - no anti-spoof, no rate limiting, no SYN-flood/conntrack-flood
mitigation, no `ct invalid` cleanup. Host-level filtering and edge protection
live in a separate project.

## Layout

```
/etc/tun-nat/
├── config.toml           # TOML config
├── apply-nat.sh          # orchestrator
└── nat.d/
    ├── lib.sh                # config loader + validation + helpers
    ├── 10-sysctl.sh          # ip_forward + conntrack/socket tuning
    ├── 20-nic.sh             # ethtool offloads (GRO/GSO/TSO)
    ├── 30-nftables.sh        # nft ruleset (flowtable + DNAT maps)
    ├── 40-verify.sh          # post-apply verification + log
    └── 99-teardown.sh        # remove nft table
```

Stages are numbered so you can drop in additional ones (`25-foo.sh`, etc.)
and they will run in order if you wire them into the orchestrator.

## Usage

```bash
# full apply (sysctl + nic + nftables)
sudo /etc/tun-nat/apply-nat.sh

# only one stage (debug / re-tune without touching the rest)
sudo /etc/tun-nat/apply-nat.sh --only sysctl
sudo /etc/tun-nat/apply-nat.sh --only nic
sudo /etc/tun-nat/apply-nat.sh --only nftables

# point at a non-default config / table without exporting env vars
sudo /etc/tun-nat/apply-nat.sh --config /etc/tun-nat/lab.toml --table tun_nat_lab

# verify that everything applied correctly; writes full report to $VERIFY_LOG
# (default /tmp/apply-nat-verify.log). Exit 0 if no FAILs, 1 otherwise.
sudo /etc/tun-nat/apply-nat.sh --verify
sudo VERIFY_LOG=/var/log/apply-nat-verify.log /etc/tun-nat/apply-nat.sh --verify

# remove the nft table (sysctl is not reverted - resets on reboot)
sudo /etc/tun-nat/apply-nat.sh --down

# also: each stage can be invoked directly
sudo /etc/tun-nat/nat.d/30-nftables.sh
sudo /etc/tun-nat/nat.d/40-verify.sh
```

## Environment

| var          | default                       | meaning                                       |
| ------------ | ----------------------------- | --------------------------------------------- |
| `NAT_CONF`   | `/etc/tun-nat/config.toml`   | path to config (overridden by `--config`)     |
| `NFT_TABLE`  | `tun_nat`                    | nftables table name (overridden by `--table`) |
| `VERIFY_LOG` | `/tmp/apply-nat-verify.log` | path for the `--verify` log                   |

## config.toml

```toml
[tunnel]
interface = "wg0"
port = 51820

[external]
interface = "eth0"
ip = "203.0.113.10" # empty string for dynamic IP / MASQUERADE

[[port_rules]]
protocol = "udp"
target = "10.66.66.2"
ports = "27015-27050"

[[port_rules]]
protocol = "tcp"
target = "10.66.66.2"
ports = "27015-27050"

[tuning]
conntrack_max          = 32768
conntrack_hashsize     = 32768
rmem_max               = 1048576
wmem_max               = 1048576
netdev_max_backlog     = 4096
netdev_budget          = 300
netdev_budget_usecs    = 2000
udp_timeout            = 5
udp_timeout_stream     = 120
```

The parser in `lib.sh` is pure bash and accepts only what this project
uses: `[section]` and `[[array.section]]` headers, single-line
`key = value` pairs (int or double-quoted string, no escapes), and `#`
comments. Anything else (dotted keys, multi-line strings, inline
tables, arrays) needs a real TOML parser - swap it out if you need it.

### Parameters

`[tunnel]` - describes the tunnel interface on this host (WireGuard, AmneziaWG, OpenVPN tun, GRE, etc.):

| key         | type   | meaning                                                                                                               |
| ----------- | ------ | --------------------------------------------------------------------------------------------------------------------- |
| `interface` | string | tunnel interface name (e.g. `wg0`). Must exist when apply-nat runs.                                                   |
| `port`      | int    | UDP port the tunnel transport listens on. Added to the nft `notrack` rule so tunnel traffic doesn't burn conntrack slots. |

`[external]` - the WAN-facing interface packets arrive on:

| key         | type   | meaning                                                                                            |
| ----------- | ------ | -------------------------------------------------------------------------------------------------- |
| `interface` | string | external interface (e.g. `eth0`). Used as `iifname` for DNAT and as `oifname` for SNAT/MASQUERADE. |
| `ip`        | string | static external IPv4 for SNAT. Leave empty (`""`) to fall back to MASQUERADE (dynamic IP).         |

`[[port_rules]]` - one entry per forwarded range, compiled into O(1) nft interval maps:

| key        | type   | meaning                                          |
| ---------- | ------ | ------------------------------------------------ |
| `protocol` | string | `tcp` or `udp`.                                  |
| `target`   | string | IPv4 to DNAT to (typically a tunnel peer address). |
| `ports`    | string | single port (`27015`) or range (`27015-27050`).  |

`[tuning]` - kernel/conntrack/socket-buffer knobs read by `10-sysctl.sh`.
Defaults are sized for a 1-core / 512 MB VPS; bump them up on bigger hosts.
Values are validated as positive integers.

| key                  | default   | meaning                                                                                                                                                                                  |
| -------------------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `conntrack_max`      | `32768`   | `nf_conntrack_max`. ~13 MB worst case (×~400 B per entry).                                                                                                                               |
| `conntrack_hashsize` | `32768`   | `nf_conntrack` hashsize - written at apply time via `/sys/module/nf_conntrack/parameters/hashsize`, not persisted as a boot sysctl. 1:1 with `conntrack_max` keeps hash chains shortest. |
| `rmem_max`           | `1048576` | `net.core.rmem_max` - max per-socket recv buffer (1 MB).                                                                                                                                 |
| `wmem_max`           | `1048576` | `net.core.wmem_max` - max per-socket send buffer (1 MB).                                                                                                                                 |
| `netdev_max_backlog` | `4096`    | `net.core.netdev_max_backlog` - per-CPU input queue depth.                                                                                                                               |
| `netdev_budget`      | `300`     | `net.core.netdev_budget` - max packets per softirq NAPI poll cycle. Matches the kernel default; raising it trades userspace tail-latency for fewer softirq->ksoftirqd reschedules under high PPS. See [When to raise](#when-to-raise-netdev_budget--netdev_budget_usecs) below. |
| `netdev_budget_usecs` | `2000`    | `net.core.netdev_budget_usecs` - max usecs per softirq NAPI poll cycle. Matches the kernel default; same trade-off as above, time-bounded.                                                |
| `udp_timeout`        | `5`       | `nf_conntrack_udp_timeout`. Short on purpose - kill unanswered records (scans, dead handshakes) fast.                                                                                    |
| `udp_timeout_stream` | `120`     | `nf_conntrack_udp_timeout_stream`. Kernel default; long enough to survive sparse-keepalive phases (lobbies, loading) without rebuilding the flowtable mapping.                           |

`10-sysctl.sh` also turns off `nf_conntrack_acct`, `nf_conntrack_timestamp`,
and `nf_conntrack_helper` (pure per-flow memory savings, no behaviour change).

### Kernel auto-defaults

For reference, here is what a stock Linux kernel would set on its own
without `10-sysctl.sh` running, alongside what we set instead:

| key                                             | kernel default                | this project | why we override                                                                                |
| ----------------------------------------------- | ----------------------------- | ------------ | ---------------------------------------------------------------------------------------------- |
| `net.ipv4.ip_forward`                           | `0`                           | `1`          | Mandatory - NAT/forward cannot work without it.                                                |
| `net.core.rmem_max`                             | `212992` (208 KB)             | `1048576`    | Bigger per-socket recv buffer cap so the tunnel keeps up under bursty load.                 |
| `net.core.wmem_max`                             | `212992` (208 KB)             | `1048576`    | Same for send.                                                                                 |
| `net.core.netdev_max_backlog`                   | `1000`                        | `4096`       | Avoid drops on a single softirq CPU during traffic peaks.                                      |
| `net.netfilter.nf_conntrack_max`                | RAM-scaled (~8-16k on 512 MB) | `32768`      | Pin a predictable cap with 2-4x headroom over the auto-sized default.                          |
| `nf_conntrack` hashsize                         | `nf_conntrack_max / 4`        | `32768`      | 1:1 ratio for the shortest hash chains; ~512 KB hashtable is trivial here.                     |
| `net.netfilter.nf_conntrack_udp_timeout`        | `30`                          | `5`          | Game UDP churns fast - drop dead flows aggressively to free conntrack slots.                   |
| `net.netfilter.nf_conntrack_acct`               | `0`                           | `0`          | Already off - we just keep it that way for memory savings.                                     |
| `net.netfilter.nf_conntrack_timestamp`          | `0`                           | `0`          | Same.                                                                                          |
| `net.netfilter.nf_conntrack_helper`             | `0`                           | `0`          | Same.                                                                                          |

### Sizing presets

The `[tuning]` defaults are sized for a 1-vCPU / 512 MB VPS. Bigger hosts
can lift the memory-bound knobs proportionally. None of these numbers
need to be exact - they are starting points; bump and re-measure under
your actual peak load.

The knobs split into three groups:

- **RAM-bound** (drive from host RAM): `conntrack_max`,
  `conntrack_hashsize`, `rmem_max`, `wmem_max`, `netdev_max_backlog`.
- **Workload-bound** (don't scale with hardware): `udp_timeout` stays
  short (kill dead one-way records fast); `udp_timeout_stream` stays
  at the kernel default so quiet phases don't drop the flowtable
  mapping.
- **Leave alone**: `netdev_budget` / `netdev_budget_usecs` are caps,
  not targets - raising them only helps once NAPI actually hits them,
  and at the cost of softirq tail-latency. See
  [When to raise](#when-to-raise-netdev_budget--netdev_budget_usecs).

#### By RAM

| host RAM | `conntrack_max` | `conntrack_hashsize` | `rmem_max` / `wmem_max` | `netdev_max_backlog` |
| -------- | --------------- | -------------------- | ----------------------- | -------------------- |
| 512 MB   | `32768`         | `32768`              | `1048576` (1 MB)        | `4096`               |
| 1 GB     | `65536`         | `65536`              | `2097152` (2 MB)        | `8192`               |
| 2 GB     | `131072`        | `131072`             | `4194304` (4 MB)        | `16384`              |

Worst-case `nf_conntrack` memory ≈ `conntrack_max × ~400 B` for entries
plus `conntrack_hashsize × 16 B` for the hashtable (~50 MB at the 2 GB
row). `rmem_max` / `wmem_max` are caps, not allocations - lifting them
on a big host costs nothing until an app actually asks for the buffer.

#### When to raise `netdev_budget` / `netdev_budget_usecs`

These are caps on a single NAPI poll cycle. If your PPS never makes
NAPI hit them, raising them changes nothing. If it *does*, raising
them trades userspace tail-latency for fewer
softirq->ksoftirqd reschedules - usually the wrong trade on a
latency-sensitive game forwarder.

Use `/proc/net/softnet_stat` (one row per CPU, hex columns) as
evidence: column 1 = packets processed, column 2 = dropped (backlog
overflow - bump `netdev_max_backlog`), column 3 = `time_squeeze`
(NAPI hit the cap and bailed). If column 3 grows steadily under
load, try `600 / 4000` and re-measure. Past `1500 / 20000` you start
hurting userspace latency on non-dedicated cores.

#### Combined presets

`netdev_budget` / `netdev_budget_usecs` keep their kernel defaults
in every preset; raise them only on `time_squeeze` evidence.

**512 MB / 1 vCPU** (shipped default):

```toml
[tuning]
conntrack_max          = 32768
conntrack_hashsize     = 32768
rmem_max               = 1048576
wmem_max               = 1048576
netdev_max_backlog     = 4096
netdev_budget          = 300
netdev_budget_usecs    = 2000
udp_timeout            = 5
udp_timeout_stream     = 120
```

**1 GB / 2 vCPU**:

```toml
[tuning]
conntrack_max          = 65536
conntrack_hashsize     = 65536
rmem_max               = 2097152
wmem_max               = 2097152
netdev_max_backlog     = 8192
netdev_budget          = 300
netdev_budget_usecs    = 2000
udp_timeout            = 5
udp_timeout_stream     = 120
```

**2 GB / 3 - 4 vCPU**:

```toml
[tuning]
conntrack_max          = 131072
conntrack_hashsize     = 131072
rmem_max               = 4194304
wmem_max               = 4194304
netdev_max_backlog     = 16384
netdev_budget          = 300
netdev_budget_usecs    = 2000
udp_timeout            = 5
udp_timeout_stream     = 120
```

#### Scaling further

Past 2 GB / 4 vCPU, the rough rules of thumb:

- **`conntrack_max` / `conntrack_hashsize`**: keep them 1:1, double per
  doubling of RAM, then cap at your actual peak number of concurrent
  flows + ~50% headroom. Read the live count under load via
  `cat /proc/sys/net/netfilter/nf_conntrack_count` and size from there.
  Past 256k-512k entries the hashtable starts taking real memory; on a
  forwarder with notrack on the tunnel transport port and flowtable on the
  hot path, you rarely need more than 128k.
- **`rmem_max` / `wmem_max`**: these caps mostly affect TCP applications
  running *on* the box (sshd, monitoring, etc.), not forwarded traffic
  - flowtable and DNAT'd flows don't allocate per-socket buffers. Stop
  bumping at 4-8 MB; further increases buy nothing on a pure NAT host.
- **`netdev_max_backlog`**: scale with your peak per-CPU PPS - rule of
  thumb is `≥ peak_pps_per_cpu × 2 ms` plus a comfortable cushion for
  bursts. For practical purposes 16k - 32k covers most workloads.
- **`netdev_budget` / `netdev_budget_usecs`**: don't bump these on
  spec - bump them on evidence (`time_squeeze` in
  `/proc/net/softnet_stat`). See [When to raise](#when-to-raise-netdev_budget--netdev_budget_usecs).
- **`udp_timeout` / `udp_timeout_stream`**: don't change with hardware.
  Lower `udp_timeout` only if `nf_conntrack: table full` despite a
  high `conntrack_max`. Keep `udp_timeout_stream` at the kernel
  default (`120`); lowering it drops the flowtable mapping during
  quiet phases.

For anything past 4 vCPU / 4 GB, also enable multi-queue virtio (or
your NIC's equivalent), pin `eth0` RX-IRQ + the tunnel kernel
workqueue to specific CPUs, and consider XDP for the DNAT fast path.
Those changes live outside `config.toml`.

## nftables ruleset

`30-nftables.sh` (re)creates `inet $NFT_TABLE` atomically with:

- `raw_pre` / `raw_out` - `notrack` on the tunnel transport port so the tunnel
  itself does not allocate conntrack slots.
- `prerouting` (dstnat) - DNAT incoming game ports from `external.interface`
  to tunnel peer IPs via `dnat_tcp` / `dnat_udp` interval maps (O(1)
  match on `dport`).
- `postrouting` (srcnat) - `MASQUERADE` on `external.interface`, or static
  `SNAT` to `external.ip` when set.
- `forward` - TCP MSS clamp to PMTU; established UDP flows get pushed into
  `flowtable ft`. TCP is intentionally not offloaded (offload bypasses
  conntrack state machine which TCP needs for MSS clamp / RST handling).
  The clamp rule is **not** scoped by `iifname`/`oifname`, so it applies to
  every TCP flow forwarded by this host. `set rt mtu` derives the cap from
  the egress route per packet, which is correct on multi-interface hosts;
  scope it down explicitly if you ever need a non-default behaviour.
- `flowtable ft` - software fast path bound to both
  `external.interface` and `tunnel.interface` so established UDP NAT'd
  flows skip the full netfilter walk.

This project is IPv4-only: `[[port_rules]].target` is an IPv4 address and
the nft maps use `ipv4_addr`. IPv6 forwarding/NAT needs a separate design.

## Requirements

- Ubuntu **24+** target platform.
- nftables **≥ 0.9.6**.
- Kernel modules: `nf_conntrack`, `nf_nat`, `nf_flow_table`,
  `nf_flow_table_inet`, and nftables modules.
- Kernel **≥ 5.6** for NAT-aware flowtable offload.

## Firewalls (UFW / firewalld)

`apply-nat.sh` only manages its own `inet $NFT_TABLE` table: DNAT, SNAT,
flowtable, MSS clamp. It does **not** filter the host itself and it cannot
override a filter-`FORWARD DROP` policy installed by another tool - when
two chains are attached to the same hook (e.g. UFW's filter forward and
your own), a packet has to be accepted by **both** for it to pass.

Practical consequence: if UFW / firewalld / any host firewall defaults to
`DEFAULT_FORWARD_POLICY=DROP` (UFW's default), DNAT'd packets get rewritten
in `prerouting` and then dropped in `forward` before they leave via the tunnel
interface. Symptoms: `tcpdump` on the external interface sees the `SYN`,
`tcpdump` on the tunnel interface sees nothing, no `conntrack` entry appears.

### UFW

Add an explicit transit rule for both directions and keep the tunnel transport
port open on the host:

```bash
# inbound port-forward traffic (external -> tunnel peers)
sudo ufw route allow in on <external> out on <tunnel>
# tunnel clients using the VPS as an internet gateway (tunnel peers -> external)
sudo ufw route allow in on <tunnel> out on <external>
# tunnel transport itself
sudo ufw allow <tunnel_port>/udp
sudo ufw reload
```

For the example `config.toml` in this README (`external.interface = "eth0"`,
`tunnel.interface = "wg0"`, `tunnel.port = 51820`):

```bash
sudo ufw route allow in on eth0 out on wg0
sudo ufw route allow in on wg0 out on eth0
sudo ufw allow 51820/udp
sudo ufw reload
```

You do **not** need `ufw allow <port>/<proto>` for any port listed in
`[[port_rules]]`. DNAT happens in `prerouting`, the packet then goes to
`forward` (not `input`), so UFW's INPUT rules never see it. Adding them is
harmless but misleading.

The reverse direction of an established port-forward is auto-allowed by the
`ufw-before-forward` chain via `-m conntrack --ctstate RELATED,ESTABLISHED`,
so you don't need a separate "wg0 -> eth0" rule just for return traffic.
Add it only if tunnel peers should be able to initiate **new** outbound
connections to the internet through this host.

### firewalld

Add the external and tunnel interfaces to a zone with masquerading/forwarding
or add direct forward rules equivalent to the UFW commands above. `apply-nat`
doesn't interact with firewalld zones automatically.

## Hooking into your tunnel

If you want the NAT/forwarding rules to come up and go down with the tunnel,
hook `apply-nat.sh` from the tunnel interface config. Use `PostUp` (the tunnel
interface already exists when it fires - `lib.sh` validates that) and
`PreDown` (still exists at this point, so `--down` can clean up the table).
Avoid `PostDown`: by then `$TUNNEL_INTERFACE` is gone and the validation
in `lib.sh` will refuse to run.

### WireGuard / AmneziaWG (wg-quick)

For `wg-quick`, in `/etc/wireguard/wg0.conf` (or `/etc/amnezia/amneziawg/awg0.conf`), under `[Interface]`:

```ini
[Interface]
# ...
PostUp  = /etc/tun-nat/apply-nat.sh
PreDown = /etc/tun-nat/apply-nat.sh --down
```

Bring it up:

```bash
sudo wg-quick down wg0 || true
sudo wg-quick up wg0
sudo /etc/tun-nat/apply-nat.sh --verify
```

Prefer a systemd unit instead? Bind it to the tunnel:

```ini
# /etc/systemd/system/tun-nat.service
[Unit]
Description=tun-nat for wg0
After=wg-quick@wg0.service
BindsTo=wg-quick@wg0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/tun-nat/apply-nat.sh
ExecStop=/etc/tun-nat/apply-nat.sh --down

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now tun-nat.service
```

Both paths are safe to combine with manual runs of `apply-nat.sh`: each stage
is idempotent and the nftables table is recreated atomically.

## License

MIT - see [LICENSE](LICENSE).