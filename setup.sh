#!/bin/bash
# setup.sh - one-shot provisioning for the agent-app exercise
# Run as root from the directory containing agent-app + monitor.sh + report.sh + log_retention.sh:
#   With sudo:     sudo bash setup.sh ./agent-app-linux-x86
#   Already root:  bash setup.sh ./agent-app-linux-x86
# Re-running is idempotent: safe on a partially-set-up box.

set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "[ERROR] must run as root." >&2
  echo "        If sudo is available:  sudo bash setup.sh [path/to/agent-app]" >&2
  echo "        If you ARE root (e.g., container shell), just: bash setup.sh [path/to/agent-app]" >&2
  exit 1
fi

# ---------- Configurable ----------
SSH_PORT=20022
APP_PORT=15034
ADMIN_USER=agent-admin
DEV_USER=agent-dev
TEST_USER=agent-test
COMMON_GRP=agent-common
CORE_GRP=agent-core
AGENT_HOME="/home/${ADMIN_USER}/agent-app"
LOG_DIR="/var/log/agent-app"
APP_BIN_SRC="${1:-}"      # optional; auto-detected below if not given

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="/etc/profile.d/agent-app.sh"
SSHD_DROP="/etc/ssh/sshd_config.d/agent-app.conf"

step() { printf '\n==> %s\n' "$*"; }

# ---------- 1. SSH (port + disable root) ----------
step "1. SSH: Port=${SSH_PORT}, PermitRootLogin=no"
mkdir -p /etc/ssh/sshd_config.d
cat > "$SSHD_DROP" <<EOF
# Managed by setup.sh
Port ${SSH_PORT}
PermitRootLogin no
EOF
chmod 644 "$SSHD_DROP"

# Verify the main config actually pulls in *.conf drop-ins (Ubuntu 22.04 default).
if ! grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
  echo "    [INFO] sshd_config has no Include for sshd_config.d -> patching directly"
  cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
  sed -ri "s|^[#[:space:]]*Port[[:space:]]+.*|Port ${SSH_PORT}|" /etc/ssh/sshd_config || true
  sed -ri "s|^[#[:space:]]*PermitRootLogin[[:space:]]+.*|PermitRootLogin no|" /etc/ssh/sshd_config || true
  grep -q "^Port ${SSH_PORT}"     /etc/ssh/sshd_config || echo "Port ${SSH_PORT}"     >> /etc/ssh/sshd_config
  grep -q "^PermitRootLogin no"   /etc/ssh/sshd_config || echo "PermitRootLogin no"   >> /etc/ssh/sshd_config
fi

# Validate before reload (don't lock yourself out)
if ! sshd -t 2>/tmp/sshd-t.log; then
  echo "[ERROR] sshd config validation failed:"; cat /tmp/sshd-t.log >&2
  exit 1
fi

# Ubuntu 24.04 ships ssh as socket-activated (ssh.socket listens on :22, hands
# off to ssh@.service). Changing sshd_config's Port has no effect there because
# the kernel listener belongs to ssh.socket. Disable the socket and run ssh as
# a normal service so 'Port 20022' actually takes effect.
if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
  systemctl disable --now ssh.socket 2>/dev/null || true
  systemctl enable --now ssh.service 2>/dev/null || true
fi
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart || true

# ---------- 2. Firewall (UFW) ----------
step "2. UFW: allow ${SSH_PORT}/tcp and ${APP_PORT}/tcp only"
if ! command -v ufw >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y ufw
fi
ufw --force reset
ufw default deny  incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow "${APP_PORT}/tcp"
ufw --force enable
ufw status verbose

# ---------- 3. Groups ----------
step "3. Groups: ${COMMON_GRP}, ${CORE_GRP}"
getent group "$COMMON_GRP" >/dev/null || groupadd "$COMMON_GRP"
getent group "$CORE_GRP"   >/dev/null || groupadd "$CORE_GRP"

# ---------- 4. Users ----------
step "4. Users: ${ADMIN_USER}, ${DEV_USER}, ${TEST_USER}"
for U in "$ADMIN_USER" "$DEV_USER" "$TEST_USER"; do
  if ! id -u "$U" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$U"
    echo "    created $U"
  else
    echo "    $U already exists"
  fi
done

# ---------- 5. Group membership ----------
# agent-common: admin, dev, test     /     agent-core: admin, dev
step "5. Memberships"
gpasswd -M "${ADMIN_USER},${DEV_USER},${TEST_USER}" "$COMMON_GRP"
gpasswd -M "${ADMIN_USER},${DEV_USER}"              "$CORE_GRP"
id "$ADMIN_USER"; id "$DEV_USER"; id "$TEST_USER"

