#!/bin/sh
# derper one-shot bootstrap installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/xjoker/tailscale-derper/main/scripts/install.sh | sudo sh
#
# What it does:
#   1. detect CPU arch (amd64 / arm64)
#   2. resolve latest release tarball URL via GitHub API
#   3. download to /tmp, verify SHA256 if SHA256SUMS is published
#   4. extract and hand off to the bundled install.sh wizard
#
# Override knobs (env):
#   REPO       fork owner/name        default xjoker/tailscale-derper
#   GH_TOKEN   bump GitHub API rate limit from 60/h to 5000/h
#   DERP_AUTO  =1 + DERP_HOST etc. → skip wizard (CI / Ansible)

set -eu

REPO="${REPO:-xjoker/tailscale-derper}"

log()  { printf '>>> %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行：curl -fsSL ... | sudo sh"
command -v curl >/dev/null 2>&1 || die "需要 curl"
command -v tar  >/dev/null 2>&1 || die "需要 tar"

case "$(uname -s)" in
  Linux) ;;
  *) die "仅支持 Linux，当前: $(uname -s)" ;;
esac

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的架构: $(uname -m)" ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT INT TERM

API="https://api.github.com/repos/${REPO}/releases/latest"
AUTH=""
[ -n "${GH_TOKEN:-}" ] && AUTH="-H Authorization:Bearer ${GH_TOKEN}"

log "解析 ${REPO} 最新 release（linux-${ARCH}）"
META="$(curl -fsSL ${AUTH} "${API}")" \
  || die "调用 GitHub API 失败；可设 GH_TOKEN 提升限频"

URL="$(printf '%s' "${META}" | grep -oE "https://[^\"]+linux-${ARCH}\.tar\.gz" | head -n1)"
[ -n "${URL}" ] || die "未在最新 release 中找到 linux-${ARCH} tarball"

TARBALL="${TMP}/$(basename "${URL}")"
log "下载 ${URL}"
curl -fsSL -o "${TARBALL}" "${URL}"

SUMS_URL="$(printf '%s' "${META}" | grep -oE "https://[^\"]+/SHA256SUMS" | head -n1)"
if [ -n "${SUMS_URL}" ] && command -v sha256sum >/dev/null 2>&1; then
  log "校验 SHA256"
  curl -fsSL -o "${TMP}/SHA256SUMS" "${SUMS_URL}"
  ( cd "${TMP}" && grep "$(basename "${URL}")" SHA256SUMS | sha256sum -c - >/dev/null ) \
    || die "SHA256 校验失败"
else
  printf 'warn: 未找到 SHA256SUMS 或缺 sha256sum，跳过校验\n' >&2
fi

log "解压"
tar -xzf "${TARBALL}" -C "${TMP}"
DIR="$(find "${TMP}" -maxdepth 1 -mindepth 1 -type d -name "derper-*-linux-${ARCH}" | head -n1)"
[ -n "${DIR}" ] && [ -d "${DIR}" ] || die "解压目录未找到"

log "启动安装向导"
cd "${DIR}"
sh ./install.sh
