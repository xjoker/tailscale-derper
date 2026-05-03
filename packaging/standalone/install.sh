#!/bin/sh
set -eu
umask 022

# ===========================================================================
# derper installer — pure wizard
#
# Usage:
#   sudo ./install.sh             interactive install
#   sudo ./install.sh check       health probe + DERPMap snippet
#   sudo ./install.sh uninstall   stop and remove (keeps config + data)
#
# Hidden batch mode (for CI / Ansible — not advertised):
#   DERP_AUTO=1 plus DERP_HOST, optionally DERP_DNS_PROVIDER, DERP_ACME_EMAIL,
#   and the lego env vars (e.g. CLOUDFLARE_DNS_API_TOKEN).
# ===========================================================================

log()  { printf '%s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

is_ip() {
  case "$1" in
    *:*:*) printf '%s' "$1" | grep -Eq '^[0-9a-fA-F:]+$' ;;
    *.*.*.*) printf '%s' "$1" | grep -Eq '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$' ;;
    *) return 1 ;;
  esac
}

to_bool() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

ask() {
  prompt="$1"; default="${2:-}"
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
  printf '%s: ' "$1" >&2
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
      printf '%s' "${ip}"; return 0
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

CMD="${1:-install}"

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------

cmd_uninstall() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行: sudo ./install.sh uninstall"
  if command -v systemctl >/dev/null 2>&1 && [ -f "${SERVICE_FILE}" ]; then
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload 2>/dev/null || true
    log "已移除 ${SERVICE_FILE}"
  fi
  rm -f "${BIN_DIR}/derper" "${BIN_DIR}/lego" "${BIN_DIR}/derper-run" "${BIN_DIR}/derper-installer"
  log "已移除 ${BIN_DIR} 下的 binaries"
  log "保留 ${CONFIG_DIR} 与 ${DATA_DIR}（如需彻底清理: sudo rm -rf ${CONFIG_DIR} ${DATA_DIR}）"
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
  verify=""; sock=""
  if [ -f "${CONFIG_FILE}" ]; then
    verify="$(awk -F'=' '/^[[:space:]]*verify_clients[[:space:]]*=/{gsub(/[" ]/,"",$2); print $2; exit}' "${CONFIG_FILE}")"
    sock="$(awk -F'=' '/^[[:space:]]*socket[[:space:]]*=/{gsub(/[" ]/,"",$2); print $2; exit}' "${CONFIG_FILE}")"
  fi
  log "host:    ${host:-(unset)}"
  log "mode:    ${mode:-(unset)}"
  log "addr:    ${addr}"
  if [ "${verify}" = "true" ]; then
    if [ -n "${sock}" ] && [ -S "${sock}" ]; then
      log "access:  PRIVATE (verify_clients via ${sock} OK)"
    else
      log "access:  PRIVATE (verify_clients enabled, but ${sock:-sock} missing — derper 拒所有连接); status=1"
      status=1
    fi
  else
    log "access:  OPEN (任何 Tailscale 客户端可中继)"
  fi

  if command -v systemctl >/dev/null 2>&1 && [ -f "${SERVICE_FILE}" ]; then
    state="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
    log "systemd: ${state}"
    [ "${state}" = "active" ] || status=1
  fi

  port="${addr#*:}"; [ -z "${port}" ] && port=443
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
# wizard prompts (one host question infers mode)
# ---------------------------------------------------------------------------

wizard_host() {
  log ""
  log "[1] derper 节点对外的 IP 或域名"
  log "    - 输入 IP        → 自签证书模式（无需域名，适合纯 IP 节点）"
  log "    - 输入域名       → Let's Encrypt + DNS-01 自动申请证书"
  default="${DERP_HOST:-}"
  if [ -z "${default}" ]; then
    default="$(detect_public_ip || true)"
    [ -n "${default}" ] && log "    检测到本机公网 IP: ${default}"
  fi
  while :; do
    DERP_HOST="$(ask "    IP 或域名" "${default}")"
    if [ -z "${DERP_HOST}" ]; then
      log "    不能为空"
      continue
    fi
    if is_ip "${DERP_HOST}"; then
      DERP_TLS_MODE=ip
      log "    → 模式: ip（自签证书）"
      break
    elif printf '%s' "${DERP_HOST}" | grep -Eq '^[A-Za-z0-9._-]+\.[A-Za-z]{2,}$'; then
      DERP_TLS_MODE=dns01
      log "    → 模式: dns01（DNS-01 自动申请）"
      break
    else
      log "    格式无效，请输入 IPv4/IPv6 或域名"
    fi
  done
}

