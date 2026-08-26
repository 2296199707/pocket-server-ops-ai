const statusScriptBody = r'''#!/bin/sh
set +e

clean_value() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

hostname_value=$(hostname 2>/dev/null | head -n 1)
os_value=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -n 1 | sed 's/^"//;s/"$//')
[ -n "$os_value" ] || os_value=$(uname -s 2>/dev/null)
kernel_value=$(uname -sr 2>/dev/null)
uptime_value=$(uptime -p 2>/dev/null | head -n 1)
[ -n "$uptime_value" ] || uptime_value=$(uptime 2>/dev/null | head -n 1)
cpu_value=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
[ -n "$cpu_value" ] || cpu_value=$(nproc 2>/dev/null)
memory_value=$(awk '/MemTotal:/ {total=$2} /MemAvailable:/ {available=$2} END {if (total) printf "%.0f%% (%d/%d MiB)", (total-available)*100/total, (total-available)/1024, total/1024}' /proc/meminfo 2>/dev/null)
disk_value=$(df -P -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')
load_value=$(awk '{print $1 " " $2 " " $3}' /proc/loadavg 2>/dev/null)
disk_details_value=$(df -P -h 2>/dev/null | awk 'NR > 1 && $6 ~ /^\// {gsub("%", "", $5); printf "%s|%s|%s|%s|%s;", $6, $2, $3, $4, $5}')
network_value=$(awk 'NR > 2 {name=$1; sub(/:/, "", name); if (name != "lo") {iface=name; rx += $2; tx += $10}} END {if (iface != "") printf "%s|%.0f|%.0f", iface, rx, tx}' /proc/net/dev 2>/dev/null)
process_value=$(ps -e 2>/dev/null | awk 'NR > 1 {count++} END {print count + 0}')
cpu_snapshot() {
  awk 'NR == 1 && $1 == "cpu" {print ($2+$3+$4+$5+$6+$7+$8+$9+$10), ($5+$6); exit}' /proc/stat 2>/dev/null
}
cpu_before=$(cpu_snapshot)
sleep 0.2
cpu_after=$(cpu_snapshot)
cpu_usage=$(awk -v first="$cpu_before" -v second="$cpu_after" 'BEGIN {
  first_count = split(first, first_values, " ")
  second_count = split(second, second_values, " ")
  total = second_values[1] - first_values[1]
  idle = second_values[2] - first_values[2]
  if (first_count >= 2 && second_count >= 2 && total > 0) {
    value = (total - idle) * 100 / total
    if (value < 0) value = 0
    if (value > 100) value = 100
    printf "%.0f", value
  }
}')

printf 'script_version=1\n'
printf 'hostname=%s\n' "$(clean_value "$hostname_value")"
printf 'os=%s\n' "$(clean_value "$os_value")"
printf 'kernel=%s\n' "$(clean_value "$kernel_value")"
printf 'uptime=%s\n' "$(clean_value "$uptime_value")"
printf 'load=%s\n' "$(clean_value "$load_value")"
printf 'cpu=%s cores\n' "$(clean_value "$cpu_value")"
printf 'cpu_usage=%s\n' "$(clean_value "$cpu_usage")"
printf 'memory=%s\n' "$(clean_value "$memory_value")"
printf 'disk=%s\n' "$(clean_value "$disk_value")"
printf 'disk_details=%s\n' "$(clean_value "$disk_details_value")"
printf 'network=%s\n' "$(clean_value "$network_value")"
printf 'processes=%s\n' "$(clean_value "$process_value")"
''';

