#!/bin/sh
set -eu

umask 022

log() { printf '%s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

to_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

is_ip() {
  case "$1" in
    *:*:*) printf '%s' "$1" | grep -Eq '^[0-9a-fA-F:]+$' ;;
    *.*.*.*) printf '%s' "$1" | grep -Eq '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$' ;;
    *) return 1 ;;
  esac
}

is_tty() { [ -t 0 ] && [ -t 1 ]; }

ask() {
  # ask "<prompt>" "<default>" -> echoes answer
  prompt="$1"
  default="${2:-}"
  if [ -n "${default}" ]; then
    printf '%s [%s]: ' "${prompt}" "${default}" >&2
  else
    printf '%s: ' "${prompt}" >&2
  fi
  IFS= read -r ans </dev/tty || ans=""
  [ -z "${ans}" ] && ans="${default}"
  printf '%s' "${ans}"
}

ask_secret() {
  prompt="$1"
  printf '%s: ' "${prompt}" >&2
  if command -v stty >/dev/null 2>&1; then
    stty -echo </dev/tty 2>/dev/null || true
    IFS= read -r ans </dev/tty || ans=""
    stty echo </dev/tty 2>/dev/null || true
    printf '\n' >&2
  else
    IFS= read -r ans </dev/tty || ans=""
  fi
  printf '%s' "${ans}"
}

detect_public_ip() {
  for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip="$(curl -fsS --max-time 3 "${url}" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -n "${ip}" ] && is_ip "${ip}"; then
      printf '%s' "${ip}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="${BIN_DIR:-${PREFIX}/bin}"
CONFIG_DIR="${CONFIG_DIR:-/etc/derper}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/derper.toml}"
ENV_FILE="${ENV_FILE:-${CONFIG_DIR}/derper.env}"
DATA_DIR="${DATA_DIR:-/data}"
SERVICE_NAME="${SERVICE_NAME:-derper}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
ENABLE_SERVICE="${ENABLE_SERVICE:-true}"
START_SERVICE="${START_SERVICE:-}"
RESTART_SERVICE="${RESTART_SERVICE:-true}"

CMD="${1:-install}"

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------

cmd_uninstall() {
  [ "$(id -u)" = "0" ] || die "run as root, for example: sudo ./install.sh uninstall"
  if command -v systemctl >/dev/null 2>&1 && [ -f "${SERVICE_FILE}" ]; then
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null || true
    log "removed ${SERVICE_FILE}"
  fi
  rm -f "${BIN_DIR}/derper" "${BIN_DIR}/lego" "${BIN_DIR}/derper-run"
  log "removed binaries from ${BIN_DIR}"
  log "kept ${CONFIG_DIR} and ${DATA_DIR} (delete manually if you want a clean wipe)"
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

cmd_check() {
  status=0
  log "config:  ${CONFIG_FILE} $([ -f "${CONFIG_FILE}" ] && echo OK || { echo MISSING; status=1; })"
  log "env:     ${ENV_FILE} $([ -f "${ENV_FILE}" ] && echo OK || echo '(none)')"
  log "data:    ${DATA_DIR} $([ -d "${DATA_DIR}" ] && echo OK || echo MISSING)"

  host=""; mode=""; addr=":443"
  if [ -f "${CONFIG_FILE}" ]; then
    host="$(awk -F'=' '/^[[:space:]]*host[[:space:]]*=/{gsub(/[" ]/,"",$2); print $2; exit}' "${CONFIG_FILE}")"
    mode="$(awk -F'=' '/^[[:space:]]*tls_mode[[:space:]]*=/{gsub(/[" ]/,"",$2); print $2; exit}' "${CONFIG_FILE}")"
    a="$(awk -F'=' '/^[[:space:]]*addr[[:space:]]*=/{gsub(/[" ]/,"",$2); print $2; exit}' "${CONFIG_FILE}")"
    [ -n "${a}" ] && addr="${a}"
  fi
  log "host:    ${host:-(unset)}"
  log "mode:    ${mode:-(unset)}"
  log "addr:    ${addr}"

  if command -v systemctl >/dev/null 2>&1 && [ -f "${SERVICE_FILE}" ]; then
    state="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
    log "systemd: ${state}"
    [ "${state}" = "active" ] || status=1
  fi

  port="${addr#*:}"
  [ -z "${port}" ] && port=443
  if command -v ss >/dev/null 2>&1; then
    ss -lntH "sport = :${port}" 2>/dev/null | grep -q ":${port}" \
      && log "listen:  :${port} OK" \
      || { log "listen:  :${port} NOT LISTENING"; status=1; }
  fi

  cert_file="${DATA_DIR}/certs/${host}.crt"
  if [ -n "${host}" ] && [ -f "${cert_file}" ] && command -v openssl >/dev/null 2>&1; then
    fp="$(openssl x509 -in "${cert_file}" -outform DER 2>/dev/null \
      | openssl dgst -sha256 -binary | base64 2>/dev/null || true)"
    if [ -n "${fp}" ]; then
      log ""
      log "DERPMap snippet:"
      log "  \"DERPMap\": { \"Regions\": { \"900\": { \"RegionID\": 900, \"RegionCode\": \"custom\", \"Nodes\": ["
      log "    { \"Name\": \"1\", \"RegionID\": 900, \"HostName\": \"${host}\", \"IPv4\": \"${host}\","
      log "      \"DERPPort\": ${port}, \"CertName\": \"sha256-raw:${fp}\" }"
      log "  ] } } }"
    fi
  fi
  return ${status}
}

