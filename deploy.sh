#!/usr/bin/env bash
# ============================================================
# 常青藤 · 双向客服机器人 —— 一键部署脚本
#
# 走 Cloudflare REST API，不依赖 wrangler（无需 Node 环境）。
# 依赖：bash + curl + jq
#
# 用法：
#   CF_TOKEN=xxx \
#   ACCOUNT_ID=xxx \
#   BOT_TOKEN=xxx \
#   GROUP_ID=-100xxxxxxxxxx \
#   ./deploy.sh
#
# 可选环境变量：
#   SCRIPT_NAME      Worker 名称，默认 tgchatbot
#   DB_NAME          D1 数据库名，默认 tgchatbot-db
#                    （这两个默认值刻意与线上既有部署保持一致，
#                      重复执行 deploy.sh 会「更新」而不是「新建」）
#   RATE_LIMIT       每用户每分钟消息上限，默认 30
#   TURNSTILE_SITEKEY / TURNSTILE_SECRET
#                    Cloudflare Turnstile 凭据；不填则自动回退「算术验证」
#   WEBHOOK_SECRET   webhook 校验密钥；不填则脚本自动生成
#   SKIP_SUBDOMAIN   设为 1 可跳过 workers.dev 子域启用
# ============================================================
set -uo pipefail

CF_TOKEN="${CF_TOKEN:-}"
ACCOUNT_ID="${ACCOUNT_ID:-}"
BOT_TOKEN="${BOT_TOKEN:-}"
GROUP_ID="${GROUP_ID:-}"
RATE_LIMIT="${RATE_LIMIT:-30}"
SCRIPT_NAME="${SCRIPT_NAME:-tgchatbot}"
DB_NAME="${DB_NAME:-tgchatbot-db}"
TURNSTILE_SITEKEY="${TURNSTILE_SITEKEY:-}"
TURNSTILE_SECRET="${TURNSTILE_SECRET:-}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-}"
SKIP_SUBDOMAIN="${SKIP_SUBDOMAIN:-0}"

API="https://api.cloudflare.com/client/v4"
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$WORKDIR/build"