const statusProbeCommand =
    r'''if [ -x "$HOME/.local/bin/mobile-agent-status" ]; then
  status_output=$("$HOME/.local/bin/mobile-agent-status")
  printf '%s\n' "$status_output"
  case "$status_output" in
    *cpu_usage=*) ;;
    *)
      cpu_snapshot() {
        awk 'NR == 1 && $1 == "cpu" {print ($2+$3+$4+$5+$6+$7+$8+$9+$10), ($5+$6); exit}' /proc/stat 2>/dev/null
      }
      cpu_before=$(cpu_snapshot)
      sleep 0.2
      cpu_after=$(cpu_snapshot)
      cpu_usage=$(awk -v first="$cpu_before" -v second="$cpu_after" 'BEGIN {
        first_count = split(first, first_values, " ")
        second_count = split(second, second_values, " ")
        total = second_values[1] - first_values[1]
        idle = second_values[2] - first_values[2]
        if (first_count >= 2 && second_count >= 2 && total > 0) {
          value = (total - idle) * 100 / total
          if (value < 0) value = 0
          if (value > 100) value = 100
          printf "%.0f", value
        }
      }')
      printf 'cpu_usage=%s\n' "$cpu_usage"
      ;;
  esac
else
  printf 'script_version=0\n'
  printf 'hostname=%s\n' "$(hostname 2>/dev/null | head -n 1)"
  printf 'os=%s\n' "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -n 1 | sed 's/^"//;s/"$//')"
  printf 'kernel=%s\n' "$(uname -sr 2>/dev/null)"
  printf 'uptime=%s\n' "$(uptime -p 2>/dev/null | head -n 1)"
  printf 'load=%s\n' "$(awk '{print $1 " " $2 " " $3}' /proc/loadavg 2>/dev/null)"
  printf 'cpu=%s cores\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null)"
  printf 'memory=%s\n' "$(awk '/MemTotal:/ {total=$2} /MemAvailable:/ {available=$2} END {if (total) printf "%.0f%% (%d/%d MiB)", (total-available)*100/total, (total-available)/1024, total/1024}' /proc/meminfo 2>/dev/null)"
  printf 'disk=%s\n' "$(df -P -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
  printf 'disk_details=%s\n' "$(df -P -h 2>/dev/null | awk 'NR > 1 && $6 ~ /^\// {gsub("%", "", $5); printf "%s|%s|%s|%s|%s;", $6, $2, $3, $4, $5}')"
  printf 'network=%s\n' "$(awk 'NR > 2 {name=$1; sub(/:/, "", name); if (name != "lo") {iface=name; rx += $2; tx += $10}} END {if (iface != "") printf "%s|%.0f|%.0f", iface, rx, tx}' /proc/net/dev 2>/dev/null)"
  printf 'processes=%s\n' "$(ps -e 2>/dev/null | awk 'NR > 1 {count++} END {print count + 0}')"
  cpu_snapshot() {
    awk 'NR == 1 && $1 == "cpu" {print ($2+$3+$4+$5+$6+$7+$8+$9+$10), ($5+$6); exit}' /proc/stat 2>/dev/null
  }
  cpu_before=$(cpu_snapshot)
  sleep 0.2
  cpu_after=$(cpu_snapshot)
  cpu_usage=$(awk -v first="$cpu_before" -v second="$cpu_after" 'BEGIN {
    first_count = split(first, first_values, " ")
    second_count = split(second, second_values, " ")
    total = second_values[1] - first_values[1]
    idle = second_values[2] - first_values[2]
    if (first_count >= 2 && second_count >= 2 && total > 0) {
      value = (total - idle) * 100 / total
      if (value < 0) value = 0
      if (value > 100) value = 100
      printf "%.0f", value
    }
  }')
  printf 'cpu_usage=%s\n' "$cpu_usage"
fi''';

final statusScriptInstallCommand = [
  r'''set -eu
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/mobile-agent-status.tmp.$$" <<'MOBILE_AGENT_STATUS'
''',
  statusScriptBody,
  r'''MOBILE_AGENT_STATUS
chmod 700 "$HOME/.local/bin/mobile-agent-status.tmp.$$"
mv "$HOME/.local/bin/mobile-agent-status.tmp.$$" "$HOME/.local/bin/mobile-agent-status"
printf 'installed\n'
''',
].join('\n');