# ---------------------------------------------------------------------------
# install (default)
# ---------------------------------------------------------------------------

cmd_install() {
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
    *) warn "untested distribution: ${ID:-unknown}; continuing anyway" ;;
  esac

  mkdir -p "${BIN_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" \
    "${DATA_DIR}/certs" "${DATA_DIR}/acme" "${DATA_DIR}/cache"

  copy_exec() {
    src="$1"; dest="$2"; tmp="${dest}.tmp.$$"
    cp "${src}" "${tmp}"
    chmod 0755 "${tmp}"
    mv -f "${tmp}" "${dest}"
  }

  copy_exec "${SCRIPT_DIR}/derper" "${BIN_DIR}/derper"
  copy_exec "${SCRIPT_DIR}/lego" "${BIN_DIR}/lego"
  copy_exec "${SCRIPT_DIR}/derper-run" "${BIN_DIR}/derper-run"
  log "updated binaries in ${BIN_DIR}"

  # ---- interactive wizard (only when stdin is a tty AND key vars unset) ----
  interactive=false
  if is_tty && [ -z "${DERP_HOST:-}" ] && [ -z "${NONINTERACTIVE:-}" ]; then
    interactive=true
  fi

  : "${DERP_TLS_MODE:=}"
  : "${DERP_HOST:=}"
  : "${DERP_DNS_PROVIDER:=}"
  : "${DERP_ACME_EMAIL:=}"

  PROVIDER_ENV_NAME=""
  PROVIDER_ENV_VALUE=""

  if [ "${interactive}" = "true" ]; then
    log ""
    log "=== derper setup wizard ==="
    log "press Enter to accept defaults shown in [brackets]"
    log ""

    if [ -z "${DERP_TLS_MODE}" ]; then
      log "TLS mode:"
      log "  ip    = self-signed cert tied to a public IP (no domain needed)"
      log "  dns01 = Let's Encrypt cert via DNS-01 (needs domain + DNS API token)"
      DERP_TLS_MODE="$(ask "mode (ip/dns01)" "ip")"
    fi

    case "${DERP_TLS_MODE}" in
      ip)
        if [ -z "${DERP_HOST}" ]; then
          guess="$(detect_public_ip || true)"
          if [ -n "${guess}" ]; then
            log "detected public IP: ${guess}"
          fi
          while :; do
            DERP_HOST="$(ask "public IP" "${guess}")"
            is_ip "${DERP_HOST}" && break
            log "  not a valid IPv4/IPv6 address, try again"
          done
        fi
        ;;
      dns01)
        while [ -z "${DERP_HOST}" ] || is_ip "${DERP_HOST}"; do
          DERP_HOST="$(ask "domain (e.g. derp.example.com)" "")"
          [ -n "${DERP_HOST}" ] && ! is_ip "${DERP_HOST}" || \
            log "  must be a domain name, not an IP"
        done
        [ -n "${DERP_DNS_PROVIDER}" ] || {
          log "DNS provider (lego name): cloudflare / alidns / dnspod / route53 / gcloud / ..."
          log "full list: https://go-acme.github.io/lego/dns/"
          DERP_DNS_PROVIDER="$(ask "DNS provider" "cloudflare")"
        }
        [ -n "${DERP_ACME_EMAIL}" ] || \
          DERP_ACME_EMAIL="$(ask "ACME contact email" "")"

        case "${DERP_DNS_PROVIDER}" in
          cloudflare) PROVIDER_ENV_NAME="CLOUDFLARE_DNS_API_TOKEN" ;;
          alidns)     PROVIDER_ENV_NAME="ALICLOUD_ACCESS_KEY" ;;
          dnspod)     PROVIDER_ENV_NAME="DNSPOD_API_KEY" ;;
          route53)    PROVIDER_ENV_NAME="AWS_ACCESS_KEY_ID" ;;
          gcloud)     PROVIDER_ENV_NAME="GCE_PROJECT" ;;
          *)
            PROVIDER_ENV_NAME="$(ask "primary credential env var name" "")"
            ;;
        esac
        if [ -n "${PROVIDER_ENV_NAME}" ]; then
          existing="$(printenv "${PROVIDER_ENV_NAME}" 2>/dev/null || true)"
          if [ -n "${existing}" ]; then
            PROVIDER_ENV_VALUE="${existing}"
            log "using ${PROVIDER_ENV_NAME} from environment"
          else
            PROVIDER_ENV_VALUE="$(ask_secret "value for ${PROVIDER_ENV_NAME}")"
          fi
          if [ "${DERP_DNS_PROVIDER}" = "alidns" ] && [ -z "$(printenv ALICLOUD_SECRET_KEY 2>/dev/null || true)" ]; then
            ALICLOUD_SECRET_KEY="$(ask_secret "value for ALICLOUD_SECRET_KEY")"
            export ALICLOUD_SECRET_KEY
          fi
          if [ "${DERP_DNS_PROVIDER}" = "dnspod" ] && [ -z "$(printenv DNSPOD_API_TOKEN 2>/dev/null || true)" ]; then
            DNSPOD_API_TOKEN="$(ask_secret "value for DNSPOD_API_TOKEN (or leave empty if using DNSPOD_API_KEY only)")"
            [ -n "${DNSPOD_API_TOKEN}" ] && export DNSPOD_API_TOKEN
          fi
          if [ "${DERP_DNS_PROVIDER}" = "route53" ] && [ -z "$(printenv AWS_SECRET_ACCESS_KEY 2>/dev/null || true)" ]; then
            AWS_SECRET_ACCESS_KEY="$(ask_secret "value for AWS_SECRET_ACCESS_KEY")"
            export AWS_SECRET_ACCESS_KEY
          fi
        fi
        ;;
      *) die "unknown TLS mode: ${DERP_TLS_MODE}" ;;
    esac
  fi

  # ---- write derper.toml (preserve existing) ----
  if [ ! -f "${CONFIG_FILE}" ]; then
    cp "${SCRIPT_DIR}/derper.toml" "${CONFIG_FILE}"
    chmod 0644 "${CONFIG_FILE}"
    if [ -n "${DERP_HOST}" ]; then
      tmp="${CONFIG_FILE}.tmp.$$"
      sed "s/^host[[:space:]]*=.*/host = \"${DERP_HOST}\"/" "${CONFIG_FILE}" > "${tmp}"
      mv -f "${tmp}" "${CONFIG_FILE}"
    fi
    if [ -n "${DERP_TLS_MODE}" ]; then
      tmp="${CONFIG_FILE}.tmp.$$"
      sed "s/^tls_mode[[:space:]]*=.*/tls_mode = \"${DERP_TLS_MODE}\"/" "${CONFIG_FILE}" > "${tmp}"
      mv -f "${tmp}" "${CONFIG_FILE}"
    fi
    log "created config ${CONFIG_FILE}"
  else
    log "kept existing config ${CONFIG_FILE}"
  fi

  # ---- write EnvironmentFile (carries env vars, including DNS provider creds) ----
  # Always (re)write when interactive added new values; otherwise create a stub if missing.
  write_env=false
  if [ "${interactive}" = "true" ] && [ -n "${PROVIDER_ENV_NAME}" ]; then
    write_env=true
  elif [ ! -f "${ENV_FILE}" ]; then
    write_env=true
  fi

  if [ "${write_env}" = "true" ]; then
    tmp="${ENV_FILE}.tmp.$$"
    : > "${tmp}"
    chmod 0600 "${tmp}"
    {
      echo "# managed by derper install.sh; secrets live here, keep mode 0600"
      [ -n "${DERP_TLS_MODE}" ] && echo "DERP_TLS_MODE=${DERP_TLS_MODE}"
      [ -n "${DERP_HOST}" ] && echo "DERP_HOST=${DERP_HOST}"
      [ -n "${DERP_DNS_PROVIDER}" ] && echo "DERP_DNS_PROVIDER=${DERP_DNS_PROVIDER}"
      [ -n "${DERP_ACME_EMAIL}" ] && echo "DERP_ACME_EMAIL=${DERP_ACME_EMAIL}"
      if [ -n "${PROVIDER_ENV_NAME}" ] && [ -n "${PROVIDER_ENV_VALUE}" ]; then
        echo "${PROVIDER_ENV_NAME}=${PROVIDER_ENV_VALUE}"
      fi
      for v in ALICLOUD_SECRET_KEY DNSPOD_API_TOKEN AWS_SECRET_ACCESS_KEY; do
        val="$(printenv "${v}" 2>/dev/null || true)"
        [ -n "${val}" ] && echo "${v}=${val}"
      done
    } > "${tmp}"
    mv -f "${tmp}" "${ENV_FILE}"
    chmod 0600 "${ENV_FILE}"
    log "wrote ${ENV_FILE} (mode 0600)"
  fi

  # ---- decide whether to start ----
  if [ -z "${START_SERVICE}" ]; then
    if [ -n "${DERP_HOST:-}" ] || ! grep -Eq '^[[:space:]]*host[[:space:]]*=[[:space:]]*"203\.0\.113\.10"' "${CONFIG_FILE}"; then
      START_SERVICE=true
    else
      START_SERVICE=false
    fi
  fi

  # ---- systemd unit ----
  if [ -d /etc/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    if [ ! -f "${SERVICE_FILE}" ]; then
      cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Tailscale DERP relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${ENV_FILE}
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
      # ensure existing unit picks up EnvironmentFile (idempotent patch)
      if ! grep -q "EnvironmentFile=-${ENV_FILE}" "${SERVICE_FILE}"; then
        tmp="${SERVICE_FILE}.tmp.$$"
        awk -v ef="${ENV_FILE}" '
          { print }
          /^\[Service\]$/ && !done { print "EnvironmentFile=-" ef; done=1 }
        ' "${SERVICE_FILE}" > "${tmp}"
        mv -f "${tmp}" "${SERVICE_FILE}"
        chmod 0644 "${SERVICE_FILE}"
        log "patched ${SERVICE_FILE} to load ${ENV_FILE}"
      else
        log "kept existing systemd unit ${SERVICE_FILE}"
      fi
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

  log ""
  log "next steps:"
  log "  systemctl status ${SERVICE_NAME}    # service state"
  log "  ${SCRIPT_DIR}/install.sh check      # health + DERPMap snippet"
  log "  journalctl -u ${SERVICE_NAME} -f    # tail logs"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

case "${CMD}" in
  install) cmd_install ;;
  check)   cmd_check ;;
  uninstall|remove) cmd_uninstall ;;
  -h|--help|help)
    cat <<EOF
derper installer

Usage:
  sudo ./install.sh                # interactive install (or non-interactive if DERP_HOST set)
  sudo ./install.sh check          # show config + listening port + DERPMap snippet
  sudo ./install.sh uninstall      # stop service and remove binaries (keeps config and data)

Non-interactive install (CI/Ansible):
  sudo NONINTERACTIVE=1 DERP_HOST=203.0.113.10 ./install.sh
  sudo NONINTERACTIVE=1 DERP_TLS_MODE=dns01 DERP_HOST=derp.example.com \\
       DERP_DNS_PROVIDER=cloudflare DERP_ACME_EMAIL=ops@example.com \\
       CLOUDFLARE_DNS_API_TOKEN=xxxx ./install.sh
EOF
    ;;
  *) die "unknown command: ${CMD} (try: install / check / uninstall / help)" ;;
esac
