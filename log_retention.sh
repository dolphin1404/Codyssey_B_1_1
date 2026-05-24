#!/bin/bash
# log_retention.sh - time-based log retention
#   1) compress *.log older than 7 days from /var/log/agent-app/
#      to /var/log/monitor/agent-app/archive/<name>.<timestamp>.gz
#   2) delete *.gz older than 30 days from /var/log/monitor/agent-app/archive/
# Designed to fail safe: missing dirs, no perms, zero matches -> warn + exit 0.

set -u

SRC_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
ARCHIVE_DIR="/var/log/monitor/agent-app/archive"
COMPRESS_AGE_DAYS=7
DELETE_AGE_DAYS=30

ts="$(date '+%Y-%m-%d %H:%M:%S')"
log()  { printf '[%s] [INFO] %s\n'    "$ts" "$*"; }
warn() { printf '[%s] [WARNING] %s\n' "$ts" "$*"; }

# 0. Source dir sanity
if [ ! -d "$SRC_DIR" ]; then
  warn "source dir does not exist: $SRC_DIR"
  exit 0
fi
if [ ! -r "$SRC_DIR" ]; then
  warn "no read permission on $SRC_DIR"
  exit 0
fi

# 1. Archive dir (create if missing)
if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
  warn "cannot create archive dir: $ARCHIVE_DIR (need root/proper perms)"
  exit 0
fi
if [ ! -w "$ARCHIVE_DIR" ]; then
  warn "no write permission on $ARCHIVE_DIR"
  exit 0
fi

# 2. Compress >7-day .log files
compressed=0
errored=0
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  out="$ARCHIVE_DIR/${base}.$(date '+%Y%m%d-%H%M%S').gz"
  if gzip -c -- "$f" > "$out" 2>/dev/null; then
    if rm -f -- "$f" 2>/dev/null; then
      compressed=$((compressed + 1))
    else
      warn "compressed but could not remove original: $f"
      errored=$((errored + 1))
    fi
  else
    warn "failed to compress: $f"
    rm -f -- "$out" 2>/dev/null
    errored=$((errored + 1))
  fi
done < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.log' -mtime +"$COMPRESS_AGE_DAYS" -print0 2>/dev/null)

if [ "$compressed" -eq 0 ] && [ "$errored" -eq 0 ]; then
  log "no .log files older than ${COMPRESS_AGE_DAYS}d in $SRC_DIR"
else
  log "compressed ${compressed} file(s); ${errored} error(s)"
fi

# 3. Delete >30-day .gz archives
deleted=0
del_err=0
while IFS= read -r -d '' f; do
  if rm -f -- "$f" 2>/dev/null; then
    deleted=$((deleted + 1))
  else
    warn "could not delete archive: $f"
    del_err=$((del_err + 1))
  fi
done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.gz' -mtime +"$DELETE_AGE_DAYS" -print0 2>/dev/null)

if [ "$deleted" -eq 0 ] && [ "$del_err" -eq 0 ]; then
  log "no .gz archives older than ${DELETE_AGE_DAYS}d in $ARCHIVE_DIR"
else
  log "deleted ${deleted} archive(s); ${del_err} error(s)"
fi

exit 0
