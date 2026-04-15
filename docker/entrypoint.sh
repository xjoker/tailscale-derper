#!/bin/sh
set -eu

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

read_toml() {
  [ -f "${DERPER_CONFIG_FILE}" ] || return 0
  awk -v section="$1" -v key="$2" '
    /^[[:space:]]*\[/ { current=$0; gsub(/[[:space:]\[\]]/, "", current); next }
    current==section {
      line=$0
      if (line ~ "^[[:space:]]*" key "[[:space:]]*=") {
        sub(/^[^=]*=[[:space:]]*/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line ~ /^".*"$/) {
          line=substr(line, 2, length(line)-2)
        } else if (line ~ /^'\''.*'\''$/) {
          line=substr(line, 2, length(line)-2)
        } else {
          sub(/[[:space:]]+#.*$/, "", line)
        }
        print line
        exit
      }
    }
  ' "${DERPER_CONFIG_FILE}"
}

set_from_config() {
  var="$1"
  current="$(printenv "$var" 2>/dev/null || true)"
  [ -n "${current}" ] && return 0
  value="$(read_toml "$2" "$3")"
  [ -z "${value}" ] && return 0
  export "${var}=${value}"
}

is_ip() {
  case "$1" in
    *:*:*)
      # IPv6: 2+ colons, all chars hex digits or colons
      printf '%s' "$1" | grep -Eq '^[0-9a-fA-F:]+$'
      ;;
    *.*.*.*)
      # IPv4: four dot-separated octets 0-255
      printf '%s' "$1" | grep -Eq '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
      ;;
    *)
      return 1
      ;;
  esac
}

to_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# lego helper (dns01 mode)
# ---------------------------------------------------------------------------

run_lego() {
  set -- lego --accept-tos --email "${DERP_ACME_EMAIL}" --dns "${DERP_DNS_PROVIDER}" \
    --domains "${DERP_HOST}" --path "${DERP_ACME_PATH}"
  to_bool "${DERP_ACME_STAGING}" && set -- "$@" --server "https://acme-staging-v02.api.letsencrypt.org/directory"

  if [ -f "${DERP_ACME_PATH}/certificates/${DERP_HOST}.crt" ] && \
     [ -f "${DERP_ACME_PATH}/certificates/${DERP_HOST}.key" ]; then
    "$@" renew --days 30
  else
    "$@" run
  fi

  cp "${DERP_ACME_PATH}/certificates/${DERP_HOST}.crt" "${DERP_CERT_DIR}/${DERP_HOST}.crt"
  cp "${DERP_ACME_PATH}/certificates/${DERP_HOST}.key" "${DERP_CERT_DIR}/${DERP_HOST}.key"
}

# ---------------------------------------------------------------------------
# config loading: env > config file > defaults
# ---------------------------------------------------------------------------

set_from_config DERP_TLS_MODE        derper tls_mode
set_from_config DERP_HOST            derper host
set_from_config DERP_ADDR            derper addr
set_from_config DERP_STUN            derper stun
set_from_config DERP_STUN_PORT       derper stun_port
set_from_config DERP_HTTP_PORT       derper http_port
set_from_config DERP_CERT_DIR        derper cert_dir
set_from_config DERP_VERIFY_CLIENTS  derper verify_clients
set_from_config DERP_VERIFY_CLIENT_URL derper verify_client_url
set_from_config DERP_DNS_PROVIDER    dns01 provider
set_from_config DERP_ACME_EMAIL      dns01 email
set_from_config DERP_ACME_PATH       dns01 acme_path
set_from_config DERP_ACME_STAGING    dns01 staging
set_from_config DERP_RENEWAL_INTERVAL dns01 renewal_interval

: "${DERP_TLS_MODE:=ip}"
: "${DERP_HOST:=}"
: "${DERP_ADDR:=:443}"
: "${DERP_STUN:=true}"
: "${DERP_STUN_PORT:=3478}"
: "${DERP_HTTP_PORT:=-1}"
: "${DERP_CERT_DIR:=/var/lib/derper/certs}"
: "${DERP_VERIFY_CLIENTS:=false}"
: "${DERP_VERIFY_CLIENT_URL:=}"
: "${DERP_DNS_PROVIDER:=}"
: "${DERP_ACME_EMAIL:=}"
: "${DERP_ACME_PATH:=/var/lib/derper/acme}"
: "${DERP_ACME_STAGING:=false}"
: "${DERP_RENEWAL_INTERVAL:=43200}"

# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

[ -n "${DERP_HOST}" ] || { log "DERP_HOST 未设置"; exit 1; }
mkdir -p "${DERP_CERT_DIR}" "${DERP_ACME_PATH}"