# ---------- 6. Directory tree ----------
# Modes use the SETGID bit (2xxx) so newly created files inherit the dir's group.
step "6. Directories under ${AGENT_HOME} and ${LOG_DIR}"
# Ubuntu's useradd -m makes /home/$USER mode 750 owned by user:user, which blocks
# agent-dev/agent-test from traversing it to reach $AGENT_HOME. Open the traversal
# bit explicitly; next-level dir modes still gate read access correctly.
chmod 755 "/home/${ADMIN_USER}"
install -d -o "$ADMIN_USER" -g "$COMMON_GRP" -m 2775 "$AGENT_HOME"
install -d -o "$ADMIN_USER" -g "$COMMON_GRP" -m 2775 "$AGENT_HOME/upload_files"
install -d -o "$ADMIN_USER" -g "$CORE_GRP"   -m 2770 "$AGENT_HOME/api_keys"
install -d -o "$DEV_USER"   -g "$CORE_GRP"   -m 2770 "$AGENT_HOME/bin"
install -d -o "$ADMIN_USER" -g "$CORE_GRP"   -m 2770 "$LOG_DIR"

# ---------- 7. ACLs (defense-in-depth) ----------
step "7. ACLs"
if ! command -v setfacl >/dev/null 2>&1; then
  apt-get install -y acl
fi
# upload_files -> agent-common rwx
setfacl    -m g:${COMMON_GRP}:rwX "$AGENT_HOME/upload_files"
setfacl -d -m g:${COMMON_GRP}:rwX "$AGENT_HOME/upload_files"
# api_keys & log dir -> agent-core rwx ONLY (mask others to ---)
setfacl    -m g:${CORE_GRP}:rwX   "$AGENT_HOME/api_keys"
setfacl -d -m g:${CORE_GRP}:rwX   "$AGENT_HOME/api_keys"
setfacl    -m g:${CORE_GRP}:rwX   "$LOG_DIR"
setfacl -d -m g:${CORE_GRP}:rwX   "$LOG_DIR"

# ---------- 8. API key file ----------
# The agent-app-linux binary expects AGENT_KEY_PATH to be the *directory* and
# the key file to be named 'secret.key' (no 't_' prefix). Earlier builds used
# 't_secret.key'; keep that around as a compat symlink so monitor scripts that
# refer to either name keep working.
step "8. API key: ${AGENT_HOME}/api_keys/secret.key"
KEY="${AGENT_HOME}/api_keys/secret.key"
if [ ! -s "$KEY" ]; then
  printf 'agent_api_key_test\n' > "$KEY"
fi
chown "$ADMIN_USER:$CORE_GRP" "$KEY"
chmod 640 "$KEY"
# Compat: keep t_secret.key pointing at secret.key
ln -sf secret.key "${AGENT_HOME}/api_keys/t_secret.key" 2>/dev/null || true

# ---------- 9. Application binary ----------
# Pick the binary to install:
#   1) explicit arg if given and it exists
#   2) else auto-detect by this host's architecture (agent-app-linux-{arm64,x86})
#   3) else any agent-app-linux-* / agent-app in the script dir
# A wrong-arch binary fails at runtime with a misleading "No such file or directory"
# (missing ELF interpreter), so we MATCH ARCH here and hard-fail if none is found.
step "9. Application binary -> ${AGENT_HOME}/agent-app"

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) WANT="agent-app-linux-arm64" ;;
  x86_64|amd64)  WANT="agent-app-linux-x86"   ;;
  *)             WANT="" ;;
esac

BIN=""
if [ -n "$APP_BIN_SRC" ] && [ -f "$APP_BIN_SRC" ]; then
  BIN="$APP_BIN_SRC"                                   # explicit arg wins
elif [ -n "$WANT" ] && [ -f "${SCRIPT_DIR}/${WANT}" ]; then
  BIN="${SCRIPT_DIR}/${WANT}"                          # arch-matched auto-detect
else                                                    # last resort: anything plausible
  for cand in "${SCRIPT_DIR}/${WANT}" "${SCRIPT_DIR}"/agent-app-linux-* "${SCRIPT_DIR}/agent-app"; do
    [ -f "$cand" ] && { BIN="$cand"; break; }
  done
fi

if [ -z "$BIN" ]; then
  echo "[ERROR] agent-app binary not found." >&2
  echo "        Host arch is '${ARCH}' (expected file: ${WANT:-agent-app-linux-*})." >&2
  echo "        Put the matching binary next to setup.sh, then re-run:" >&2
  echo "          bash setup.sh ./${WANT:-agent-app-linux-x86}" >&2
  exit 1
