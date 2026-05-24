#!/bin/bash
# monitor.sh - agent-app process/port/resource monitor + log writer
# Path  : $AGENT_HOME/bin/monitor.sh
# Owner : agent-dev   Group : agent-core   Perms : 750
# Cron  : agent-admin (must belong to agent-core)

set -u

# ===== Configuration =====
AGENT_PROC="${AGENT_PROC:-agent-app}"           # provided binary name
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
LOG_FILE="$AGENT_LOG_DIR/monitor.log"

# Threshold (warning only)
CPU_WARN=20
MEM_WARN=10
DISK_WARN=80

# Rotation policy: <=10MB per file, keep up to 10 rotated files
MAX_SIZE_BYTES=$((10 * 1024 * 1024))
MAX_ROTATIONS=10

# ===== Helpers =====
section() { printf '\n[%s]\n' "$1"; }
warn()    { printf '[WARNING] %s\n' "$*"; }

echo "====== SYSTEM MONITOR RESULT ======"

# ===== 1. Health check (FAIL -> exit 1) =====
section "HEALTH CHECK"

# Process: pidof matches by basename only (won't match this script).
PID="$(pidof -s "$AGENT_PROC" 2>/dev/null || true)"
if [ -z "${PID:-}" ]; then
  PID="$(pgrep -x "$AGENT_PROC" 2>/dev/null | head -n1 || true)"
fi
if [ -z "${PID:-}" ]; then
  printf "Checking process '%s'... [FAIL]\n" "$AGENT_PROC"
  echo "[ERROR] process '$AGENT_PROC' is not running"
  exit 1
fi
printf "Checking process '%s'... [OK] (PID: %s)\n" "$AGENT_PROC" "$PID"

# Port: ss preferred, fall back to netstat
port_listen=0
if command -v ss >/dev/null 2>&1; then
  ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\.)${AGENT_PORT}$" && port_listen=1
elif command -v netstat >/dev/null 2>&1; then
  netstat -tln 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\.)${AGENT_PORT}$" && port_listen=1
else
  warn "neither 'ss' nor 'netstat' is available; skipping port check"
  port_listen=1   # don't fail if we can't measure
fi
if [ "$port_listen" -ne 1 ]; then
  printf "Checking port %s... [FAIL]\n" "$AGENT_PORT"
  echo "[ERROR] port $AGENT_PORT is not LISTEN"
  exit 1
fi
printf "Checking port %s... [OK]\n" "$AGENT_PORT"

# ===== 2. Firewall (warning only, never exit) =====
section "FIREWALL CHECK"
fw_active=0
if systemctl is-active --quiet ufw 2>/dev/null; then
  echo "UFW service is active... [OK]"
  fw_active=1
elif systemctl is-active --quiet firewalld 2>/dev/null; then
  echo "firewalld service is active... [OK]"
  fw_active=1
fi
[ "$fw_active" -eq 0 ] && warn "firewall (UFW/firewalld) is not active"

# ===== 3. Resource collection =====
section "RESOURCE MONITORING"

# CPU%: sample /proc/stat twice 1s apart and compute (1 - idle/total) * 100.
read_cpu() {
  awk '/^cpu / { idle=$5+$6; total=$2+$3+$4+$5+$6+$7+$8; print total, idle }' /proc/stat
}
read1=( $(read_cpu) ); sleep 1; read2=( $(read_cpu) )
total_d=$((read2[0] - read1[0]))
idle_d=$((read2[1] - read1[1]))
if [ "$total_d" -gt 0 ]; then
  cpu_usage=$(awk -v t="$total_d" -v i="$idle_d" 'BEGIN { printf "%.1f", (t - i) * 100 / t }')
else
  cpu_usage="0.0"
fi

# MEM%: from /proc/meminfo using MemAvailable (more accurate than 'free' tricks).
mem_usage=$(awk '
  /^MemTotal:/     { tot   = $2 }
  /^MemAvailable:/ { avail = $2 }
  END { if (tot > 0) printf "%.1f", (tot - avail) * 100 / tot; else print "0.0" }
' /proc/meminfo)

# DISK%: root partition, POSIX format (-P) keeps it on a single line.
disk_used=$(df -P / | awk 'NR==2 { gsub("%","",$5); print $5 }')

printf 'CPU Usage  : %s%%\n' "$cpu_usage"
printf 'MEM Usage  : %s%%\n' "$mem_usage"
printf 'DISK Used  : %s%%\n' "$disk_used"

# ===== 4. Threshold warnings =====
awk -v v="$cpu_usage"  -v t="$CPU_WARN"  'BEGIN { exit !((v + 0) > t) }' \
  && warn "CPU threshold exceeded ($cpu_usage% > $CPU_WARN%)"
awk -v v="$mem_usage"  -v t="$MEM_WARN"  'BEGIN { exit !((v + 0) > t) }' \
  && warn "MEM threshold exceeded ($mem_usage% > $MEM_WARN%)"
awk -v v="$disk_used"  -v t="$DISK_WARN" 'BEGIN { exit !((v + 0) > t) }' \
  && warn "DISK threshold exceeded ($disk_used% > $DISK_WARN%)"

# ===== 5. Rotate (size-based) and append log =====
mkdir -p "$AGENT_LOG_DIR" 2>/dev/null || true

if [ -f "$LOG_FILE" ]; then
  size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -ge "$MAX_SIZE_BYTES" ]; then
    [ -f "${LOG_FILE}.${MAX_ROTATIONS}" ] && rm -f "${LOG_FILE}.${MAX_ROTATIONS}"
    for i in $(seq $((MAX_ROTATIONS - 1)) -1 1); do
      [ -f "${LOG_FILE}.${i}" ] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    done
    mv "$LOG_FILE" "${LOG_FILE}.1"
  fi
fi

ts="$(date '+%Y-%m-%d %H:%M:%S')"
printf '[%s] PID:%s CPU:%s%% MEM:%s%% DISK_USED:%s%%\n' \
  "$ts" "$PID" "$cpu_usage" "$mem_usage" "$disk_used" >> "$LOG_FILE"

echo
echo "[INFO] Log appended: $LOG_FILE"
exit 0