case "${DERP_TLS_MODE}" in
  ip)
    is_ip "${DERP_HOST}" || { log "ip 模式要求 DERP_HOST 为 IP 地址"; exit 1; }
    CERT_FILE="${DERP_CERT_DIR}/${DERP_HOST}.crt"
    if [ -f "${CERT_FILE}" ]; then
      FP="$(openssl x509 -in "${CERT_FILE}" -outform DER 2>/dev/null \
        | openssl dgst -sha256 -binary \
        | base64)"
      log "现有证书 SHA-256 指纹: ${FP}"
      log "DERPMap 配置: \"CertName\": \"sha256-raw:${FP}\""
    else
      log "首次运行，derper 将生成 IP 自签证书"
      log "重启后可在此处查看指纹，或运行: docker logs <container> | grep sha256-raw"
    fi
    log "使用 ip 模式，证书将由 derper 按需生成或复用"
    ;;
  dns01)
    is_ip "${DERP_HOST}" && { log "dns01 模式要求 DERP_HOST 为域名"; exit 1; }
    [ -n "${DERP_DNS_PROVIDER}" ] || { log "dns01 模式缺少 DERP_DNS_PROVIDER"; exit 1; }
    [ -n "${DERP_ACME_EMAIL}" ]   || { log "dns01 模式缺少 DERP_ACME_EMAIL"; exit 1; }
    log "使用 dns01 模式申请/续期证书"
    run_lego
    ;;
  *)
    log "不支持的 DERP_TLS_MODE: ${DERP_TLS_MODE}"
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# normalize booleans for derper flags
# ---------------------------------------------------------------------------

to_bool "${DERP_STUN}"           && DERP_STUN=true           || DERP_STUN=false
to_bool "${DERP_VERIFY_CLIENTS}" && DERP_VERIFY_CLIENTS=true || DERP_VERIFY_CLIENTS=false

# ---------------------------------------------------------------------------
# start derper
# ---------------------------------------------------------------------------

log "启动 derper: host=${DERP_HOST} addr=${DERP_ADDR} stun=${DERP_STUN_PORT} mode=${DERP_TLS_MODE}"

case "${DERP_TLS_MODE}" in
  ip)
    set -- derper \
      "-hostname=${DERP_HOST}" \
      "-a=${DERP_ADDR}" \
      "-certmode=manual" \
      "-certdir=${DERP_CERT_DIR}" \
      "-stun=${DERP_STUN}" \
      "-stun-port=${DERP_STUN_PORT}" \
      "-http-port=${DERP_HTTP_PORT}" \
      "-verify-clients=${DERP_VERIFY_CLIENTS}"
    [ -n "${DERP_VERIFY_CLIENT_URL}" ] && set -- "$@" "-verify-client-url=${DERP_VERIFY_CLIENT_URL}"
    exec "$@"
    ;;
  dns01)
    # dns01 模式: 后台运行 derper + 定时续期循环
    DERPER_PID=""

    cleanup() {
      if [ -n "${DERPER_PID}" ] && kill -0 "${DERPER_PID}" 2>/dev/null; then
        log "收到终止信号，停止 derper (PID ${DERPER_PID})"
        kill -TERM "${DERPER_PID}" 2>/dev/null
        wait "${DERPER_PID}" 2>/dev/null || true
      fi
      exit 0
    }
    trap cleanup TERM INT

    start_derper() {
      set -- derper \
        "-hostname=${DERP_HOST}" \
        "-a=${DERP_ADDR}" \
        "-certmode=manual" \
        "-certdir=${DERP_CERT_DIR}" \
        "-stun=${DERP_STUN}" \
        "-stun-port=${DERP_STUN_PORT}" \
        "-http-port=${DERP_HTTP_PORT}" \
        "-verify-clients=${DERP_VERIFY_CLIENTS}"
      [ -n "${DERP_VERIFY_CLIENT_URL}" ] && set -- "$@" "-verify-client-url=${DERP_VERIFY_CLIENT_URL}"
      "$@" &
      DERPER_PID=$!
      log "derper 已启动 (PID ${DERPER_PID})"
    }

    start_derper

    while true; do
      elapsed=0
      while [ "${elapsed}" -lt "${DERP_RENEWAL_INTERVAL}" ]; do
        sleep 60 &
        SLEEP_PID=$!
        wait "${SLEEP_PID}" 2>/dev/null || true

        # 检测 derper 是否意外退出
        if ! kill -0 "${DERPER_PID}" 2>/dev/null; then
          EXIT_CODE=0
          wait "${DERPER_PID}" 2>/dev/null || EXIT_CODE=$?
          log "derper 意外退出 (exit code: ${EXIT_CODE})"
          exit "${EXIT_CODE}"
        fi

        elapsed=$((elapsed + 60))
      done

      log "检查证书续期..."
      if run_lego; then
        log "证书续期成功，重启 derper"
        kill -TERM "${DERPER_PID}" 2>/dev/null
        wait "${DERPER_PID}" 2>/dev/null || true
        start_derper
      else
        log "证书未到续期窗口或续期失败，derper 继续运行"
      fi
    done
    ;;
esac
