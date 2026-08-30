const statusScriptBody = r'''#!/bin/sh
set +e

clean_value() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

if [ "${1:-}" = "directory" ]; then
  directory_path=${2:-}
  expected_fingerprint=${3:-}
  if [ -z "$directory_path" ] || [ ! -d "$directory_path" ]; then
    printf 'probe_version=1\n'
    printf 'error=directory_unavailable\n'
    exit 1
  fi
  if ! command -v stat >/dev/null 2>&1 ||
     ! command -v sort >/dev/null 2>&1 ||
     ! command -v cksum >/dev/null 2>&1; then
    printf 'probe_version=1\n'
    printf 'error=probe_tools_unavailable\n'
    exit 1
  fi

  directory_metadata() {
    for item in "$directory_path"/* "$directory_path"/.[!.]* "$directory_path"/..?*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      item_name=${item##*/}
      item_type=f
      [ -d "$item" ] && item_type=d
      item_stat=$(stat -c '%s %Y' "$item" 2>/dev/null)
      [ -n "$item_stat" ] || item_stat=$(stat -f '%z %m' "$item" 2>/dev/null)
      if [ -z "$item_stat" ]; then
        printf '__mobile_agent_probe_error__\n'
        continue
      fi
      item_size=${item_stat%% *}
      item_modified=${item_stat#* }
      printf '%s\t%s\t%s\t%s\n' \
        "$item_type" "$item_size" "$item_modified" "$item_name"
    done
  }

  directory_output=$(directory_metadata)
  case "$directory_output" in
    *__mobile_agent_probe_error__*)
    printf 'probe_version=1\n'
    printf 'error=entry_metadata_unavailable\n'
    exit 1
    ;;
  esac
  sorted_directory=$(printf '%s\n' "$directory_output" | LC_ALL=C sort)
  fingerprint_value=$(printf '%s\n' "$sorted_directory" | cksum | awk '{print $1 ":" $2}')
  if [ -z "$fingerprint_value" ]; then
    printf 'probe_version=1\n'
    printf 'error=fingerprint_unavailable\n'
    exit 1
  fi
  printf 'probe_version=1\n'
  printf 'fingerprint=%s\n' "$fingerprint_value"
  if [ -n "$expected_fingerprint" ] &&
     [ "$expected_fingerprint" = "$fingerprint_value" ]; then
    printf 'unchanged=1\n'
    exit 0
  fi
  printf 'unchanged=0\n'
  printf '%s\n' "$sorted_directory" | while IFS= read -r item_line; do
    [ -n "$item_line" ] || continue
    printf 'entry\t%s\n' "$item_line"
  done
  exit 0
fi

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
  awk '$1 == "cpu" || $1 ~ /^cpu[0-9]+$/ {
    total = $2+$3+$4+$5+$6+$7+$8+$9+$10
    idle = $5+$6
    print $1 " " total " " idle
  }' /proc/stat 2>/dev/null
}
cpu_before=$(cpu_snapshot)
sleep 0.2
cpu_after=$(cpu_snapshot)
cpu_metrics=$(awk -v first="$cpu_before" -v second="$cpu_after" 'BEGIN {
  first_count = split(first, first_lines, "\n")
  for (i = 1; i <= first_count; i++) {
    field_count = split(first_lines[i], fields, "[[:space:]]+")
    if (field_count >= 3) {
      first_total[fields[1]] = fields[2]
      first_idle[fields[1]] = fields[3]
    }
  }
  second_count = split(second, second_lines, "\n")
  for (i = 1; i <= second_count; i++) {
    field_count = split(second_lines[i], fields, "[[:space:]]+")
    name = fields[1]
    if (field_count < 3 || !(name in first_total)) continue
    total = fields[2] - first_total[name]
    idle = fields[3] - first_idle[name]
    if (total <= 0) continue
    value = (total - idle) * 100 / total
    if (value < 0) value = 0
    if (value > 100) value = 100
    if (name == "cpu") {
      total_usage = sprintf("%.0f", value)
    } else if (name ~ /^cpu[0-9]+$/) {
      if (core_usage != "") core_usage = core_usage ","
      core_usage = core_usage name ":" sprintf("%.0f", value)
    }
  }
  print "cpu_usage=" total_usage
  print "cpu_core_usage=" core_usage
}')

printf 'script_version=3\n'
printf 'hostname=%s\n' "$(clean_value "$hostname_value")"
printf 'os=%s\n' "$(clean_value "$os_value")"
printf 'kernel=%s\n' "$(clean_value "$kernel_value")"
printf 'uptime=%s\n' "$(clean_value "$uptime_value")"
printf 'load=%s\n' "$(clean_value "$load_value")"
printf 'cpu=%s cores\n' "$(clean_value "$cpu_value")"
printf '%s\n' "$cpu_metrics"
printf 'memory=%s\n' "$(clean_value "$memory_value")"
printf 'disk=%s\n' "$(clean_value "$disk_value")"
printf 'disk_details=%s\n' "$(clean_value "$disk_details_value")"
printf 'network=%s\n' "$(clean_value "$network_value")"
printf 'processes=%s\n' "$(clean_value "$process_value")"
''';

