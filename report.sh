#!/bin/bash
# report.sh - print Average / Maximum / Minimum / Sample-count for CPU, MEM, DISK
#             from /var/log/agent-app/monitor.log
# Usage:
#   report.sh                                  # whole log
#   report.sh "2026-02-25 13:58:00" \
#             "2026-02-25 14:05:00"            # filter by time range
#   AGENT_LOG_DIR=/tmp/foo report.sh           # override log dir

set -u

AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
LOG_FILE="$AGENT_LOG_DIR/monitor.log"
START="${1:-}"
END="${2:-}"

if [ ! -r "$LOG_FILE" ]; then
  echo "[ERROR] cannot read log: $LOG_FILE" >&2
  exit 1
fi

# Convert range bounds to epoch up front (avoids spawning `date` per line).
s_epoch=""
e_epoch=""
if [ -n "$START" ]; then
  s_epoch=$(date -d "$START" +%s 2>/dev/null || true)
  [ -z "$s_epoch" ] && { echo "[ERROR] invalid START: $START" >&2; exit 1; }
fi
if [ -n "$END" ]; then
  e_epoch=$(date -d "$END" +%s 2>/dev/null || true)
  [ -z "$e_epoch" ] && { echo "[ERROR] invalid END: $END" >&2; exit 1; }
fi

awk -v s="$s_epoch" -v e="$e_epoch" '
  function ts2epoch(str,    cmd, x) {
    cmd = "date -d \"" str "\" +%s 2>/dev/null"
    cmd | getline x
    close(cmd)
    return x + 0
  }
  BEGIN {
    cmin =  1e9; cmax = -1; csum = 0
    mmin =  1e9; mmax = -1; msum = 0
    dmin =  1e9; dmax = -1; dsum = 0
    n = 0
  }
  # match: [2026-02-25 13:58:01] PID:48291 CPU:10.2% MEM:3.2% DISK_USED:23%
  /^\[/ {
    ts = $1 " " $2
    gsub(/[\[\]]/, "", ts)

    if (s != "" || e != "") {
      ep = ts2epoch(ts)
      if (s != "" && ep < (s + 0)) next
      if (e != "" && ep > (e + 0)) next
    }

    cpu = mem = disk = -1
    for (i = 3; i <= NF; i++) {
      if      (match($i, /^CPU:[0-9.]+/))       cpu  = substr($i, 5,  RLENGTH - 4) + 0
      else if (match($i, /^MEM:[0-9.]+/))       mem  = substr($i, 5,  RLENGTH - 4) + 0
      else if (match($i, /^DISK_USED:[0-9.]+/)) disk = substr($i, 11, RLENGTH - 10) + 0
    }
    if (cpu < 0 || mem < 0 || disk < 0) next

    csum += cpu
    if (cpu < cmin) { cmin = cpu; cmin_ts = ts }
    if (cpu > cmax) { cmax = cpu; cmax_ts = ts }

    msum += mem
    if (mem < mmin) { mmin = mem; mmin_ts = ts }
    if (mem > mmax) { mmax = mem; mmax_ts = ts }

    dsum += disk
    if (disk < dmin) { dmin = disk; dmin_ts = ts }
    if (disk > dmax) { dmax = disk; dmax_ts = ts }

    n++
  }
  END {
    if (n == 0) { print "[INFO] no samples in selected range"; exit 0 }
    printf "====== STATISTICS REPORT ======\n"
    printf "  [CPU]\n"
    printf "    Average : %.1f%%\n",         csum / n
    printf "    Maximum : %.1f%% at %s\n",   cmax, cmax_ts
    printf "    Minimum : %.1f%% at %s\n",   cmin, cmin_ts
    printf "  [Memory]\n"
    printf "    Average : %.1f%%\n",         msum / n
    printf "    Maximum : %.1f%% at %s\n",   mmax, mmax_ts
    printf "    Minimum : %.1f%% at %s\n",   mmin, mmin_ts
    printf "  [Disk]\n"
    printf "    Average : %.1f%%\n",         dsum / n
    printf "    Maximum : %.1f%% at %s\n",   dmax, dmax_ts
    printf "    Minimum : %.1f%% at %s\n",   dmin, dmin_ts
    printf "  [Samples]\n"
    printf "    Data Points: %d samples\n",  n
  }
' "$LOG_FILE"
