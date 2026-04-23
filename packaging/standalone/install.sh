#!/bin/sh
set -eu

umask 022

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

to_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"

PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="${BIN_DIR:-${PREFIX}/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/derper}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/derper.toml}"
DATA_DIR="${DATA_DIR:-/data}"
SERVICE_NAME="${SERVICE_NAME:-derper}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
ENABLE_SERVICE="${ENABLE_SERVICE:-true}"
START_SERVICE="${START_SERVICE:-}"
RESTART_SERVICE="${RESTART_SERVICE:-true}"

[ "$(id -u)" = "0" ] || die "run as root, for example: sudo ./install.sh"
[ -x "${SCRIPT_DIR}/derper" ] || die "missing bundled derper binary"
[ -x "${SCRIPT_DIR}/lego" ] || die "missing bundled lego binary"
[ -x "${SCRIPT_DIR}/derper-run" ] || die "missing bundled derper-run script"
[ -f "${SCRIPT_DIR}/derper.toml" ] || die "missing bundled derper.toml"

[ -r /etc/os-release ] || die "unsupported Linux: /etc/os-release not found"
. /etc/os-release
os_words=" ${ID:-} ${ID_LIKE:-} "
case "${os_words}" in
  *" debian "*|*" ubuntu "*|*" rhel "*|*" centos "*|*" fedora "*) ;;
  *) die "unsupported Linux distribution: ${ID:-unknown}" ;;
esac

mkdir -p "${BIN_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" \
  "${DATA_DIR}/certs" "${DATA_DIR}/acme" "${DATA_DIR}/cache"

copy_exec() {
  src="$1"
  dest="$2"
  tmp="${dest}.tmp.$$"
  cp "${src}" "${tmp}"
  chmod 0755 "${tmp}"
  mv -f "${tmp}" "${dest}"
}

copy_exec "${SCRIPT_DIR}/derper" "${BIN_DIR}/derper"
copy_exec "${SCRIPT_DIR}/lego" "${BIN_DIR}/lego"
copy_exec "${SCRIPT_DIR}/derper-run" "${BIN_DIR}/derper-run"
log "updated binaries in ${BIN_DIR}"

if [ ! -f "${CONFIG_FILE}" ]; then
  cp "${SCRIPT_DIR}/derper.toml" "${CONFIG_FILE}"
  chmod 0644 "${CONFIG_FILE}"
  if [ -n "${DERP_HOST:-}" ]; then
    tmp="${CONFIG_FILE}.tmp.$$"
    sed "s/^host[[:space:]]*=.*/host = \"${DERP_HOST}\"/" "${CONFIG_FILE}" > "${tmp}"
    mv -f "${tmp}" "${CONFIG_FILE}"
  fi
  log "created config ${CONFIG_FILE}"
else
  log "kept existing config ${CONFIG_FILE}"
fi

if [ -z "${START_SERVICE}" ]; then
  if [ -n "${DERP_HOST:-}" ] || ! grep -Eq '^[[:space:]]*host[[:space:]]*=[[:space:]]*"203\.0\.113\.10"' "${CONFIG_FILE}"; then
    START_SERVICE=true
  else
    START_SERVICE=false
  fi
fi

if [ -d /etc/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  if [ ! -f "${SERVICE_FILE}" ]; then
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Tailscale DERP relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=DERPER_CONFIG_FILE=${CONFIG_FILE}
Environment=DERP_DATA_DIR=${DATA_DIR}
ExecStart=${BIN_DIR}/derper-run
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "${SERVICE_FILE}"
    log "created systemd unit ${SERVICE_FILE}"
  else
    log "kept existing systemd unit ${SERVICE_FILE}"
  fi

  if systemctl daemon-reload; then
    if to_bool "${ENABLE_SERVICE}"; then
      systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1 || log "could not enable ${SERVICE_NAME}.service"
    fi

    if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
      if to_bool "${RESTART_SERVICE}"; then
        systemctl restart "${SERVICE_NAME}.service"
        log "restarted ${SERVICE_NAME}.service"
      else
        log "${SERVICE_NAME}.service is running; restart skipped"
      fi
    elif to_bool "${START_SERVICE}"; then
      systemctl start "${SERVICE_NAME}.service"
      log "started ${SERVICE_NAME}.service"
    else
      log "service installed but not started; edit ${CONFIG_FILE}, then run: systemctl start ${SERVICE_NAME}"
    fi
  else
    log "systemctl daemon-reload failed; files were installed but service was not managed"
  fi
else
  log "systemd not detected; run manually with: DERPER_CONFIG_FILE=${CONFIG_FILE} ${BIN_DIR}/derper-run"
fi
