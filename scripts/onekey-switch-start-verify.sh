#!/usr/bin/env bash
set -euo pipefail

# 在 openim/open-im-server 目录下执行：

# 正常执行
# ./scripts/onekey-switch-start-verify.sh
# 只看将执行什么（不真正执行）
# ./scripts/onekey-switch-start-verify.sh --dry-run
# 指定老套目录
# ./scripts/onekey-switch-start-verify.sh --legacy-root /your/old/open-im-server
# 跳过编译
# ./scripts/onekey-switch-start-verify.sh --skip-build

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPS_SCRIPT="$NEW_ROOT/scripts/ops.sh"

# 默认老目录（你之前混跑的那套）
LEGACY_ROOT_DEFAULT="/home/administrator/interview-quicker/open-im-server"

LEGACY_ROOT="${LEGACY_ROOT:-$LEGACY_ROOT_DEFAULT}"
SKIP_BUILD="false"
DRY_RUN="false"

usage() {
  cat <<EOF
一键执行：停老套 + 拉起新套 + 验证

用法:
  ./scripts/onekey-switch-start-verify.sh [选项]

选项:
  --legacy-root <path>   指定老套目录（默认: $LEGACY_ROOT_DEFAULT）
  --skip-build           跳过编译检查与 mage build
  --dry-run              只打印将执行的命令，不真正执行
  -h, --help             显示帮助

环境变量:
  LEGACY_ROOT            等价于 --legacy-root
EOF
}

log() {
  echo "[onekey] $*"
}

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $*"
    return 0
  fi
  eval "$@"
}

need_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "文件不存在: $f" >&2
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --legacy-root)
        shift
        LEGACY_ROOT="${1:-}"
        if [[ -z "$LEGACY_ROOT" ]]; then
          echo "--legacy-root 需要路径参数" >&2
          exit 1
        fi
        ;;
      --skip-build)
        SKIP_BUILD="true"
        ;;
      --dry-run)
        DRY_RUN="true"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done
}

stop_legacy() {
  log "步骤 1/4：停止老套进程（如果存在）..."

  # 仅清理已知老路径和历史二进制命令，避免误杀当前新套
  local pattern
  pattern="${LEGACY_ROOT}|/tmp/openim_server_v3|${LEGACY_ROOT}/web/proxy_server\\.js"
  run_cmd "pkill -f '$pattern' || true"

  # 再次确认是否仍有老进程残留
  run_cmd "ps -ef | awk 'NR==1{print;next} \$0 ~ /${LEGACY_ROOT//\//\\/}|\\/tmp\\/openim_server_v3|proxy_server\\.js/ {print}' || true"
}

ensure_binaries() {
  if [[ "$SKIP_BUILD" == "true" ]]; then
    log "步骤 2/4：已跳过编译检查（--skip-build）"
    return 0
  fi

  log "步骤 2/4：检查并编译新套二进制..."
  local api_bin tools_bin
  api_bin="$NEW_ROOT/_output/bin/platforms/linux/amd64/openim-api"
  tools_bin="$NEW_ROOT/_output/bin/tools/linux/amd64/check-component"

  if [[ -x "$api_bin" && -x "$tools_bin" ]]; then
    log "二进制已存在，跳过编译。"
    return 0
  fi

  run_cmd "cd '$NEW_ROOT' && mage build"
}

start_new_stack() {
  log "步骤 3/4：拉起新套（依赖 + OpenIM 服务）..."
  run_cmd "cd '$NEW_ROOT' && '$OPS_SCRIPT' start-all"
}

verify_new_stack() {
  log "步骤 4/4：验证新套状态..."
  run_cmd "cd '$NEW_ROOT' && '$OPS_SCRIPT' status"
  run_cmd "cd '$NEW_ROOT' && '$OPS_SCRIPT' ports"
}

main() {
  parse_args "$@"
  need_file "$OPS_SCRIPT"

  log "NEW_ROOT=$NEW_ROOT"
  log "LEGACY_ROOT=$LEGACY_ROOT"

  stop_legacy
  ensure_binaries
  start_new_stack
  verify_new_stack

  log "完成：老套已清理，新套已启动并通过验证。"
}

main "$@"
