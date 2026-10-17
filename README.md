# 常青藤 · 双向客服机器人

> Telegram 双向匿名客服机器人 —— 陌生人私聊机器人，消息自动落入后台群组的独立**话题（Topic）**，你在群里回复即可原路发回给对方。
> 基于 [52Lxcloud/TGChatBot](https://github.com/52Lxcloud/TGChatBot) 深度改造，由 **Callia** 二次开发。

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](./LICENSE)
[![Platform: Cloudflare Workers](https://img.shields.io/badge/Platform-Cloudflare%20Workers-F38020.svg)](https://workers.cloudflare.com/)

---

## 这个项目解决什么问题

第三方双向客服机器人最大的痛点是**入口无验证**：任何爬虫号、营销号都能直接私聊机器人，把广告灌进你的后台群。

常青藤在消息转发前加了一道**人机验证闸门**：

```
陌生人 → 私聊 Bot → 未验证？→ 弹出「点击验证」按钮
                                    ↓
                        打开 Telegram Mini App
                                    ↓
                     Cloudflare Turnstile 自动人机验证
                                    ↓
                    校验 initData 签名 → 写入 is_verified=1
                                    ↓
                  消息转发进后台群的话题 → 你回复 → 原路发回
```

验证通过后 **3 天内免重复验证**（活跃自动续期），话题空闲 3 天自动清理，清理后下次再聊需重新验证。

---

## 核心特性

| 能力 | 说明 |
|---|---|
| **Mini App + Turnstile 验证** | 点击按钮打开 Telegram Mini App，Cloudflare Turnstile 静默人机验证，无感通过 |
| **算术题回退** | 未配置 Turnstile 时自动降级为按钮式算术验证，零外部依赖 |
| **`initData` 签名校验** | HMAC-SHA256 校验 Telegram 签名 + `auth_date` 新鲜度，**无法伪造 user_id** |
| **Webhook 来源校验** | `secret_token` + `X-Telegram-Bot-Api-Secret-Token` 头比对，杜绝伪造更新 |
| **一人一话题** | 每个用户独占一个 Forum Topic，互不串台 |
| **话题空闲自动清理** | 默认 3 天无活动自动删话题 + 清状态，避免话题堆积 |
| **验证有效期管理** | 默认 3 天，活跃用户自动续期，不打扰正常用户 |
| **频率限制** | 默认 30 条/分钟，超频**静默丢弃**（不重发验证） |
| **管理员鉴权** | 只有后台群管理员在话题里的发言才会转发，防止群成员冒充客服 |
| **文本降级** | Markdown 解析失败自动退化为纯文本重发，不再丢消息 |
| **零外部依赖** | 欢迎/通知文案已本地内嵌，不再运行时拉取 GitHub raw |

---

## 架构

```
┌──────────────┐   私聊     ┌─────────────────────────────┐
│   陌生人      │ ─────────▶ │  Telegram Bot @CamrlliaBot  │
└──────────────┘            └──────────────┬──────────────┘
                                           │ webhook
                                           ▼
                        ┌──────────────────────────────────┐
                        │  Cloudflare Worker (worker.js)   │
                        │  ├─ /webhook       接收更新       │
                        │  ├─ /verify        Mini App 验证页 │
                        │  ├─ /verify/check  Turnstile 校验 │
                        │  ├─ /registerWebhook              │
                        │  └─ /checkTables                   │
                        └────────┬─────────────────┬────────┘
                                 │                 │
                    ┌────────────▼──────┐  ┌───────▼────────┐
                    │   Cloudflare D1   │  │  Turnstile API │
                    │  user_states      │  └────────────────┘
                    │  message_rates    │
                    │  chat_topic_maps  │
                    └───────────────────┘
                                 │ createForumTopic / sendMessage
                                 ▼
                    ┌──────────────────────────────────┐
                    │  后台群（Forum 模式）             │
                    │  ├─ 话题 #12 · 用户A              │
                    │  ├─ 话题 #13 · 用户B              │
                    │  └─ 话题 #14 · 用户C              │
                    │  管理员在话题内回复 → 原路发回     │
                    └──────────────────────────────────┘
```

---

## 快速开始

### 前置准备

1. **Cloudflare 账号** + API Token（需要 `Workers Scripts:Edit`、`D1:Edit`、`Account Settings:Read` 权限；要建 Turnstile 还需 `Turnstile:Edit`）
2. **Telegram Bot** —— 找 [@BotFather](https://t.me/BotFather) 发 `/newbot`，拿到 Bot Token
3. **后台群** —— 新建一个群，在群设置里开启「**话题（Topics）**」，把 bot 拉进去设为**管理员**并勾选「管理话题」
4. **群 ID** —— 把群 ID 发消息给 [@userinfobot](https://t.me/userinfobot) 可查（形如 `-100xxxxxxxxxx`）

### 一键部署

```bash
git clone https://github.com/Callia218/TGChatBot-Callia.git
cd TGChatBot-Callia

CF_TOKEN=你的CF令牌 \
ACCOUNT_ID=你的账号ID \
BOT_TOKEN=你的BotToken \
GROUP_ID=-100xxxxxxxxxx \
TURNSTILE_SITEKEY=0x4AAAAAAA... \
TURNSTILE_SECRET=0x4AAAAAAA... \
./deploy.sh
```

脚本会自动：校验令牌 → 建/复用 D1 → 生成 Webhook 密钥 → 上传 Worker → 启用 workers.dev 子域 → 触发初始化（注册 webhook）。

> 本机访问不到 `workers.dev` 时，用浏览器打开脚本输出的 Worker 地址一次即可完成初始化。

部署完成后给 bot 发 `/start`，应当看到「点击验证」按钮。

详见 [docs/DEPLOY.md](./docs/DEPLOY.md)（含 Turnstile 建站、手动部署、常见报错排查）。

---

## 配置项

全部通过 Cloudflare Worker 的 **环境变量绑定**注入，不写进代码：

| 绑定名 | 必填 | 说明 |
|---|---|---|
| `D1` | ✅ | D1 数据库绑定（type: `d1`） |
| `BOT_TOKEN_ENV` | ✅ | BotFather 给的 Bot Token |
| `GROUP_ID_ENV` | ✅ | 后台群 ID，`-100` 开头 |
| `MAX_MESSAGES_PER_MINUTE_ENV` | ⬜ | 每用户每分钟消息上限，默认 `30` |
| `TURNSTILE_SITEKEY_ENV` | ⬜ | Turnstile 站点密钥，留空则回退算术验证 |
| `TURNSTILE_SECRET_ENV` | ⬜ | Turnstile 服务端密钥 |
| `WEBHOOK_SECRET_ENV` | ⬜ | webhook 校验密钥；**强烈建议配置**，否则 webhook 可被伪造 |

代码内的可调常量（`worker.js` 顶部）：

```js
const TOPIC_IDLE_DAYS = 3;                          // 话题空闲多少天后自动删除
const VERIFICATION_VALID_SECONDS = 3 * 24 * 60 * 60; // 验证有效期（秒）
const IDLE_CLEANUP_INTERVAL = 5 * 60 * 1000;         // 清理检查间隔
```

---

## 数据表

`worker.js` 启动时会自动建表并做 `ALTER TABLE` 迁移，**无需手动执行 SQL**。

| 表 | 用途 |
|---|---|
| `user_states` | 用户验证状态、封禁状态、验证码、有效期 |
| `message_rates` | 频率限制计数窗口 |
| `chat_topic_mappings` | `用户ID → 话题ID` 映射 + `last_activity` 活跃时间 |
| `settings` | 全局配置键值 |

---

## 命令

在**私聊**中对 bot 发送：

| 命令 | 作用 |
|---|---|
| `/start` | 开始对话 / 触发验证 |

在**后台群话题内**发送：

| 命令 | 作用 |
|---|---|
| `/block` | 屏蔽当前话题对应的用户 |
| `/unblock` | 解除屏蔽 |
| `/checkblock` | 查看屏蔽状态 |

---

## 安全说明

- **`/verify/check` 强制校验 `initData` HMAC 签名**，密钥为 `WebAppData`、消息为 Bot Token，并检查 `auth_date` 不超过 24 小时 —— 伪造 `user_id` 会被拒绝。
- **`/webhook` 校验 `X-Telegram-Bot-Api-Secret-Token`**。配置了 `WEBHOOK_SECRET_ENV` 后，未携带正确头部的请求直接 403。
- **管理端点鉴权**：`/registerWebhook`、`/unRegisterWebhook`、`/checkTables` 在配置了 `WEBHOOK_SECRET_ENV` 后，必须带 `?token=<密钥>` 或请求头 `X-Admin-Token`，否则 403。
  > ⚠️ 这三个端点早期是无鉴权的。`/unRegisterWebhook` 只要被任何人访问一次，就会把 Telegram webhook 清空、机器人立刻失联 —— 这是**必须配 `WEBHOOK_SECRET_ENV`** 的另一个理由。
- **后台群管理员鉴权**：只有 `administrator` / `creator` 在话题里的发言才会转发给用户。
- **不要把 `metadata.json` / `turnstile.json` / `.env` 提交到仓库** —— 里面是 Bot Token 和 Turnstile Secret，泄露等于 bot 被接管。`.gitignore` 已默认忽略。

---

## 与上游的差异

本项目基于 [52Lxcloud/TGChatBot](https://github.com/52Lxcloud/TGChatBot)，主要改动：

1. 新增 **Telegram Mini App + Cloudflare Turnstile** 验证链路（`/verify`、`/verify/check`、`verify.html`）
2. 新增 **`initData` HMAC-SHA256 签名校验**
3. 新增 **webhook `secret_token` 来源校验**
4. 修复：`userStateCache` 结构冲突导致**每次发消息都要求重新验证**
5. 修复：话题通知 Markdown 解析失败导致**话题成孤儿、话题内无消息**
6. 修复：消息速率缓存键冲突
7. 新增：**话题空闲自动清理** + 删除用户时同步删话题
8. 新增：**后台群管理员鉴权**，堵住群成员冒充客服的漏洞
9. 改进：Markdown 解析失败自动降级为纯文本
10. 改进：欢迎/通知文案**本地内嵌**，去除对 GitHub raw 的运行时依赖
11. 新增：一键部署脚本 `deploy.sh`（纯 REST API，不依赖 wrangler）

---

## 许可证

[GPL-3.0](./LICENSE)

上游 [52Lxcloud/TGChatBot](https://github.com/52Lxcloud/TGChatBot) 采用 GPL-3.0，因此本衍生作品同样以 GPL-3.0 发布。你可以自由使用、修改、分发，但**衍生作品必须同样开源**。
