#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
DEFAULT_CONFIG_DIR="$ROOT_DIR/config"
DEFAULT_LOG_DIR="$ROOT_DIR/_output/logs"

# ======================== 使用例子（快速复制） ========================
# 基础运维
#   ./scripts/ops.sh start-all
#   ./scripts/ops.sh stop-all
#   ./scripts/ops.sh start
#   ./scripts/ops.sh stop
#   ./scripts/ops.sh restart
#
# 状态与检查
#   ./scripts/ops.sh status
#   ./scripts/ops.sh check
#   ./scripts/ops.sh ps
#   ./scripts/ops.sh ports
#
# 日志查看
#   ./scripts/ops.sh logs
#   ./scripts/ops.sh logs mongo
#   ./scripts/ops.sh logs kafka
#
# 依赖容器单独管理
#   ./scripts/ops.sh deps-up
#   ./scripts/ops.sh deps-down
#
# 一键切换并验证（停老套 + 拉起新套 + 验证）
#   ./scripts/ops.sh onekey
#   ./scripts/ops.sh onekey --dry-run
#   ./scripts/ops.sh onekey --skip-build
#   ./scripts/ops.sh onekey --legacy-root /home/administrator/interview-quicker/open-im-server
# =====================================================================

usage() {
  cat <<'EOF'
OpenIM 运维脚本

用法:
  ./scripts/ops.sh <命令> [参数]

命令:
  deps-up                 启动依赖容器（Mongo/Redis/Etcd/Kafka/MinIO/Web）
  deps-down               停止依赖容器（docker compose down）
  start                   启动 OpenIM 服务（mage start）
  stop                    停止 OpenIM 服务（mage stop）
  restart                 重启 OpenIM 服务（stop + start）
  start-all               启动依赖 + OpenIM 服务
  stop-all                停止 OpenIM 服务 + 依赖容器
  status                  查看 OpenIM 服务状态 + 容器状态
  check                   执行 OpenIM 健康检查（mage check）
  logs [service]          查看日志；无参数显示 _output/logs，带参数查看容器日志
  ps                      查看 OpenIM 相关进程
  ports                   查看 OpenIM 相关监听端口
  onekey [args...]        一键执行停老套 + 拉起新套 + 验证（透传参数）
  help                    显示帮助

环境变量:
  CONFIG_DIR              默认: ./config
  LOG_DIR                 默认: ./_output/logs
EOF
}

log() {
  echo "[ops] $*"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令: $1" >&2
    exit 1
  fi
}

compose_cmd() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "docker compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return
  fi
  echo "未找到 docker compose / docker-compose" >&2
  exit 1
}

run_compose() {
  local compose
  compose="$(compose_cmd)"
  # shellcheck disable=SC2086
  $compose -f "$COMPOSE_FILE" "$@"
}

# 示例: ./scripts/ops.sh deps-up
# 启动容器节点:
#   mongodb, redis, etcd, kafka, minio, openim-web-front
# 实际执行: docker compose -f docker-compose.yml up -d mongodb redis etcd kafka minio openim-web-front
deps_up() {
  log "启动依赖容器..."
  run_compose up -d mongodb redis etcd kafka minio openim-web-front
}

# 示例: ./scripts/ops.sh deps-down
# 实际执行: docker compose -f docker-compose.yml down
deps_down() {
  log "停止依赖容器..."
  run_compose down
}

# 示例: ./scripts/ops.sh start
# 启动服务节点（来自 start-config.yml）:
#   openim-api x1
#   openim-crontask x4
#   openim-rpc-user x1
#   openim-msggateway x1
#   openim-push x8
#   openim-msgtransfer x8
#   openim-rpc-conversation x1
#   openim-rpc-auth x1
#   openim-rpc-group x1
#   openim-rpc-friend x1
#   openim-rpc-msg x1
#   openim-rpc-third x1
# 实际执行: OPENIMCONFIG=./config mage start
start_server() {
  need_cmd mage
  local config_dir="${CONFIG_DIR:-$DEFAULT_CONFIG_DIR}"
  log "启动 OpenIM 服务，配置目录: $config_dir"
  (
    cd "$ROOT_DIR"
    OPENIMCONFIG="$config_dir" mage start
  )
}

# 示例: ./scripts/ops.sh stop
# 实际执行: mage stop
stop_server() {
  need_cmd mage
  log "停止 OpenIM 服务..."
  (
    cd "$ROOT_DIR"
    mage stop
  )
}

# 示例: ./scripts/ops.sh check
# 实际执行: mage check
check_server() {
  need_cmd mage
  log "检查 OpenIM 服务状态..."
  (
    cd "$ROOT_DIR"
    mage check
  )
}

# 示例: ./scripts/ops.sh status
# 实际执行:
#   1) mage check
#   2) docker compose -f docker-compose.yml ps
status_all() {
  log "OpenIM 服务状态:"
  if ! check_server; then
    echo "OpenIM 服务检查失败，请查看日志。" >&2
  fi
  echo
  log "容器状态:"
  run_compose ps
}

# 示例:
#   ./scripts/ops.sh logs
#   ./scripts/ops.sh logs mongo
# 实际执行:
#   - 无参数: ls -la ./_output/logs
#   - 有参数: docker compose -f docker-compose.yml logs -f <service>
logs_all() {
  local log_dir="${LOG_DIR:-$DEFAULT_LOG_DIR}"
  if [[ -n "${1:-}" ]]; then
    log "查看容器日志: $1"
    run_compose logs -f "$1"
    return
  fi

  if [[ -d "$log_dir" ]]; then
    log "查看服务日志目录: $log_dir"
    ls -la "$log_dir"
  else
    echo "日志目录不存在: $log_dir" >&2
    echo "可传参查看容器日志，例如: ./scripts/ops.sh logs mongo" >&2
    exit 1
  fi
}

# 示例: ./scripts/ops.sh ps
# 实际执行: ps -ef | awk ... (按 openim 关键字过滤进程)
ps_openim() {
  log "OpenIM 相关进程:"
  ps -ef | awk '
    NR==1 {print; next}
    tolower($0) ~ /openim|open-im-server|msgtransfer|openim_server/ {print}
  '
}

# 示例: ./scripts/ops.sh ports
# 实际执行: ss -lntp | awk ... (按 openim 关键字过滤监听端口)
ports_openim() {
  log "OpenIM 相关监听端口:"
  ss -lntp | awk '
    NR==1 {print; next}
    tolower($0) ~ /openim|open-im-server|msgtransfer|openim_server/ {print}
  '
}

cmd="${1:-help}"
case "$cmd" in
  deps-up)
    deps_up
    ;;
  deps-down)
    deps_down
    ;;
  start)
    start_server
    ;;
  stop)
    stop_server
    ;;
  restart)
    #     cd /home/administrator/openim/open-im-server
    # OPENIMCONFIG=./config mage stop && OPENIMCONFIG=./config mage start
    stop_server
    start_server
    ;;
  start-all)
    deps_up
    start_server
    ;;
  stop-all)
    stop_server || true
    deps_down
    ;;
  status)
    status_all
    ;;
  check)
    check_server
    ;;
  logs)
    logs_all "${2:-}"
    ;;
  ps)
    ps_openim
    ;;
  ports)
    ports_openim
    ;;
  onekey)
    shift || true
    exec "$ROOT_DIR/scripts/onekey-switch-start-verify.sh" "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    echo "未知命令: $cmd" >&2
    echo
    usage
    exit 1
    ;;
esac
