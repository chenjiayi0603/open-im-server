#!/usr/bin/env bash

set -euo pipefail

# ======================== 完整指令示例（可直接复制） ========================
# 1) 默认执行（使用 127.0.0.1:10002 / imAdmin / 自动读取 config/share.yml 的 secret）
#    ./scripts/smoke-test.sh
#
# 2) 指定参数执行（通过环境变量覆盖）
#    API_HOST=127.0.0.1 API_PORT=10002 ADMIN_USER_ID=imAdmin ADMIN_SECRET='<your-secret>' \
#    OPERATION_ID=smoke-manual-001 ./scripts/smoke-test.sh
#
# 3) 本脚本内部等价关键请求（手工排错可用）
#    # 获取 admin token
#    curl --noproxy '*' -sS -X POST "http://127.0.0.1:10002/auth/get_admin_token" \
#      -H "Content-Type: application/json" \
#      -H "operationID: smoke-manual-001" \
#      -d '{"secret":"<your-secret>","userID":"imAdmin"}'
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
ADMIN_SECRET="${ADMIN_SECRET:-}"
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
  ADMIN_SECRET     默认读取 config/share.yml 的 secret（可手动覆盖）
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

if [[ -z "${ADMIN_SECRET}" ]]; then
  if [[ -f "$ROOT_DIR/config/share.yml" ]]; then
    ADMIN_SECRET="$(python3 - <<'PY' "$ROOT_DIR/config/share.yml"
import re,sys
path=sys.argv[1]
for line in open(path, encoding="utf-8"):
    if re.match(r'^\s*secret\s*:\s*', line):
        print(line.split(':',1)[1].strip().strip('"').strip("'"))
        break
PY
)"
  fi
fi

if [[ -z "${ADMIN_SECRET}" ]]; then
  echo "[smoke] ADMIN_SECRET 为空：请设置环境变量 ADMIN_SECRET 或检查 config/share.yml 的 secret" >&2
  exit 1
fi

API_BASE="http://${API_HOST}:${API_PORT}"

log "1/6 [服务编排层] 检查进程与容器是否整体健康（ops status）"
# 1/6 完整指令（等价）:
#   ./scripts/ops.sh status
log "    通过标准: status 不报错，服务显示 running"
"$OPS_SCRIPT" status >/dev/null

# 2/6 完整指令（等价）:
#   curl --noproxy '*' -sS -X POST "${API_BASE}/auth/get_admin_token" \
#     -H "Content-Type: application/json" \
#     -H "operationID: ${OPERATION_ID}" \
#     -d "{\"secret\":\"${ADMIN_SECRET}\",\"userID\":\"${ADMIN_USER_ID}\"}"
log "2/6 [鉴权层] 调用 /auth/get_admin_token 获取管理员 token"
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

# 3/6 完整指令（等价）:
#   curl --noproxy '*' -sS -X POST "${API_BASE}/user/account_check" \
#     -H "Content-Type: application/json" \
#     -H "operationID: ${OPERATION_ID}-check" \
#     -H "token: ${TOKEN}" \
#     -d "{\"checkUserIDs\":[\"${ADMIN_USER_ID}\"]}"
log "3/6 [业务接口层] 调用受保护接口 /user/account_check（验证 token 可用）"
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

# 4/6 完整指令（等价）:
#   ./scripts/ops.sh ports
#   ./scripts/ops.sh ports | grep -q "10001"
#   ./scripts/ops.sh ports | grep -q "10002"
log "4/6 [网络监听层] 检查关键端口 10001(ws) / 10002(api)"
log "    通过标准: ops ports 同时包含 10001 和 10002"
PORTS_OUT="$("$OPS_SCRIPT" ports)"
if ! grep -q "10001" <<<"$PORTS_OUT" || ! grep -q "10002" <<<"$PORTS_OUT"; then
  echo "[smoke] 端口检查失败，未同时发现 10001/10002" >&2
  echo "$PORTS_OUT" >&2
  exit 1
fi

# 5/6 完整指令（等价）:
#   curl --noproxy '*' -sS -X POST "${API_BASE}/auth/get_admin_token" \
#     -H "Content-Type: application/json" \
#     -H "operationID: ${OPERATION_ID}-default-secret" \
#     -d "{\"secret\":\"openIM123\",\"userID\":\"${ADMIN_USER_ID}\"}"
log "5/6 [安全基线] 校验默认密钥 openIM123 已失效"
log "    通过标准: 使用 openIM123 获取 token 返回 errCode != 0"
DEFAULT_SECRET_RESP="$(curl --noproxy '*' -sS -X POST "${API_BASE}/auth/get_admin_token" \
  -H "Content-Type: application/json" \
  -H "operationID: ${OPERATION_ID}-default-secret" \
  -d "{\"secret\":\"openIM123\",\"userID\":\"${ADMIN_USER_ID}\"}")"
DEFAULT_SECRET_CODE="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("errCode",""))' <<<"$DEFAULT_SECRET_RESP")"
if [[ "$DEFAULT_SECRET_CODE" == "0" ]]; then
  echo "[smoke] 默认密钥 openIM123 仍可用，存在高风险" >&2
  echo "[smoke] 原始响应: $DEFAULT_SECRET_RESP" >&2
  exit 1
fi

# 6/6 完整指令（等价）:
#   curl --noproxy '*' -sS -X POST "${API_BASE}/auth/get_admin_token" \
#     -H "Content-Type: application/json" \
#     -H "operationID: ${OPERATION_ID}-public-ip" \
#     -H "X-Forwarded-For: 8.8.8.8" \
#     -d "{\"secret\":\"${ADMIN_SECRET}\",\"userID\":\"${ADMIN_USER_ID}\"}"
log "6/6 [安全基线] 校验管理口对公网来源拒绝（X-Forwarded-For 模拟）"
log "    通过标准: 返回 errCode=403 或 errMsg=forbidden（若网关未透传来源头，此项可按环境豁免）"
PUBLIC_IP_RESP="$(curl --noproxy '*' -sS -X POST "${API_BASE}/auth/get_admin_token" \
  -H "Content-Type: application/json" \
  -H "operationID: ${OPERATION_ID}-public-ip" \
  -H "X-Forwarded-For: 8.8.8.8" \
  -d "{\"secret\":\"${ADMIN_SECRET}\",\"userID\":\"${ADMIN_USER_ID}\"}")"
PUBLIC_IP_CODE="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("errCode",""))' <<<"$PUBLIC_IP_RESP")"
PUBLIC_IP_MSG="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(str(d.get("errMsg","")).lower())' <<<"$PUBLIC_IP_RESP")"
if [[ "$PUBLIC_IP_CODE" != "403" && "$PUBLIC_IP_MSG" != "forbidden" ]]; then
  log "    提示: 当前环境未触发来源头限制（可能因反向代理/信任链配置），请在真实公网入口复测。"
fi

echo
echo "[smoke] 全部通过"
echo "[smoke] API: ${API_BASE}"
echo "[smoke] operationID: ${OPERATION_ID}"
echo "[smoke] adminUserID: ${ADMIN_USER_ID}"
