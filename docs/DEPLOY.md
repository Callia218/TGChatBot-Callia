# 部署指南

## 目录

- [一、准备工作](#一准备工作)
- [二、创建 Cloudflare Turnstile 站点](#二创建-cloudflare-turnstile-站点)
- [三、一键部署](#三一键部署)
- [四、手动部署（REST API）](#四手动部署rest-api)
- [五、部署后自检](#五部署后自检)
- [六、常见报错](#六常见报错)

---

## 一、准备工作

### 1. Cloudflare API Token

进入 Cloudflare Dashboard → 右上角头像 → **My Profile** → **API Tokens** → **Create Token** → 选 **Custom token**。

权限至少包含：

| 范围 | 权限 | 用途 |
|---|---|---|
| Account | Workers Scripts : Edit | 上传 Worker |
| Account | D1 : Edit | 创建/绑定数据库 |
| Account | Account Settings : Read | 读取 workers.dev 子域 |
| Account | Turnstile : Edit | 建 Turnstile 站点（可选） |

> ⚠️ 不需要 Zone 级权限。本项目走 `workers.dev` 子域，不绑自定义域名 —— 绑自定义域名需要 Zone 权限，而 Zone 权限会让 Token 范围过大。

同时记下 **Account ID**（Dashboard 右侧栏可见）。

### 2. Telegram Bot

找 [@BotFather](https://t.me/BotFather)：

```
/newbot
→ 输入显示名（如：常青藤）
→ 输入用户名（必须以 bot 结尾，如：CamrlliaBot）
→ 得到 Bot Token：1234567890:AAHxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

> 想改显示名随时 `/setname`，想改头像 `/setuserpic`。

### 3. 后台群

1. 新建一个群（可以只有你一个人，也可以把第二个小号拉进来）
2. 群设置 → **Topics（话题）** → 打开
3. 把 bot 拉进群，设为**管理员**，勾选：
   - ✅ 管理话题（Manage Topics）
   - ✅ 删除消息（Delete Messages，可选）
4. 获取群 ID：把任意消息转发给 [@userinfobot](https://t.me/userinfobot)，或把 bot 拉群后访问
   `https://api.telegram.org/bot<你的TOKEN>/getUpdates` 查看 `chat.id`

> 群 ID 一定是负数，超级群以 `-100` 开头，例如 `-1001234567890`。

---

## 二、创建 Cloudflare Turnstile 站点

> 不想要 Turnstile 也可以跳过 —— 代码会自动回退到**按钮式算术验证**。

1. Cloudflare Dashboard → **Turnstile** → **Add Site**
2. 填写：
   - **Site name**：随便，如 `tgchatbot-verify`
   - **Domain**：填 `<你的Worker名>.<你的子域>.workers.dev`（例如 `tgchatbot.abcdefg.workers.dev`）
   - **Widget Mode**：`Managed`
3. 创建后得到 **Site Key**（`0x4AAA...`）和 **Secret Key**（`0x4AAA...`）

> 💡 拿 Secret 的小技巧：**列表页不显示 Secret**。要查 Secret，点进站点详情，或调
> `GET /accounts/{account_id}/challenges/widgets/{sitekey}` 单条查询。

---

## 三、一键部署

```bash
git clone https://github.com/Callia218/TGChatBot-Callia.git
cd TGChatBot-Callia

chmod +x deploy.sh

CF_TOKEN=xxx \
ACCOUNT_ID=xxx \
BOT_TOKEN=xxx \
GROUP_ID=-100xxxxxxxxxx \
TURNSTILE_SITEKEY=0x4AAAAAAAxxx \
TURNSTILE_SECRET=0x4AAAAAAAxxx \
./deploy.sh
```

依赖：`bash` + `curl` + `jq`。

脚本流程：

```
1/7 校验 Cloudflare Token
2/7 准备代码（注入 Turnstile sitekey 到 verify.html）
3/7 创建/复用 D1 数据库
4/7 生成 Webhook 密钥（openssl rand -hex 32）
5/7 上传 Worker（7 个 bindings）
6/7 启用 workers.dev 子域
7/7 触发初始化（自动注册 Telegram Webhook）
```

> **重要**：脚本最后会打印 `WEBHOOK_SECRET`，请自行保存。之后手动调 `setWebhook` 时必须带上同一个值，否则 webhook 会因校验失败返回 403。

---

## 四、手动部署（REST API）

不用脚本，纯 curl：

```bash
API=https://api.cloudflare.com/client/v4
CF_TOKEN=xxx
ACCOUNT_ID=xxx

# 1. 建 D1
DB_ID=$(curl -sS -X POST -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  "$API/accounts/$ACCOUNT_ID/d1/database" \
  -d '{"name":"tgchatbot-db"}' | jq -r '.result.uuid')

# 2. 生成 webhook secret
WS=$(openssl rand -hex 32)

# 3. 注入 sitekey 到 verify.html
sed "s/__SITEKEY__/0x4AAAAAAAxxx/" verify.html > build_verify.html

# 4. 写 metadata
jq -n --arg db "$DB_ID" --arg bt "1234567890:AAHxxxxxxxxxxxxxxxxxxxxx" --arg gid "-100xxxxxxxxxx" \
      --arg ws "$WS" --arg sk "0x4AAAAAAAxxx" --arg ss "0x4AAAAAAAxxx" '{
  main_module: "worker.js",
  compatibility_date: "2024-11-01",
  bindings: [
    { type: "d1",         name: "D1",                          id: $db },
    { type: "plain_text", name: "BOT_TOKEN_ENV",               text: $bt },
    { type: "plain_text", name: "GROUP_ID_ENV",                text: $gid },
    { type: "plain_text", name: "MAX_MESSAGES_PER_MINUTE_ENV", text: "30" },
    { type: "plain_text", name: "TURNSTILE_SITEKEY_ENV",       text: $sk },
    { type: "plain_text", name: "TURNSTILE_SECRET_ENV",        text: $ss },
    { type: "plain_text", name: "WEBHOOK_SECRET_ENV",          text: $ws }
  ]
}' > metadata.json

# 5. 上传 Worker
curl -sS -X PUT -H "Authorization: Bearer $CF_TOKEN" \
  -F "metadata=@metadata.json;type=application/json" \
  -F "worker.js=@worker.js;type=application/javascript+module" \
  "$API/accounts/$ACCOUNT_ID/workers/scripts/tgchatbot"

# 6. 启用子域
curl -sS -X POST -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  "$API/accounts/$ACCOUNT_ID/workers/scripts/tgchatbot/subdomain" \
  -d '{"enabled":true,"previews_enabled":true}'

# 7. 触发初始化
curl -sS "https://tgchatbot.<子域>.workers.dev/"
```

> ⚠️ 注意：`verify.html` 只是验证页的**源码参考**。线上实际返回的验证页来自
> `worker.js` 内的 `VERIFY_PAGE_HTML` 常量 —— Worker 在响应 `/verify` 时会把其中的
> `__SITEKEY__` 占位符替换为 `TURNSTILE_SITEKEY_ENV`。改动验证页样式时，
> **两处都要同步**。

---

## 五、部署后自检

### 1. 检查 webhook

```bash
curl -sS "https://api.telegram.org/bot<TOKEN>/getWebhookInfo" | jq
```

期望：

```json
{
  "ok": true,
  "result": {
    "url": "https://tgchatbot.xxx.workers.dev/webhook",
    "pending_update_count": 0
  }
}
```

### 2. 检查数据表

```bash
curl -sS "https://tgchatbot.xxx.workers.dev/checkTables"
# → Database tables checked and repaired
```

或在 Cloudflare Dashboard → D1 → 你的库 → Console 执行：

```sql
SELECT name FROM sqlite_master WHERE type='table';
-- user_states / message_rates / chat_topic_mappings / settings
```

### 3. 检查 webhook 鉴权是否生效

```bash
# 不带 secret 头 —— 应当返回 403
curl -sS -o /dev/null -w "%{http_code}\n" \
  -X POST -H "Content-Type: application/json" \
  -d '{"update_id":1}' \
  "https://tgchatbot.xxx.workers.dev/webhook"
```

### 4. 端到端测试

用**另一个 Telegram 账号**（非管理员）私聊 bot 发 `/start`：

- ✅ 应当收到「🛡️ 请点击下方按钮完成人机验证」+ 按钮
- ✅ 点击按钮打开 Mini App，Turnstile 自动通过，显示「验证成功，窗口即将关闭」
- ✅ 后台群自动创建该用户的话题，话题内有置顶通知
- ✅ 用户再发消息，内容出现在对应话题里
- ✅ 你在话题内回复，用户私聊里收到回复

---

## 六、常见报错

| 现象 | 原因 | 解决 |
|---|---|---|
| `10026 Could not parse request body` | 用 REST API 注册 cron 触发器，Token 权限不足 | 本项目**不用 cron**，改用请求路径上的惰性清理，忽略此错 |
| `10405 Method not allowed for this authentication scheme` | Token 缺 Zone 权限，无法绑自定义域名 | 用 `workers.dev` 子域；或给 Token 加 Zone 权限 |
| Worker 上传成功但 D1 为空 | 从未被访问过，初始化未触发 | 用浏览器打开一次 Worker 根地址 |
| `/webhook` 返回 403 | `WEBHOOK_SECRET_ENV` 已配置，但 Telegram 没带正确 header | 重新调 `setWebhook` 并在 body 里带 `secret_token`；或清空该绑定 |
| 每次发消息都要求验证 | 旧版缓存 bug（已在 v2 修复） | 升级到最新 `worker.js` |
| 话题建了但里面没消息 | 用户名含特殊字符导致 Markdown 解析失败（已在 v2 修复） | 升级到最新 `worker.js` |
| 验证页白屏 | Turnstile 域名与实际访问域名不一致 | 在 Turnstile 站点设置里补上 `workers.dev` 域名 |
| 用户点验证后没反应 | Mini App 必须在 **Telegram 客户端内**打开 | 不要在浏览器里点；必须从 TG 聊天窗口点按钮 |
| 群里回复没转发给用户 | 回复者不是管理员，或回复不在对应话题内 | 确认回复者账号是群管理员；确认在正确的话题里回复 |

---

## 附：清理测试残留话题

```bash
# 删除某个话题
curl -sS "https://api.telegram.org/bot<TOKEN>/deleteForumTopic" \
  -H "Content-Type: application/json" \
  -d '{"chat_id":-100xxxxxxxxxx,"message_thread_id":12}'
```

话题空闲 3 天会被自动清理，测试残留一般不用管。
