#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="vless-xhttp-reality-self"
PUBLIC_REPO="${PUBLIC_REPO:-tao-t356/vless-xhttp-reality-self}"
RELEASE_REPO="${RELEASE_REPO:-tao-t356/vless-xhttp-reality-self}"
RELEASE_VERSION="${RELEASE_VERSION:-${VERSION:-latest}}"
ASSET_BASE_WAS_SET="${ASSET_BASE+x}"
ASSET_BASE="${ASSET_BASE:-https://raw.githubusercontent.com/${PUBLIC_REPO}/main/dist}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
INSTALL_ROOT="${INSTALL_ROOT:-/usr/local/lib/${APP_NAME}}"
LOCK_FILE="${LOCK_FILE:-/run/lock/${APP_NAME}-bootstrap.lock}"
AUTH_HEADER_FILE=""
BOOTSTRAP_TMP=""
PENDING_INSTALL_DIR=""
INSTALL_TRANSACTION_ACTIVE=0
VERSION_CHANGE_KIND=""
VERSION_FINAL_DIR=""
VERSION_BACKUP_DIR=""
ENTRY_CURRENT_LINK=""
ENTRY_CURRENT_PENDING=""
ENTRY_CURRENT_BACKUP=""
ENTRY_CURRENT_HAD_OLD=0
ENTRY_CURRENT_CHANGED=0
ENTRY_NAMES=("$APP_NAME" "${APP_NAME}-egress-pool")
OBSOLETE_ENTRY_NAMES=("${APP_NAME}-install-ip" facker668)
ENTRY_HAD_OLD=()
ENTRY_CHANGED=()
ENTRY_PENDING=()
ENTRY_BACKUP=()

red() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }

cleanup_bootstrap() {
  local status=$? rollback_failed=0
  trap - EXIT INT TERM HUP
  set +e
  if [[ "${INSTALL_TRANSACTION_ACTIVE:-0}" == "1" ]]; then
    rollback_entrypoint_transaction || rollback_failed=1
    rollback_version_change || rollback_failed=1
  fi
  if [[ "$rollback_failed" == "0" ]]; then
    cleanup_entrypoint_artifacts
  else
    red "安装事务回滚不完整；事务备份文件已保留，请人工检查。"
    status=1
  fi
  if [[ -n "${PENDING_INSTALL_DIR:-}" ]]; then
    rm -rf -- "$PENDING_INSTALL_DIR"
    PENDING_INSTALL_DIR=""
  fi
  if [[ -n "${BOOTSTRAP_TMP:-}" ]]; then
    rm -rf -- "$BOOTSTRAP_TMP"
    BOOTSTRAP_TMP=""
  fi
  exit "$status"
}

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    red "请以 root 运行：sudo bash install.sh"
    exit 1
  fi
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64|armv7l|armv7)
      red "公开二进制资产当前仅支持 linux/amd64；检测到架构: ${machine}"
      exit 1
      ;;
    *) red "暂不支持当前 CPU 架构: ${machine}"; exit 1 ;;
  esac
}