die()  { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

command -v curl >/dev/null || die "缺少 curl"
command -v jq   >/dev/null || die "缺少 jq（macOS: brew install jq / Debian: apt install jq）"

[ -n "$CF_TOKEN" ]   || die "缺少 CF_TOKEN"
[ -n "$ACCOUNT_ID" ] || die "缺少 ACCOUNT_ID"
[ -n "$BOT_TOKEN" ]  || die "缺少 BOT_TOKEN"
[ -n "$GROUP_ID" ]   || die "缺少 GROUP_ID"

cf() { curl -sS --max-time 40 -H "Authorization: Bearer $CF_TOKEN" "$@"; }

step "1/7 校验 Cloudflare Token"
VERIFY=$(cf "$API/user/tokens/verify")
echo "$VERIFY" | jq -c '{success, status: (.result.status // null), errors: (.errors // [])}'
echo "$VERIFY" | jq -e '.success == true' >/dev/null || die "Token 无效或权限不足"
ok "Token 有效"

step "2/7 准备代码"
mkdir -p "$BUILD"
cp "$WORKDIR/worker.js" "$BUILD/worker.js"
# 说明：verify.html 是验证页的「源码参考」，运行时由 worker.js 内的 VERIFY_PAGE_HTML
# 在返回 /verify 时把 __SITEKEY__ 替换为 TURNSTILE_SITEKEY_ENV，无需在此注入。
ok "代码就绪（$(wc -l < "$BUILD/worker.js") 行）"

step "3/7 创建/复用 D1 数据库"
DB_ID=$(cf "$API/accounts/$ACCOUNT_ID/d1/database" | jq -r --arg n "$DB_NAME" '.result[]? | select(.name==$n) | .uuid' | head -1)
if [ -z "$DB_ID" ] || [ "$DB_ID" = "null" ]; then
  echo "  未找到同名库，创建中..."
  DB_ID=$(cf -X POST -H "Content-Type: application/json" \
    "$API/accounts/$ACCOUNT_ID/d1/database" \
    -d "{\"name\":\"$DB_NAME\"}" | jq -r '.result.uuid')
fi
[ -n "$DB_ID" ] && [ "$DB_ID" != "null" ] || die "D1 创建失败"
ok "D1 数据库 ID: $DB_ID"

step "4/7 生成 Webhook 密钥"
if [ -z "$WEBHOOK_SECRET" ]; then
  if command -v openssl >/dev/null; then
    WEBHOOK_SECRET=$(openssl rand -hex 32)
  else
    WEBHOOK_SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
fi
[ ${#WEBHOOK_SECRET} -ge 16 ] || die "WEBHOOK_SECRET 至少 16 字符"
echo "  WEBHOOK_SECRET=$WEBHOOK_SECRET"
echo "  （请自行留存，后续手动 setWebhook 时需要）"

step "5/7 上传 Worker"
jq -n \
  --arg db "$DB_ID" \
  --arg bt "$BOT_TOKEN" \
  --arg gid "$GROUP_ID" \
  --arg rl "$RATE_LIMIT" \
  --arg sk "$TURNSTILE_SITEKEY" \
  --arg ss "$TURNSTILE_SECRET" \
  --arg ws "$WEBHOOK_SECRET" \
  '{
    main_module: "worker.js",
    compatibility_date: "2024-11-01",
    bindings: [
      { type: "d1",         name: "D1",                         id: $db },
      { type: "plain_text", name: "BOT_TOKEN_ENV",              text: $bt },
      { type: "plain_text", name: "GROUP_ID_ENV",               text: $gid },
      { type: "plain_text", name: "MAX_MESSAGES_PER_MINUTE_ENV",text: $rl },
      { type: "plain_text", name: "TURNSTILE_SITEKEY_ENV",      text: $sk },
      { type: "plain_text", name: "TURNSTILE_SECRET_ENV",       text: $ss },
      { type: "plain_text", name: "WEBHOOK_SECRET_ENV",         text: $ws }
    ]
  }' > "$BUILD/metadata.json"

UP=$(cf -X PUT \
  -F "metadata=@$BUILD/metadata.json;type=application/json" \
  -F "worker.js=@$BUILD/worker.js;type=application/javascript+module" \
  "$API/accounts/$ACCOUNT_ID/workers/scripts/$SCRIPT_NAME")
echo "$UP" | jq -c '{success, errors: (.errors // [])}'
echo "$UP" | jq -e '.success == true' >/dev/null || die "Worker 上传失败"
ok "Worker 已上传"

step "6/7 启用 workers.dev 子域"
if [ "$SKIP_SUBDOMAIN" != "1" ]; then
  cf -X POST -H "Content-Type: application/json" \
    "$API/accounts/$ACCOUNT_ID/workers/scripts/$SCRIPT_NAME/subdomain" \
    -d '{"enabled":true,"previews_enabled":true}' | jq -c '{success, errors: (.errors // [])}' || true
fi
SUB=$(cf "$API/accounts/$ACCOUNT_ID/workers/subdomain" | jq -r '.result.subdomain')
WORKER_URL="https://$SCRIPT_NAME.$SUB.workers.dev"
ok "Worker 地址: $WORKER_URL"

step "7/7 触发初始化（自动注册 Telegram Webhook）"
CODE=$(curl -sS --max-time 25 -o /dev/null -w "%{http_code}" "$WORKER_URL/" 2>/dev/null || echo "000")
echo "  访问返回码: $CODE"
if [ "$CODE" = "000" ]; then
  warn "当前机器访问不到 workers.dev，请在任意能联网的环境打开一次："
  echo "         $WORKER_URL"
fi

echo ""
echo "============================================================"
echo "  部署完成"
echo "  Worker URL  : $WORKER_URL"
echo "  D1 数据库    : $DB_ID"
echo "  Webhook     : $WORKER_URL/webhook"
echo "  验证页       : $WORKER_URL/verify"
echo "  WEBHOOK_SECRET: $WEBHOOK_SECRET"
echo ""
echo "  下一步：在 Telegram 里给 bot 发 /start 测试。"
echo "============================================================"