ask_port() {
  prompt="$1"; default="$2"
  while :; do
    p="$(ask "${prompt}" "${default}")"
    case "${p}" in
      ''|*[!0-9]*) log "    端口必须为数字"; continue ;;
    esac
    if [ "${p}" -ge 1 ] 2>/dev/null && [ "${p}" -le 65535 ]; then
      printf '%s' "${p}"; return 0
    fi
    log "    端口必须在 1-65535 之间"
  done
}

port_in_use() {
  proto="$1"; port="$2"
  command -v ss >/dev/null 2>&1 || return 1
  case "${proto}" in
    tcp) ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$" ;;
    udp) ss -lnuH 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$" ;;
  esac
}

wizard_ports() {
  log ""
  log "[2] HTTPS 监听端口（DERP 流量）"
  log "    443 是默认；被占用时可改 8443/8444 等。Tailscale 节点需在 DERPMap 用同一端口"
  default_addr="${DERP_ADDR:-:443}"
  default_port="${default_addr#*:}"
  while :; do
    p="$(ask_port "    端口" "${default_port}")"
    if port_in_use tcp "${p}"; then
      log "    警告: TCP :${p} 当前已被占用，启动会失败"
      ans="$(ask "    仍使用该端口？[y/N]" "N")"
      case "${ans}" in y|Y|yes|YES) ;; *) continue ;; esac
    fi
    DERP_ADDR=":${p}"
    break
  done

  log ""
  log "[3] STUN 端口（UDP，NAT 探测）"
  log "    3478 是默认；同一公网 IP 跑多个 derper 时改成不同端口"
  default_stun="${DERP_STUN_PORT:-3478}"
  while :; do
    sp="$(ask_port "    端口" "${default_stun}")"
    if port_in_use udp "${sp}"; then
      log "    警告: UDP :${sp} 当前已被占用，启动会失败"
      ans="$(ask "    仍使用该端口？[y/N]" "N")"
      case "${ans}" in y|Y|yes|YES) ;; *) continue ;; esac
    fi
    DERP_STUN_PORT="${sp}"
    break
  done
}

wizard_access() {
  log ""
  log "[4] 访问控制"
  log "    默认：私有（仅本 Tailnet 客户端可中继；通过本机 tailscaled 校验公钥）"

  DETECTED_SOCK=""
  for s in /var/run/tailscale/tailscaled.sock /run/tailscale/tailscaled.sock; do
    if [ -S "${s}" ]; then DETECTED_SOCK="${s}"; break; fi
  done

  if [ -n "${DETECTED_SOCK}" ]; then
    log "    ✓ 检测到 ${DETECTED_SOCK}，启用 verify_clients"
    log "    注意：tailscaled 需与 derper 来自同一 Tailscale revision，否则可能拒所有客户端"
    DERP_VERIFY_CLIENTS=true
    DERP_SOCKET="${DETECTED_SOCK}"
    return
  fi

  log "    ✗ 未检测到 tailscaled.sock"
  log "    要私有需先装 tailscaled 并加入你的 Tailnet:"
  log "      curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up"
  log ""
  log "    选择:"
  log "      1) 私有（推荐；先装 tailscaled，再 sudo derper-installer 重跑向导）"
  log "      2) 开放（任何 Tailscale 客户端可中继；会消耗带宽）"
  while :; do
    sel="$(ask "    选择" "1")"
    case "${sel}" in
      1)
        DERP_VERIFY_CLIENTS=true
        DERP_SOCKET=/var/run/tailscale/tailscaled.sock
        log "    → 私有。本次启动可能因 sock 缺失被拒；装完 tailscaled 后:"
        log "      sudo systemctl restart derper"
        break
        ;;
      2)
        DERP_VERIFY_CLIENTS=false
        DERP_SOCKET=""
        log "    → 开放"
        break
        ;;
      *) log "    输入 1 或 2" ;;
    esac
  done
}