asset_url() {
  local asset="$1"
  if [[ "$RELEASE_VERSION" == "latest" ]]; then
    if [[ -n "$ASSET_BASE_WAS_SET" || "$RELEASE_REPO" == "$PUBLIC_REPO" ]]; then
      printf '%s/%s' "${ASSET_BASE%/}" "$asset"
    else
      printf 'https://github.com/%s/releases/latest/download/%s' "$RELEASE_REPO" "$asset"
    fi
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
  if [[ "$RELEASE_VERSION" != "latest" && "$RELEASE_REPO" == "$PUBLIC_REPO" ]]; then
    red "默认公开仓库只从 main/dist 发布资产，不创建 GitHub Release。"
    red "固定版本安装必须显式指定另一个实际发布 Release 资产的 RELEASE_REPO。"
    exit 1
  fi
  if [[ ! "$ASSET_BASE" =~ ^https:// ]]; then
    red "ASSET_BASE 必须使用 HTTPS: ${ASSET_BASE}"
    exit 1
  fi
  [[ "$INSTALL_DIR" == /* && "$INSTALL_ROOT" == /* ]] || {
    red "INSTALL_DIR 与 INSTALL_ROOT 必须是绝对路径。"
    exit 1
  }
}

curl_download() {
  local url="$1" output="$2"
  local headers=()
  if [[ -n "$AUTH_HEADER_FILE" && ( "$url" == https://github.com/* \
    || "$url" == https://api.github.com/* || "$url" == https://raw.githubusercontent.com/* ) ]]; then
    [[ -r "$AUTH_HEADER_FILE" ]] || { red "GitHub 认证 header 文件不可读"; return 1; }
    headers=(-H "@${AUTH_HEADER_FILE}")
  fi
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 15 --retry 3 --retry-delay 2 --max-filesize 268435456 \
    "${headers[@]}" "$url" -o "$output" || return $?
}

validate_archive_members() {
  local archive="$1" member mode owner size date_field time_field remainder
  local names_file verbose_file required total_size=0
  local -a required_members=(
    bin/
    VERSION
    "bin/${APP_NAME}"
    "bin/${APP_NAME}-egress-pool"
  )
  local -A seen=()

  names_file="$(mktemp)"
  verbose_file="$(mktemp)"
  if ! tar -tzf "$archive" > "$names_file" \
    || ! LC_ALL=C tar -tvzf "$archive" > "$verbose_file"; then
    rm -f "$names_file" "$verbose_file"
    red "发布包不是有效的 gzip tar 归档"
    return 1
  fi

  while IFS= read -r member; do
    case "$member" in
      bin/|VERSION|LICENSE|"bin/${APP_NAME}"|"bin/${APP_NAME}-egress-pool")
        ;;
      *)
        red "发布包包含未授权路径: ${member}"
        rm -f "$names_file" "$verbose_file"
        return 1
        ;;
    esac
    if [[ -n "${seen[$member]+present}" ]]; then
      rm -f "$names_file" "$verbose_file"
      red "发布包包含重复路径: ${member}"
      return 1
    fi
    seen["$member"]=1
  done < "$names_file"

  for required in "${required_members[@]}"; do
    if [[ -z "${seen[$required]+present}" ]]; then
      rm -f "$names_file" "$verbose_file"
      red "发布包缺少必要路径: ${required}"
      return 1
    fi
  done

  while read -r mode owner size date_field time_field member remainder; do
    case "$member" in
      bin/)
        [[ "$mode" == d* ]] || {
          rm -f "$names_file" "$verbose_file"
          red "发布包中的 bin/ 不是目录"
          return 1
        }
        ;;
      VERSION|LICENSE|"bin/${APP_NAME}"|"bin/${APP_NAME}-egress-pool")
        [[ "$mode" == -* && "$size" =~ ^[0-9]+$ ]] || {
          rm -f "$names_file" "$verbose_file"
          red "发布包包含非常规文件: ${member}"
          return 1
        }
        total_size=$((total_size + size))
        (( total_size <= 536870912 )) || {
          rm -f "$names_file" "$verbose_file"
          red "发布包解压后文件总量超过 512 MiB 限制"
          return 1
        }
        ;;
      *)
        rm -f "$names_file" "$verbose_file"
        red "无法验证发布包成员类型: ${member:-unknown}"
        return 1
        ;;
    esac
  done < "$verbose_file"

  rm -f "$names_file" "$verbose_file"
}

version_dir_matches() {
  local installed="$1" expected="$2" entry relative name
  [[ -d "$installed" && ! -L "$installed" ]] || return 1
  [[ -d "${installed}/bin" && ! -L "${installed}/bin" ]] || return 1

  for name in "${ENTRY_NAMES[@]}"; do
    [[ -f "${installed}/bin/${name}" && ! -L "${installed}/bin/${name}" \
      && -x "${installed}/bin/${name}" ]] || return 1
    cmp -s -- "${installed}/bin/${name}" "${expected}/bin/${name}" || return 1
  done
  [[ -f "${installed}/VERSION" && ! -L "${installed}/VERSION" ]] || return 1
  cmp -s -- "${installed}/VERSION" "${expected}/VERSION" || return 1
  [[ -f "${installed}/.archive-sha256" && ! -L "${installed}/.archive-sha256" ]] || return 1
  cmp -s -- "${installed}/.archive-sha256" "${expected}/.archive-sha256" || return 1
  if [[ -f "${expected}/LICENSE" ]]; then
    [[ -f "${installed}/LICENSE" && ! -L "${installed}/LICENSE" ]] || return 1
    cmp -s -- "${installed}/LICENSE" "${expected}/LICENSE" || return 1
  elif [[ -e "${installed}/LICENSE" || -L "${installed}/LICENSE" ]]; then
    return 1
  fi

  while IFS= read -r -d '' entry; do
    relative="${entry#${installed}/}"
    case "$relative" in
      bin)
        [[ -d "$entry" && ! -L "$entry" ]] || return 1
        ;;
      VERSION|LICENSE|.archive-sha256|"bin/${APP_NAME}"|"bin/${APP_NAME}-egress-pool")
        [[ -f "$entry" && ! -L "$entry" ]] || return 1
        ;;
      *)
        return 1
        ;;
    esac
  done < <(find "$installed" -mindepth 1 -print0)
}

cleanup_entrypoint_artifacts() {
  local index path
  [[ -z "${ENTRY_CURRENT_PENDING:-}" ]] || rm -f -- "$ENTRY_CURRENT_PENDING"
  if [[ -n "${ENTRY_CURRENT_BACKUP:-}" && ( -e "$ENTRY_CURRENT_BACKUP" || -L "$ENTRY_CURRENT_BACKUP" ) ]]; then
    rm -f -- "$ENTRY_CURRENT_BACKUP"
  fi
  for index in "${!ENTRY_NAMES[@]}"; do
    path="${ENTRY_PENDING[$index]:-}"
    [[ -z "$path" ]] || rm -f -- "$path"
    path="${ENTRY_BACKUP[$index]:-}"
    if [[ -n "$path" && ( -e "$path" || -L "$path" ) ]]; then
      rm -f -- "$path"
    fi
  done
}

prepare_entrypoint_transaction() {
  local final_dir="$1" index name dest pending backup
  ENTRY_CURRENT_LINK="${INSTALL_ROOT}/current"
  ENTRY_CURRENT_PENDING="${INSTALL_ROOT}/.current.new.$$"
  ENTRY_CURRENT_BACKUP="${INSTALL_ROOT}/.current.old.$$"
  ENTRY_CURRENT_HAD_OLD=0
  ENTRY_CURRENT_CHANGED=0
  ENTRY_HAD_OLD=()
  ENTRY_CHANGED=()
  ENTRY_PENDING=()
  ENTRY_BACKUP=()

  if [[ -e "$ENTRY_CURRENT_LINK" && ! -L "$ENTRY_CURRENT_LINK" ]]; then
    red "拒绝替换非符号链接路径: ${ENTRY_CURRENT_LINK}"
    return 1
  fi
  if [[ -L "$ENTRY_CURRENT_LINK" && ! -d "${ENTRY_CURRENT_LINK}/bin" ]]; then
    red "当前版本链接无效: ${ENTRY_CURRENT_LINK}"
    return 1
  fi
  if [[ -e "$ENTRY_CURRENT_PENDING" || -L "$ENTRY_CURRENT_PENDING" \
    || -e "$ENTRY_CURRENT_BACKUP" || -L "$ENTRY_CURRENT_BACKUP" ]]; then
    red "发现冲突的 current 事务文件。"
    return 1
  fi

  for index in "${!ENTRY_NAMES[@]}"; do
    name="${ENTRY_NAMES[$index]}"
    dest="${INSTALL_DIR}/${name}"
    pending="${INSTALL_DIR}/.${name}.new.$$"
    backup="${INSTALL_DIR}/.${name}.old.$$"
    ENTRY_PENDING[$index]="$pending"
    ENTRY_BACKUP[$index]="$backup"
    ENTRY_HAD_OLD[$index]=0
    ENTRY_CHANGED[$index]=0
    if [[ -d "$dest" && ! -L "$dest" ]]; then
      red "拒绝替换目录: ${dest}"
      cleanup_entrypoint_artifacts
      return 1
    fi
    if [[ -e "$pending" || -L "$pending" || -e "$backup" || -L "$backup" ]]; then
      red "发现冲突的安装事务文件: ${pending} / ${backup}"
      cleanup_entrypoint_artifacts
      return 1
    fi
  done

  if ! ln -s "$final_dir" "$ENTRY_CURRENT_PENDING"; then
    cleanup_entrypoint_artifacts
    return 1
  fi
  if [[ -L "$ENTRY_CURRENT_LINK" ]]; then
    if ! cp -a -- "$ENTRY_CURRENT_LINK" "$ENTRY_CURRENT_BACKUP"; then
      cleanup_entrypoint_artifacts
      return 1
    fi
    ENTRY_CURRENT_HAD_OLD=1
  fi

  for index in "${!ENTRY_NAMES[@]}"; do
    name="${ENTRY_NAMES[$index]}"
    dest="${INSTALL_DIR}/${name}"
    pending="${ENTRY_PENDING[$index]}"
    backup="${ENTRY_BACKUP[$index]}"
    if ! ln -s "${INSTALL_ROOT}/current/bin/${name}" "$pending"; then
      cleanup_entrypoint_artifacts
      return 1
    fi
    if [[ -e "$dest" || -L "$dest" ]]; then
      if ! cp -a -- "$dest" "$backup"; then
        cleanup_entrypoint_artifacts
        return 1
      fi
      ENTRY_HAD_OLD[$index]=1
    fi
  done
}

apply_entrypoint_transaction() {
  local index name dest
  if ! mv -Tf -- "$ENTRY_CURRENT_PENDING" "$ENTRY_CURRENT_LINK"; then
    return 1
  fi
  ENTRY_CURRENT_CHANGED=1
  for index in "${!ENTRY_NAMES[@]}"; do
    name="${ENTRY_NAMES[$index]}"
    dest="${INSTALL_DIR}/${name}"
    if ! mv -Tf -- "${ENTRY_PENDING[$index]}" "$dest"; then
      return 1
    fi
    ENTRY_CHANGED[$index]=1
  done
}

rollback_entrypoint_transaction() {
  local index name dest failed=0
  for ((index = ${#ENTRY_NAMES[@]} - 1; index >= 0; index--)); do
    if [[ "${ENTRY_CHANGED[$index]:-0}" == "1" \
      || ( -n "${ENTRY_PENDING[$index]:-}" \
        && ! -e "${ENTRY_PENDING[$index]}" && ! -L "${ENTRY_PENDING[$index]}" ) ]]; then
      name="${ENTRY_NAMES[$index]}"
      dest="${INSTALL_DIR}/${name}"
      rm -f -- "$dest" || failed=1
      if [[ "${ENTRY_HAD_OLD[$index]:-0}" == "1" ]]; then
        mv -Tf -- "${ENTRY_BACKUP[$index]}" "$dest" || failed=1
      fi
    fi
  done
  if [[ "${ENTRY_CURRENT_CHANGED:-0}" == "1" \
    || ( -n "${ENTRY_CURRENT_PENDING:-}" \
      && ! -e "$ENTRY_CURRENT_PENDING" && ! -L "$ENTRY_CURRENT_PENDING" ) ]]; then
    rm -f -- "$ENTRY_CURRENT_LINK" || failed=1
    if [[ "${ENTRY_CURRENT_HAD_OLD:-0}" == "1" ]]; then
      mv -Tf -- "$ENTRY_CURRENT_BACKUP" "$ENTRY_CURRENT_LINK" || failed=1
    fi
  fi
  (( failed == 0 ))
}

rollback_version_change() {
  local failed=0
  case "${VERSION_CHANGE_KIND:-}" in
    created)
      if [[ -z "${PENDING_INSTALL_DIR:-}" \
        || ( ! -e "$PENDING_INSTALL_DIR" && ! -L "$PENDING_INSTALL_DIR" ) ]]; then
        [[ ! -e "$VERSION_FINAL_DIR" && ! -L "$VERSION_FINAL_DIR" ]] \
          || rm -rf -- "$VERSION_FINAL_DIR" || failed=1
      fi
      ;;
    repaired)
      if [[ -e "$VERSION_BACKUP_DIR" || -L "$VERSION_BACKUP_DIR" ]]; then
        [[ ! -e "$VERSION_FINAL_DIR" && ! -L "$VERSION_FINAL_DIR" ]] \
          || rm -rf -- "$VERSION_FINAL_DIR" || failed=1
        mv -Tf -- "$VERSION_BACKUP_DIR" "$VERSION_FINAL_DIR" || failed=1
      fi
      ;;
  esac
  (( failed == 0 ))
}

main() {
  require_root
  validate_release_inputs

  local arch asset tmp archive checksum_url checksum_file expected actual requested_version
  local version final_dir new_dir tool_name github_token version_action version_backup
  local obsolete_path obsolete_target
  arch="$(detect_arch)"
  asset="${APP_NAME}_linux_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  BOOTSTRAP_TMP="$tmp"
  trap cleanup_bootstrap EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  github_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$github_token" ]]; then
    if [[ "$github_token" == *$'\n'* || "$github_token" == *$'\r'* ]]; then
      red "GitHub Token 包含非法换行符"
      exit 1
    fi
    AUTH_HEADER_FILE="${tmp}/github.header"
    (umask 077; printf 'Authorization: Bearer %s\n' "$github_token" > "$AUTH_HEADER_FILE")
  fi
  github_token=""
  unset GITHUB_TOKEN GH_TOKEN TOKEN
  archive="${tmp}/${asset}"
  checksum_file="${archive}.sha256"

  command -v flock >/dev/null 2>&1 || { red "缺少 flock（util-linux）"; exit 1; }
  command -v cmp >/dev/null 2>&1 || { red "缺少 cmp（diffutils）"; exit 1; }
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 198>"$LOCK_FILE"
  flock -n 198 || { red "另一个安装/更新任务正在运行。"; exit 1; }

  yellow "正在下载 ${APP_NAME} 二进制包: ${RELEASE_VERSION} linux/${arch}"
  curl_download "$(asset_url "$asset")" "$archive"

  checksum_url="$(asset_url "${asset}.sha256")"
  curl_download "$checksum_url" "$checksum_file"
  read -r expected _ < "$checksum_file"
  expected="${expected,,}"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { red "校验文件格式无效"; exit 1; }
  actual="$(sha256sum "$archive" | awk '{print tolower($1)}')"
  [[ "$actual" == "$expected" ]] || { red "发布包 SHA256 校验失败"; exit 1; }

  validate_archive_members "$archive"
  tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$tmp"
  for tool_name in "${ENTRY_NAMES[@]}"; do
    [[ -f "${tmp}/bin/${tool_name}" && ! -L "${tmp}/bin/${tool_name}" ]] || {
      red "发布包缺少普通文件 bin/${tool_name}"
      exit 1
    }
    chmod 0755 "${tmp}/bin/${tool_name}"
  done
  version="$(tr -d '\r\n' < "${tmp}/VERSION")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([._-][A-Za-z0-9.-]+)?$ ]] || {
    red "发布包 VERSION 无效: ${version}"
    exit 1
  }
  if [[ "$RELEASE_VERSION" != "latest" ]]; then
    requested_version="${RELEASE_VERSION#v}"
    [[ "$requested_version" == "$version" ]] || {
      red "请求版本 ${RELEASE_VERSION} 与发布包 VERSION ${version} 不一致"
      exit 1
    }
  fi

  install -d -m 0755 "$INSTALL_DIR" "$INSTALL_ROOT"
  new_dir="${INSTALL_ROOT}/.${version}.new.$$"
  final_dir="${INSTALL_ROOT}/${version}"
  [[ ! -e "$new_dir" && ! -L "$new_dir" ]] || { red "安装暂存目录已存在: ${new_dir}"; exit 1; }
  PENDING_INSTALL_DIR="$new_dir"
  install -d -m 0755 "${new_dir}/bin"
  for tool_name in "${ENTRY_NAMES[@]}"; do
    install -m 0755 "${tmp}/bin/${tool_name}" "${new_dir}/bin/${tool_name}"
  done
  install -m 0644 "${tmp}/VERSION" "${new_dir}/VERSION"
  [[ ! -f "${tmp}/LICENSE" ]] || install -m 0644 "${tmp}/LICENSE" "${new_dir}/LICENSE"
  printf '%s\n' "$actual" > "${new_dir}/.archive-sha256"
  chmod 0644 "${new_dir}/.archive-sha256"

  version_action=create
  version_backup="${INSTALL_ROOT}/.${version}.old.$$"
  if [[ -e "$final_dir" || -L "$final_dir" ]]; then
    if [[ ! -d "$final_dir" || -L "$final_dir" \
      || ! -f "${final_dir}/.archive-sha256" || -L "${final_dir}/.archive-sha256" \
      || "$(tr -d '\r\n' < "${final_dir}/.archive-sha256")" != "$actual" ]]; then
      red "版本目录 ${final_dir} 已存在但内容标识不同；拒绝覆盖不可变版本，请发布新版本号。"
      exit 1
    fi
    if version_dir_matches "$final_dir" "$new_dir"; then
      version_action=matched
    else
      [[ ! -e "$version_backup" && ! -L "$version_backup" ]] \
        || { red "版本修复备份目录已存在: ${version_backup}"; exit 1; }
      version_action=repair
      yellow "检测到 ${final_dir} 内容损坏或不完整，将使用已验证发布包修复。"
    fi
  fi

  if [[ "$version_action" == "matched" ]]; then
    rm -rf -- "$new_dir"
    PENDING_INSTALL_DIR=""
  fi

  if ! prepare_entrypoint_transaction "$final_dir"; then
    red "无法准备命令入口切换事务。"
    exit 1
  fi

  INSTALL_TRANSACTION_ACTIVE=1
  VERSION_FINAL_DIR="$final_dir"
  case "$version_action" in
    create)
      VERSION_CHANGE_KIND=created
      if ! mv -Tf -- "$new_dir" "$final_dir"; then
        red "无法安装版本目录: ${final_dir}"
        exit 1
      fi
      PENDING_INSTALL_DIR=""
      ;;
    repair)
      VERSION_CHANGE_KIND=repaired
      VERSION_BACKUP_DIR="$version_backup"
      if ! mv -Tf -- "$final_dir" "$version_backup"; then
        red "无法创建版本修复备份: ${version_backup}"
        exit 1
      fi
      if ! mv -Tf -- "$new_dir" "$final_dir"; then
        red "无法安装修复后的版本目录: ${final_dir}"
        exit 1
      fi
      PENDING_INSTALL_DIR=""
      ;;
    matched)
      VERSION_CHANGE_KIND=""
      ;;
  esac

  if ! apply_entrypoint_transaction; then
    red "命令入口或 current 切换失败，将恢复安装前状态。"
    exit 1
  fi

  INSTALL_TRANSACTION_ACTIVE=0
  if [[ -n "$VERSION_BACKUP_DIR" && -d "$VERSION_BACKUP_DIR" ]]; then
    rm -rf -- "$VERSION_BACKUP_DIR" || yellow "无法删除版本修复备份: ${VERSION_BACKUP_DIR}"
  fi
  cleanup_entrypoint_artifacts
  for tool_name in "${OBSOLETE_ENTRY_NAMES[@]}"; do
    obsolete_path="${INSTALL_DIR}/${tool_name}"
    if [[ -L "$obsolete_path" ]]; then
      obsolete_target="$(readlink -- "$obsolete_path" 2>/dev/null || true)"
      case "$obsolete_target" in
        "${INSTALL_ROOT}"/*) rm -f -- "$obsolete_path" ;;
      esac
    fi
  done
  VERSION_CHANGE_KIND=""
  VERSION_FINAL_DIR=""
  VERSION_BACKUP_DIR=""

  rm -rf -- "$tmp"
  BOOTSTRAP_TMP=""
  trap - EXIT INT TERM HUP
  unset GITHUB_TOKEN GH_TOKEN TOKEN
  green "安装完成：${INSTALL_DIR}/${APP_NAME}"
  echo
  env -u GITHUB_TOKEN -u GH_TOKEN -u TOKEN RELEASE_REPO="$RELEASE_REPO" VXR_RELEASE_VERSION="$RELEASE_VERSION" "${INSTALL_DIR}/${APP_NAME}" menu
}

main "$@"
