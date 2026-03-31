#!/usr/bin/env bash

set -euo pipefail

# ======================== 完整指令示例（可直接复制） ========================
# 1) 默认执行（使用 127.0.0.1:10002 / imAdmin / openIM123）
#    ./scripts/smoke-test.sh
#
# 2) 指定参数执行（通过环境变量覆盖）
#    API_HOST=127.0.0.1 API_PORT=10002 ADMIN_USER_ID=imAdmin ADMIN_SECRET=openIM123 \
#    OPERATION_ID=smoke-manual-001 ./scripts/smoke-test.sh
#
# 3) 本脚本内部等价关键请求（手工排错可用）
#    # 获取 admin token
#    curl --noproxy '*' -sS -X POST "http://127.0.0.1:10002/auth/get_admin_token" \
#      -H "Content-Type: application/json" \
#      -H "operationID: smoke-manual-001" \
#      -d '{"secret":"openIM123","userID":"imAdmin"}'
#
#    # 调受保护接口 /user/account_check（将 <TOKEN> 替换成上一步 token）
#    curl --noproxy '*' -sS -X POST "http://127.0.0.1:10002/user/account_check" \
#      -H "Content-Type: application/json" \
#      -H "operationID: smoke-manual-001-check" \
#      -H "token: <TOKEN>" \
#      -d '{"checkUserIDs":["imAdmin"]}'
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OPS_SCRIPT="$ROOT_DIR/scripts/ops.sh"

API_HOST="${API_HOST:-127.0.0.1}"
API_PORT="${API_PORT:-10002}"
ADMIN_USER_ID="${ADMIN_USER_ID:-imAdmin}"
ADMIN_SECRET="${ADMIN_SECRET:-openIM123}"
OPERATION_ID="${OPERATION_ID:-smoke-test-$(date +%s)}"

usage() {
  cat <<EOF
OpenIM 冒烟测试脚本

用法:
  ./scripts/smoke-test.sh

可选环境变量:
  API_HOST         默认 127.0.0.1
  API_PORT         默认 10002
  ADMIN_USER_ID    默认 imAdmin
  ADMIN_SECRET     默认 openIM123
  OPERATION_ID     默认 smoke-test-时间戳
EOF
}

log() {
  echo "[smoke] $*"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令: $1" >&2
    exit 1
  fi
}

need_cmd curl
need_cmd python3

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

API_BASE="http://${API_HOST}:${API_PORT}"

log "1/4 [服务编排层] 检查进程与容器是否整体健康（ops status）"
# 1/4 完整指令（等价）:
#   ./scripts/ops.sh status
log "    通过标准: status 不报错，服务显示 running"
"$OPS_SCRIPT" status >/dev/null

# 2/4 完整指令（等价）:
#   curl --noproxy '*' -sS -X POST "${API_BASE}/auth/get_admin_token" \
#     -H "Content-Type: application/json" \
#     -H "operationID: ${OPERATION_ID}" \
#     -d "{\"secret\":\"${ADMIN_SECRET}\",\"userID\":\"${ADMIN_USER_ID}\"}"
log "2/4 [鉴权层] 调用 /auth/get_admin_token 获取管理员 token"
log "    通过标准: errCode=0 且 data.token 非空"
TOKEN_RESP="$(curl --noproxy '*' -sS -X POST "${API_BASE}/auth/get_admin_token" \
  -H "Content-Type: application/json" \
  -H "operationID: ${OPERATION_ID}" \
  -d "{\"secret\":\"${ADMIN_SECRET}\",\"userID\":\"${ADMIN_USER_ID}\"}")"

TOKEN="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("data",{}).get("token",""))' <<<"$TOKEN_RESP")"
ERR_CODE="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("errCode",""))' <<<"$TOKEN_RESP")"
ERR_MSG="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("errMsg",""))' <<<"$TOKEN_RESP")"

if [[ "$ERR_CODE" != "0" || -z "$TOKEN" ]]; then
  echo "[smoke] 获取 token 失败: errCode=$ERR_CODE errMsg=$ERR_MSG" >&2
  echo "[smoke] 原始响应: $TOKEN_RESP" >&2
  exit 1
fi
log "获取 token 成功"

# 3/4 完整指令（等价）:
#   curl --noproxy '*' -sS -X POST "${API_BASE}/user/account_check" \
#     -H "Content-Type: application/json" \
#     -H "operationID: ${OPERATION_ID}-check" \
#     -H "token: ${TOKEN}" \
#     -d "{\"checkUserIDs\":[\"${ADMIN_USER_ID}\"]}"
log "3/4 [业务接口层] 调用受保护接口 /user/account_check（验证 token 可用）"
log "    通过标准: errCode=0"
CHECK_RESP="$(curl --noproxy '*' -sS -X POST "${API_BASE}/user/account_check" \
  -H "Content-Type: application/json" \
  -H "operationID: ${OPERATION_ID}-check" \
  -H "token: ${TOKEN}" \
  -d "{\"checkUserIDs\":[\"${ADMIN_USER_ID}\"]}")"

CHECK_ERR_CODE="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("errCode",""))' <<<"$CHECK_RESP")"
CHECK_ERR_MSG="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("errMsg",""))' <<<"$CHECK_RESP")"

if [[ "$CHECK_ERR_CODE" != "0" ]]; then
  echo "[smoke] account_check 失败: errCode=$CHECK_ERR_CODE errMsg=$CHECK_ERR_MSG" >&2
  echo "[smoke] 原始响应: $CHECK_RESP" >&2
  exit 1
fi
log "account_check 成功"

# 4/4 完整指令（等价）:
#   ./scripts/ops.sh ports
#   ./scripts/ops.sh ports | grep -q "10001"
#   ./scripts/ops.sh ports | grep -q "10002"
log "4/4 [网络监听层] 检查关键端口 10001(ws) / 10002(api)"
log "    通过标准: ops ports 同时包含 10001 和 10002"
PORTS_OUT="$("$OPS_SCRIPT" ports)"
if ! grep -q "10001" <<<"$PORTS_OUT" || ! grep -q "10002" <<<"$PORTS_OUT"; then
  echo "[smoke] 端口检查失败，未同时发现 10001/10002" >&2
  echo "$PORTS_OUT" >&2
  exit 1
fi

echo
echo "[smoke] 全部通过"
echo "[smoke] API: ${API_BASE}"
echo "[smoke] operationID: ${OPERATION_ID}"
echo "[smoke] adminUserID: ${ADMIN_USER_ID}"