wizard_dns01() {
  log ""
  log "[5] DNS 服务商（用于 DNS-01 验证）"
  log "      1) cloudflare"
  log "      2) alidns      （阿里云 DNS）"
  log "      3) dnspod      （腾讯云 DNS）"
  log "      4) route53     （AWS）"
  log "      5) gcloud      （Google Cloud DNS）"
  log "      6) 其他        （手动输入 lego provider 名）"
  while :; do
    sel="$(ask "    选择" "1")"
    case "${sel}" in
      1|cloudflare) DERP_DNS_PROVIDER=cloudflare; PRIMARY=CLOUDFLARE_DNS_API_TOKEN; SECONDARIES=""; break ;;
      2|alidns)     DERP_DNS_PROVIDER=alidns;     PRIMARY=ALICLOUD_ACCESS_KEY;       SECONDARIES=ALICLOUD_SECRET_KEY; break ;;
      3|dnspod)     DERP_DNS_PROVIDER=dnspod;     PRIMARY=DNSPOD_API_KEY;            SECONDARIES=""; break ;;
      4|route53)    DERP_DNS_PROVIDER=route53;    PRIMARY=AWS_ACCESS_KEY_ID;         SECONDARIES=AWS_SECRET_ACCESS_KEY; break ;;
      5|gcloud)     DERP_DNS_PROVIDER=gcloud;     PRIMARY=GCE_PROJECT;               SECONDARIES=""; break ;;
      6|other)
        DERP_DNS_PROVIDER="$(ask "    lego provider 名" "")"
        [ -z "${DERP_DNS_PROVIDER}" ] && { log "    不能为空"; continue; }
        log "    见 https://go-acme.github.io/lego/dns/ 查该 provider 所需环境变量名"
        PRIMARY="$(ask "    主凭据环境变量名（如 CLOUDFLARE_DNS_API_TOKEN）" "")"
        SECONDARIES="$(ask "    其他环境变量名（空格分隔，可留空）" "")"
        break
        ;;
      *) log "    请输入 1-6" ;;
    esac
  done

  log ""
  log "[5.1] 凭据"
  existing="$(eval printf '%s' \"\${${PRIMARY}:-}\")"
  if [ -n "${existing}" ]; then
    ans="$(ask "    检测到现有 ${PRIMARY}，沿用？[Y/n]" "Y")"
    case "${ans}" in
      n|N|no|NO) PRIMARY_VAL="$(ask_secret "    ${PRIMARY}")" ;;
      *)         PRIMARY_VAL="${existing}" ;;
    esac
  else
    PRIMARY_VAL="$(ask_secret "    ${PRIMARY}")"
  fi
  [ -z "${PRIMARY_VAL}" ] && die "凭据不能为空"

  SEC_PAIRS=""
  for v in ${SECONDARIES}; do
    existing="$(eval printf '%s' \"\${${v}:-}\")"
    if [ -n "${existing}" ]; then
      ans="$(ask "    检测到现有 ${v}，沿用？[Y/n]" "Y")"
      case "${ans}" in
        n|N|no|NO) val="$(ask_secret "    ${v}")" ;;
        *)         val="${existing}" ;;
      esac
    else
      val="$(ask_secret "    ${v}")"
    fi
    SEC_PAIRS="${SEC_PAIRS}${v}=${val}
"
  done

  log ""
  log "[5.2] Let's Encrypt 联系邮箱（仅用于续期失败通知）"
  while :; do
    DERP_ACME_EMAIL="$(ask "    邮箱" "${DERP_ACME_EMAIL:-}")"
    [ -n "${DERP_ACME_EMAIL}" ] && break
    log "    不能为空"
  done
}

wizard_start() {
  ans="$(ask "立即启动 systemd 服务？[Y/n]" "Y")"
  case "${ans}" in
    n|N|no|NO) START_NOW=false ;;
    *)         START_NOW=true ;;
  esac
}

