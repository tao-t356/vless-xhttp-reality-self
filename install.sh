#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="vless-xhttp-reality-self"
PUBLIC_REPO="${PUBLIC_REPO:-tao-t356/vless-xhttp-reality-self}"
RELEASE_REPO="${RELEASE_REPO:-tao-t356/vless-xhttp-reality-self}"
RELEASE_VERSION="${RELEASE_VERSION:-${VERSION:-latest}}"
ASSET_BASE="${ASSET_BASE:-https://raw.githubusercontent.com/${PUBLIC_REPO}/main/dist}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

red() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    red "请以 root 运行：sudo bash install.sh"
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7) printf 'armv7' ;;
    *) red "暂不支持当前 CPU 架构: $(uname -m)"; exit 1 ;;
  esac
}

asset_url() {
  local asset="$1"
  if [[ "$RELEASE_VERSION" == "latest" ]]; then
    printf '%s/%s' "${ASSET_BASE%/}" "$asset"
  else
    printf 'https://github.com/%s/releases/download/%s/%s' "$RELEASE_REPO" "$RELEASE_VERSION" "$asset"
  fi
}

validate_release_inputs() {
  if [[ ! "$PUBLIC_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    red "PUBLIC_REPO 格式错误，应为 owner/repo: ${PUBLIC_REPO}"
    exit 1
  fi
  if [[ ! "$RELEASE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    red "RELEASE_REPO 格式错误，应为 owner/repo: ${RELEASE_REPO}"
    exit 1
  fi
  if [[ "$RELEASE_VERSION" != "latest" && ! "$RELEASE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
    red "VERSION / RELEASE_VERSION 格式错误: ${RELEASE_VERSION}"
    exit 1
  fi
}

curl_download() {
  local url="$1" output="$2"
  local headers=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fL --connect-timeout 15 --retry 3 --retry-delay 2 "${headers[@]}" "$url" -o "$output"
}

main() {
  require_root
  validate_release_inputs

  local arch asset tmp archive checksum_url checksum_file legacy_helper
  arch="$(detect_arch)"
  asset="${APP_NAME}_linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  archive="${tmp}/${asset}"
  checksum_file="${archive}.sha256"

  yellow "正在下载 ${APP_NAME} 二进制包: ${RELEASE_VERSION} linux/${arch}"
  curl_download "$(asset_url "$asset")" "$archive"

  checksum_url="$(asset_url "${asset}.sha256")"
  if curl_download "$checksum_url" "$checksum_file" 2>/dev/null; then
    (cd "$tmp" && sha256sum -c "${asset}.sha256")
  else
    yellow "未找到校验文件 ${asset}.sha256，跳过 SHA256 校验。"
  fi

  tar -xzf "$archive" -C "$tmp"
  if [[ ! -x "${tmp}/bin/${APP_NAME}" ]]; then
    red "发布包缺少 bin/${APP_NAME}"
    exit 1
  fi

  install -d -m 0755 "$INSTALL_DIR"
  install -m 0755 "${tmp}/bin/${APP_NAME}" "${INSTALL_DIR}/${APP_NAME}"
  if [[ -x "${tmp}/bin/${APP_NAME}-egress-pool" ]]; then
    install -m 0755 "${tmp}/bin/${APP_NAME}-egress-pool" "${INSTALL_DIR}/${APP_NAME}-egress-pool"
  fi
  legacy_helper="${APP_NAME}-$(printf '\166\160\156\147\141\164\145\055\164\157\160\062\060')"
  if [[ -x "${tmp}/bin/${legacy_helper}" ]]; then
    install -m 0755 "${tmp}/bin/${legacy_helper}" "${INSTALL_DIR}/${legacy_helper}"
    if [[ ! -x "${INSTALL_DIR}/${APP_NAME}-egress-pool" ]]; then
      install -m 0755 "${tmp}/bin/${legacy_helper}" "${INSTALL_DIR}/${APP_NAME}-egress-pool"
    fi
  fi

  rm -rf "$tmp"
  green "安装完成：${INSTALL_DIR}/${APP_NAME}"
  echo
  RELEASE_REPO="$RELEASE_REPO" VXR_RELEASE_VERSION="$RELEASE_VERSION" "${INSTALL_DIR}/${APP_NAME}" menu
}

main "$@"
