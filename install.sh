#!/usr/bin/env bash
set -Eeuo pipefail

PRIVATE_REPO="${PRIVATE_REPO:-tao-t356/vless-xhttp-reality-self-private}"
PRIVATE_REF="${PRIVATE_REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-/root/vless-xhttp-reality-self}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: $1 is required" >&2
    exit 1
  }
}

if [[ -z "$TOKEN" ]]; then
  echo "这个公开入口只负责启动安装；完整脚本在私有仓库，不会公开源码。"
  echo "请输入有私有仓库读取权限的 GitHub Token。输入时不会显示。"
  read -r -s -p "GitHub Token: " TOKEN
  echo
fi

if [[ -z "$TOKEN" ]]; then
  echo "error: GitHub Token is required for the private installer" >&2
  exit 1
fi

need_cmd curl
need_cmd tar
need_cmd mktemp

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

echo "正在下载私有安装包..."
curl -fsSL \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${PRIVATE_REPO}/tarball/${PRIVATE_REF}" \
  -o "${tmp}/repo.tar.gz"

mkdir -p "$INSTALL_DIR"
resolved_dir="$(cd "$INSTALL_DIR" && pwd)"
case "$resolved_dir" in
  /root/vless-xhttp-reality-self|/opt/vless-xhttp-reality-self|/tmp/vless-xhttp-reality-self*)
    find "$resolved_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    ;;
  *)
    echo "error: refusing to clean unexpected INSTALL_DIR: $resolved_dir" >&2
    exit 1
    ;;
esac

tar -xzf "${tmp}/repo.tar.gz" -C "$resolved_dir" --strip-components=1
chmod +x "${resolved_dir}/scripts/install.sh" "${resolved_dir}/facker668-core/scripts/"*.sh 2>/dev/null || true

exec bash "${resolved_dir}/scripts/install.sh" "$@"