const statusProbeCommand = r'''cpu_snapshot() {
  awk '$1 == "cpu" || $1 ~ /^cpu[0-9]+$/ {
    total = $2+$3+$4+$5+$6+$7+$8+$9+$10
    idle = $5+$6
    print $1 " " total " " idle
  }' /proc/stat 2>/dev/null
}

calculate_cpu_metrics() {
  awk -v first="$1" -v second="$2" 'BEGIN {
    first_count = split(first, first_lines, "\n")
    for (i = 1; i <= first_count; i++) {
      field_count = split(first_lines[i], fields, "[[:space:]]+")
      if (field_count >= 3) {
        first_total[fields[1]] = fields[2]
        first_idle[fields[1]] = fields[3]
      }
    }
    second_count = split(second, second_lines, "\n")
    for (i = 1; i <= second_count; i++) {
      field_count = split(second_lines[i], fields, "[[:space:]]+")
      name = fields[1]
      if (field_count < 3 || !(name in first_total)) continue
      total = fields[2] - first_total[name]
      idle = fields[3] - first_idle[name]
      if (total <= 0) continue
      value = (total - idle) * 100 / total
      if (value < 0) value = 0
      if (value > 100) value = 100
      if (name == "cpu") {
        total_usage = sprintf("%.0f", value)
      } else if (name ~ /^cpu[0-9]+$/) {
        if (core_usage != "") core_usage = core_usage ","
        core_usage = core_usage name ":" sprintf("%.0f", value)
      }
    }
    print "cpu_usage=" total_usage
    print "cpu_core_usage=" core_usage
  }'
}

metric_line() {
  metric_name=$1
  metric_output=$2
  printf '%s\n' "$metric_output" | awk -v name="$metric_name" 'index($0, name "=") == 1 {print; exit}'
}

if [ -x "$HOME/.local/bin/mobile-agent-status" ]; then
  status_output=$("$HOME/.local/bin/mobile-agent-status")
  printf '%s\n' "$status_output"
  case "$status_output" in
    *cpu_usage=*) ;;
    *)
      cpu_before=$(cpu_snapshot)
      sleep 0.2
      cpu_after=$(cpu_snapshot)
      metric_line cpu_usage "$(calculate_cpu_metrics "$cpu_before" "$cpu_after")"
      ;;
  esac
  case "$status_output" in
    *cpu_core_usage=*) ;;
    *)
      cpu_before=$(cpu_snapshot)
      sleep 0.2
      cpu_after=$(cpu_snapshot)
      metric_line cpu_core_usage "$(calculate_cpu_metrics "$cpu_before" "$cpu_after")"
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
  cpu_before=$(cpu_snapshot)
  sleep 0.2
  cpu_after=$(cpu_snapshot)
  calculate_cpu_metrics "$cpu_before" "$cpu_after"
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