fi

echo "    installing: $(basename "$BIN")  (host arch: ${ARCH})"
install -o "$ADMIN_USER" -g "$CORE_GRP" -m 750 "$BIN" "${AGENT_HOME}/agent-app"

# Sanity: confirm the ELF actually matches this host (catches arch mismatch now,
# not later at boot). 'No such file or directory' on a present file == wrong arch.
if ! head -c4 "${AGENT_HOME}/agent-app" | grep -q $'\x7fELF'; then
  echo "[ERROR] installed agent-app is not an ELF binary." >&2; exit 1
fi
elf_arch_byte="$(od -An -t u1 -j18 -N1 "${AGENT_HOME}/agent-app" | tr -d ' ')"
#   e_machine LSB: 62 = x86-64, 183 = AArch64
case "$ARCH:$elf_arch_byte" in
  x86_64:62|amd64:62|aarch64:183|arm64:183) : ;;   # match → OK
  *)
    echo "[WARNING] agent-app arch byte ($elf_arch_byte) may not match host ($ARCH)." >&2
    echo "          If boot fails with 'No such file or directory', install the other binary:" >&2
    echo "            bash setup.sh ./${WANT:-agent-app-linux-arm64}" >&2
    ;;
esac

# ---------- 10. Environment variables ----------
step "10. Env vars: ${PROFILE}"
cat > "$PROFILE" <<EOF
# Managed by setup.sh
export AGENT_HOME="${AGENT_HOME}"
export AGENT_PORT="${APP_PORT}"
export AGENT_UPLOAD_DIR="\${AGENT_HOME}/upload_files"
export AGENT_KEY_PATH="\${AGENT_HOME}/api_keys"
export AGENT_LOG_DIR="${LOG_DIR}"
EOF
chmod 644 "$PROFILE"

# ---------- 11. Install scripts ----------
step "11. Install monitor.sh / report.sh / log_retention.sh"
for f in monitor.sh report.sh log_retention.sh; do
  if [ -f "${SCRIPT_DIR}/${f}" ]; then
    install -o "$DEV_USER" -g "$CORE_GRP" -m 750 "${SCRIPT_DIR}/${f}" "${AGENT_HOME}/bin/${f}"
    echo "    installed ${f}"
  else
    echo "    [WARNING] missing ${SCRIPT_DIR}/${f}"
  fi
done

# ---------- 12. Cron for agent-admin (every minute) ----------
step "12. Cron: ${ADMIN_USER} runs monitor.sh every minute"
CRON_CMD="* * * * * AGENT_HOME=${AGENT_HOME} AGENT_PORT=${APP_PORT} AGENT_LOG_DIR=${LOG_DIR} ${AGENT_HOME}/bin/monitor.sh >/dev/null 2>&1"
# crontab -l exits 1 when the user has no crontab yet; combined with set -euo
# pipefail that silently aborts the install, leaving the rule unregistered.
# Disable errexit/pipefail just for this dedup-and-append pipeline.
(
  set +eo pipefail
  EXISTING="$(crontab -u "$ADMIN_USER" -l 2>/dev/null | grep -v 'bin/monitor.sh' || true)"
  { [ -n "$EXISTING" ] && printf '%s\n' "$EXISTING"; echo "$CRON_CMD"; } \
    | crontab -u "$ADMIN_USER" -
)
crontab -u "$ADMIN_USER" -l

# ---------- Summary ----------
step "Done. Quick verification commands (no sudo needed — you're root):"
cat <<EOF
  ss -tulnp | grep -E ':(${SSH_PORT}|${APP_PORT})\b'
  ufw status
  id ${ADMIN_USER} ; id ${DEV_USER} ; id ${TEST_USER}
  ls -ld ${AGENT_HOME} ${AGENT_HOME}/upload_files ${AGENT_HOME}/api_keys ${LOG_DIR}
  getfacl ${AGENT_HOME}/api_keys ${LOG_DIR}
  su - ${ADMIN_USER} -c 'cd \$AGENT_HOME && ./agent-app'              # boot the app (in another shell)
  crontab -u ${ADMIN_USER} -l                                          # list cron rule
  tail -f ${LOG_DIR}/monitor.log                                       # watch log accumulate
  su - ${TEST_USER} -c 'ls ${AGENT_HOME}/api_keys' ; echo "exit=\$?"   # negative check: should be denied

Reconnect over SSH on port ${SSH_PORT} (the old port is now blocked):
  ssh -p ${SSH_PORT} ${ADMIN_USER}@<host>
EOF
