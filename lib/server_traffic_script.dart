/// Port counters are explicitly enabled by the user, never by a status read.
/// Their input/output hooks have no allow/drop/NAT rules.
String serverTrafficConfigureCommand({
  required String sshPorts,
  required String hy2Ports,
}) {
  return (_trafficSetupPrelude +
          r'''
expected_prefix='pso-traffic-v1|ssh=__SSH_PORTS__|hy2=__HY2_PORTS__|id='
case "$traffic_comment" in
  "$expected_prefix"*) exit 0 ;;
esac
traffic_generation=$(cat /proc/sys/kernel/random/uuid) || exit 1
[ -n "$traffic_generation" ] || exit 1
traffic_delete=''
[ -n "$traffic_existing" ] && traffic_delete='delete table inet pocket_server_ops_traffic'
nft -f - <<PSO_TRAFFIC_RULES
$traffic_delete
table inet pocket_server_ops_traffic {
  comment "$expected_prefix$traffic_generation"
  counter ssh_rx { packets 0 bytes 0; }
  counter ssh_tx { packets 0 bytes 0; }
  counter hy2_rx { packets 0 bytes 0; }
  counter hy2_tx { packets 0 bytes 0; }
  chain input {
    type filter hook input priority 10; policy accept;
    iifname != "lo" tcp dport { __SSH_PORTS__ } counter name ssh_rx
    iifname != "lo" udp dport { __HY2_PORTS__ } counter name hy2_rx
  }
  chain output {
    type filter hook output priority 10; policy accept;
    oifname != "lo" tcp sport { __SSH_PORTS__ } counter name ssh_tx
    oifname != "lo" udp sport { __HY2_PORTS__ } counter name hy2_tx
  }
}
PSO_TRAFFIC_RULES
''')
      .replaceAll('__SSH_PORTS__', normalizeTrafficPorts(sshPorts))
      .replaceAll('__HY2_PORTS__', normalizeTrafficPorts(hy2Ports));
}

String normalizeTrafficPorts(String value) {
  final ports = <int>{};
  for (final item in value.split(',')) {
    final text = item.trim();
    final port = int.tryParse(text);
    if (!RegExp(r'^[0-9]+$').hasMatch(text) ||
        port == null ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('请输入 1–65535 的端口，多个端口用英文逗号分隔');
    }
    ports.add(port);
  }
  return (ports.toList()..sort()).join(',');
}

const _trafficSetupPrelude = r'''set -e
command -v nft >/dev/null 2>&1 || {
  printf '%s\n' '服务器未安装 nftables' >&2
  exit 1
}
# Check access separately so a permissions failure isn't mistaken for absence.
nft list tables >/dev/null
traffic_existing=$(nft -s list table inet pocket_server_ops_traffic 2>/dev/null || :)
traffic_comment=$(printf '%s\n' "$traffic_existing" | awk '$1 == "comment" {gsub(/^"|"$/, "", $2); print $2; exit}')
if [ -n "$traffic_existing" ]; then
  case "$traffic_comment" in
    pso-traffic-v1\|*) ;;
    *) printf '%s\n' '同名表不属于 APP，未修改；请更换该表名称后重试' >&2; exit 1 ;;
  esac
fi
''';

const serverTrafficDisableCommand =
    _trafficSetupPrelude +
    r'''
if [ -n "$traffic_existing" ]; then
  nft delete table inet pocket_server_ops_traffic
fi
''';

// Run as a subshell after the existing dashboard probe, on the same SSH call.
// Failure of this optional metric must not hide CPU/memory/disk information.
const serverTrafficProbeCommand = r'''(
traffic_ssh_ports=$(ss -Hltnp 2>/dev/null | awk '/"sshd"/ {address=$4; sub(/^.*:/, "", address); if (address ~ /^[0-9]+$/) print address}' | sort -nu | paste -sd, -)
[ -n "$traffic_ssh_ports" ] || traffic_ssh_ports=$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $4}')
printf 'traffic_ssh_hint=%s\n' "$traffic_ssh_ports"
# A Hysteria process also owns outbound UDP sockets. Only suggest a server's
# configured listen port, never every UDP socket seen in ss.
traffic_hy2_ports=$(
  for traffic_pid in $(pgrep -x hysteria 2>/dev/null); do
    traffic_config=$(tr '\000' '\n' < "/proc/$traffic_pid/cmdline" 2>/dev/null | awk '
      want {config=$0; want=0; next}
      $0 == "server" {server=1}
      $0 == "-c" || $0 == "--config" {want=1}
      /^--config=/ {config=substr($0, 10)}
      END {if (server) print config}
    ')
    [ -n "$traffic_config" ] || continue
    case "$traffic_config" in
      /*) ;;
      *) traffic_config="/proc/$traffic_pid/cwd/$traffic_config" ;;
    esac
    [ -r "$traffic_config" ] || continue
    awk '/^listen:[[:space:]]*/ {
      sub(/^listen:[[:space:]]*/, "")
      sub(/[[:space:]]+#.*$/, "")
      sub(/[[:space:]]+$/, "")
      quote=sprintf("%c", 39)
      if ((substr($0,1,1) == "\"" && substr($0,length,1) == "\"") ||
          (substr($0,1,1) == quote && substr($0,length,1) == quote))
        $0=substr($0,2,length-2)
      sub(/^.*:/, "")
      if ($0 ~ /^[0-9]+$/ && $0+0 > 0 && $0+0 <= 65535) print $0+0
      exit
    }' "$traffic_config"
  done
)
printf 'traffic_hy2_hint=%s\n' "$(printf '%s\n' "$traffic_hy2_ports" | sort -nu | paste -sd, -)"
if ! command -v nft >/dev/null 2>&1; then
  printf 'traffic_status=unsupported\n'
  exit 0
fi
# nft 1.0.6 omits table comments from JSON. Read the text metadata with a
# table handle, so the phone can verify it belongs to the same JSON snapshot.
traffic_table_metadata() {
  nft -a -s list table inet pocket_server_ops_traffic 2>/dev/null | awk '
    NR == 1 {for (i=1; i<NF; i++) if ($i == "handle") handle=$(i+1)}
    $1 == "comment" {gsub(/^"|"$/, "", $2); print handle "|" $2; exit}
  '
}
traffic_meta_before=$(traffic_table_metadata)
traffic_before=$(nft -j list table inet pocket_server_ops_traffic 2>/dev/null)
if [ "$?" != 0 ]; then
  if nft list tables >/dev/null 2>&1; then
    printf 'traffic_status=not_enabled\n'
  else
    printf 'traffic_status=unavailable\n'
  fi
  exit 0
fi
traffic_time_before=$(awk '{print $1}' /proc/uptime)
sleep 0.2
traffic_meta_after=$(traffic_table_metadata)
traffic_after=$(nft -j list table inet pocket_server_ops_traffic 2>/dev/null)
if [ "$?" != 0 ]; then
  printf 'traffic_status=unavailable\n'
  exit 0
fi
traffic_time_after=$(awk '{print $1}' /proc/uptime)
printf 'traffic_status=ready\n'
printf 'traffic_meta_before=%s\n' "$traffic_meta_before"
printf 'traffic_meta_after=%s\n' "$traffic_meta_after"
printf 'traffic_time_before=%s\n' "$traffic_time_before"
printf 'traffic_time_after=%s\n' "$traffic_time_after"
printf 'traffic_before=%s\n' "$(printf '%s' "$traffic_before" | tr '\r\n' '  ')"
printf 'traffic_after=%s\n' "$(printf '%s' "$traffic_after" | tr '\r\n' '  ')"
exit 0
)
''';