load_existing_env() {
  [ -f "${ENV_FILE}" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}" 2>/dev/null || true
  set +a
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------

cmd_install() {
  [ "$(id -u)" = "0" ] || die "请用 root 运行: sudo ./install.sh"
  [ -x "${SCRIPT_DIR}/derper" ]    || die "缺少 derper 二进制"
  [ -x "${SCRIPT_DIR}/lego" ]      || die "缺少 lego 二进制"
  [ -x "${SCRIPT_DIR}/derper-run" ]|| die "缺少 derper-run 脚本"
  [ -f "${SCRIPT_DIR}/derper.toml" ]|| die "缺少 derper.toml 模板"

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
      *" debian "*|*" ubuntu "*|*" rhel "*|*" centos "*|*" fedora "*) ;;
      *) warn "未测试过的发行版: ${ID:-unknown}，继续安装" ;;
    esac
  fi

  mkdir -p "${BIN_DIR}" "${CONFIG_DIR}" "${DATA_DIR}" \
    "${DATA_DIR}/certs" "${DATA_DIR}/acme" "${DATA_DIR}/cache"

  # 覆盖安装：先停旧服务，避免端口被自己占住造成探测误报
  if command -v systemctl >/dev/null 2>&1 && [ -f "${SERVICE_FILE}" ]; then
    if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
      systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
      log "已停止旧 ${SERVICE_NAME}.service，将以新配置启动"
    fi
  fi

  copy_exec() {
    src="$1"; dest="$2"; tmp="${dest}.tmp.$$"
    cp "${src}" "${tmp}"; chmod 0755 "${tmp}"; mv -f "${tmp}" "${dest}"
  }
  copy_exec "${SCRIPT_DIR}/derper"     "${BIN_DIR}/derper"
  copy_exec "${SCRIPT_DIR}/lego"       "${BIN_DIR}/lego"
  copy_exec "${SCRIPT_DIR}/derper-run" "${BIN_DIR}/derper-run"
  copy_exec "${SCRIPT_DIR}/install.sh" "${BIN_DIR}/derper-installer"
  log "已更新 ${BIN_DIR} 下的 binaries"

  # ---- decide: wizard or batch ----
  load_existing_env
  PRIMARY=""; PRIMARY_VAL=""; SEC_PAIRS=""; DERP_TLS_MODE=""
  : "${DERP_HOST:=}"; : "${DERP_DNS_PROVIDER:=}"; : "${DERP_ACME_EMAIL:=}"
  : "${DERP_ADDR:=}"; : "${DERP_STUN_PORT:=}"
  : "${DERP_VERIFY_CLIENTS:=}"; : "${DERP_SOCKET:=}"
  START_NOW=true

  if to_bool "${DERP_AUTO:-}"; then
    [ -n "${DERP_HOST}" ] || die "DERP_AUTO=1 时必须设 DERP_HOST"
    if is_ip "${DERP_HOST}"; then
      DERP_TLS_MODE=ip
    else
      DERP_TLS_MODE=dns01
      [ -n "${DERP_DNS_PROVIDER}" ] || die "dns01 模式需要 DERP_DNS_PROVIDER"
      [ -n "${DERP_ACME_EMAIL}" ]   || die "dns01 模式需要 DERP_ACME_EMAIL"
    fi
    : "${DERP_ADDR:=:443}"
    : "${DERP_STUN_PORT:=3478}"
    : "${DERP_VERIFY_CLIENTS:=false}"
  else
    [ -r /dev/tty ] || die "向导需要 tty；批量部署请用 DERP_AUTO=1（见脚本顶部注释）"
    hr
    if [ -f "${ENV_FILE}" ]; then
      log "derper 安装向导（检测到现有配置，回车保留旧值）"
    else
      log "derper 安装向导"
    fi
    hr
    wizard_host
    wizard_ports
    wizard_access
    if [ "${DERP_TLS_MODE}" = "dns01" ]; then
      wizard_dns01
    fi
    log ""
    wizard_start
  fi

  # ---- write derper.toml ----
  if [ ! -f "${CONFIG_FILE}" ]; then
    cp "${SCRIPT_DIR}/derper.toml" "${CONFIG_FILE}"
    chmod 0644 "${CONFIG_FILE}"
  fi
  tmp="${CONFIG_FILE}.tmp.$$"
  sed \
    -e "s|^host[[:space:]]*=.*|host = \"${DERP_HOST}\"|" \
    -e "s|^tls_mode[[:space:]]*=.*|tls_mode = \"${DERP_TLS_MODE}\"|" \
    -e "s|^addr[[:space:]]*=.*|addr = \"${DERP_ADDR}\"|" \
    -e "s|^stun_port[[:space:]]*=.*|stun_port = ${DERP_STUN_PORT}|" \
    -e "s|^verify_clients[[:space:]]*=.*|verify_clients = ${DERP_VERIFY_CLIENTS}|" \
    -e "s|^socket[[:space:]]*=.*|socket = \"${DERP_SOCKET}\"|" \
    "${CONFIG_FILE}" > "${tmp}"
  mv -f "${tmp}" "${CONFIG_FILE}"
  log "写入配置 ${CONFIG_FILE}"

  # ---- write env file (always overwrite when wizard ran with new values) ----
  tmp="${ENV_FILE}.tmp.$$"
  : > "${tmp}"; chmod 0600 "${tmp}"
  {
    echo "# 由 install.sh 生成；含 DNS-01 凭据，保持 mode 0600"
    echo "DERP_TLS_MODE=${DERP_TLS_MODE}"
    echo "DERP_HOST=${DERP_HOST}"
    echo "DERP_ADDR=${DERP_ADDR}"
    echo "DERP_STUN_PORT=${DERP_STUN_PORT}"
    echo "DERP_VERIFY_CLIENTS=${DERP_VERIFY_CLIENTS}"
    echo "DERP_SOCKET=${DERP_SOCKET}"
    if [ "${DERP_TLS_MODE}" = "dns01" ]; then
      echo "DERP_DNS_PROVIDER=${DERP_DNS_PROVIDER}"
      echo "DERP_ACME_EMAIL=${DERP_ACME_EMAIL}"
      if [ -n "${PRIMARY}" ] && [ -n "${PRIMARY_VAL}" ]; then
        echo "${PRIMARY}=${PRIMARY_VAL}"
      fi
      if [ -n "${SEC_PAIRS}" ]; then
        printf '%s' "${SEC_PAIRS}"
      fi
      # batch mode: pull lego env vars from process env if user set them there
      if to_bool "${DERP_AUTO:-}"; then
        for v in CLOUDFLARE_DNS_API_TOKEN ALICLOUD_ACCESS_KEY ALICLOUD_SECRET_KEY \
                 DNSPOD_API_KEY DNSPOD_API_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
                 GCE_PROJECT GCE_SERVICE_ACCOUNT_FILE; do
          val="$(printenv "${v}" 2>/dev/null || true)"
          [ -n "${val}" ] && echo "${v}=${val}"
        done
      fi
    fi
  } > "${tmp}"
  mv -f "${tmp}" "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
  log "写入凭据 ${ENV_FILE} (0600)"

  # ---- systemd unit ----
  if [ -d /etc/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
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
    log "写入 systemd 单元 ${SERVICE_FILE}"

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true

    if [ "${START_NOW}" = "true" ]; then
      if systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        systemctl restart "${SERVICE_NAME}.service"
        log "已重启 ${SERVICE_NAME}.service"
      else
        systemctl start "${SERVICE_NAME}.service"
        log "已启动 ${SERVICE_NAME}.service"
      fi
    else
      log "已安装但未启动；启动: sudo systemctl start ${SERVICE_NAME}"
    fi
  else
    log "未检测到 systemd；可手动运行: DERPER_CONFIG_FILE=${CONFIG_FILE} ${BIN_DIR}/derper-run"
  fi

  log ""
  hr; log "完成"; hr
  log "  状态:    sudo systemctl status ${SERVICE_NAME}"
  log "  日志:    sudo journalctl -u ${SERVICE_NAME} -f"
  log "  体检:    sudo derper-installer check     （含 DERPMap 片段）"
  log "  改配置:  sudo derper-installer           （重跑向导，覆盖现有配置）"
  log "  卸载:    sudo derper-installer uninstall"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

case "${CMD}" in
  install)          cmd_install ;;
  check)            cmd_check ;;
  uninstall|remove) cmd_uninstall ;;
  -h|--help|help)
    cat <<EOF
derper 安装器

  sudo ./install.sh             向导式安装（默认）
  sudo ./install.sh check       体检：配置、监听端口、证书指纹、DERPMap 片段
  sudo ./install.sh uninstall   停服务并移除 binaries（保留配置和数据）
EOF
    ;;
  *) die "未知命令: ${CMD}（可用: install / check / uninstall / help）" ;;
esac
