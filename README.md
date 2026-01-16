---

# 🔐 Bitwarden 自动化部署系统  
> 🛡️ 高可用 · 端到端加密 · 双账号灾备  
> 一键安装 | 自动 HTTPS | R2 加密备份 | 支持恢复

🔗 项目地址：[https://github.com/sikiyz/bitwarden-auto](https://github.com/sikiyz/bitwarden-auto)  
🎯 适用于个人/家庭/团队密码库自托管

---

## 🚀 快速开始（一行命令）

```bash
# 下载并运行一键部署脚本
curl -sSL https://raw.githubusercontent.com/sikiyz/bitwarden-auto/main/setup.sh | sudo bash
```

> ⚠️ 请以 **root 用户** 运行，支持 Ubuntu / Debian / CentOS / Rocky / Fedora / SUSE

---

## ✅ 核心特性

| 功能 | 说明 |
|------|------|
| 🌐 域名反代 + HTTPS | 自动申请 Let's Encrypt 证书，支持自动续期 |
| 💾 双 CF 账号 R2 备份 | 数据同时上传至两个独立 Cloudflare 账号，防止单点故障 |
| 🔒 GPG AES256 加密 | 所有备份在上传前加密，云端无法窥探内容 |
| 📦 智能清理策略 | 自动删除 15 天以上的旧备份，但 **至少保留一个** 防误删 |
| 🔄 支持恢复模式 | 服务器损坏后可从 R2 完整恢复所有数据 |
| 📬 通知提醒 | Telegram 或 Email 通知每日备份结果与文件名 |
| 🧩 全平台兼容 | 自动识别系统类型并安装依赖（Docker/Nginx/Certbot） |

---

## 🧰 使用流程

### 1. 准备工作

#### ✅ 域名解析
- 准备一个域名（如 `vault.yourdomain.com`）
- 将其 A 记录指向你的 VPS IP

#### ✅ 创建两个 Cloudflare 账号的 R2 存储桶
> 推荐使用 **两个不同邮箱注册的 CF 账号** 实现真正隔离

| 步骤 | 操作 |
|------|------|
| 登录 CF 控制台 | [https://dash.cloudflare.com](https://dash.cloudflare.com) |
| 进入 R2 页面 | 左侧菜单 → Storage → R2 |
| 创建 Bucket | 点击 “Create bucket”，命名如 `bw-primary` 和 `bw-backup-dr` |
| 获取 API Key | 在「Manage R2 API Keys」中创建 Access Key（记录 ID 和 Secret） |

#### ✅ （可选）Telegram Bot 设置
- 与 [@BotFather](https://t.me/BotFather) 对话创建机器人
- 获取 `Bot Token`
- 使用 [@getmyid_bot](https://t.me/getmyid_bot) 获取你的 `Chat ID`

---

### 2. 执行部署

```bash
# 方法一：直接运行（推荐）
curl -sSL https://raw.githubusercontent.com/sikiyz/bitwarden-auto/main/setup.sh | sudo bash

# 方法二：手动下载查看后再运行
wget https://raw.githubusercontent.com/sikiyz/bitwarden-auto/main/setup.sh
chmod +x setup.sh
sudo ./setup.sh
```

---

### 3. 交互式配置向导

脚本会引导你完成以下输入：

```text
========================================
   🔐 Bitwarden 一键部署（加密容灾版）
========================================

当前系统: Ubuntu 22.04

请选择模式：
1) 初次部署
2) 从 R2 恢复数据
> 输入 1 或 2: 1

🔹 域名 (如 vault.example.com): vault.mysecrets.cloud
🔹 管理员邮箱: admin@mysecrets.cloud

🔐 配置第一个 Cloudflare 账号
🔹 Account ID: f47e8a7d-xxxx-xxxx-xxxx-yyyyyyyyyyyy
🔹 Access Key: AKIAxxxxxxxxxxxxxxxx
🔹 Secret Key: ****************************************
🔹 Bucket 名称: bw-primary-backup

🔐 配置第二个 Cloudflare 账号
🔹 Account ID: a1b2c3d4-xxxx-xxxx-xxxx-zzzzzzzzzzzz
🔹 Access Key: AKIAyyyyyyyyyyyyyyyy
🔹 Secret Key: ****************************************
🔹 Bucket 名称: bw-disaster-recovery

🔹 为备份设置加密密码（用于 GPG 加密）: ********
❓ 启用 Telegram 通知？(y/N): y
🔹 Bot Token: 123456:ABCdefGHIjklMNopqRSTUvwx
🔹 Chat ID: 987654321

❓ 确认使用以上配置？(y/N): y
```

> ✅ 所有配置仅在本地使用，不会上传到任何地方

---

## 🔁 灾难恢复（换服务器时）

当原 VPS 损坏或迁移时，在新机器上重复上述步骤：

```bash
curl -sSL https://raw.githubusercontent.com/sikiyz/bitwarden-auto/main/setup.sh | sudo bash
```

选择 **模式 2：从 R2 恢复数据**

然后填写相同的配置信息，并在恢复阶段输入 **加密密码** 解密 `.gpg` 文件。

✅ 恢复后所有用户账户、密码条目、TOTP 密钥均完好无损。

---

## 🗂️ 目录结构

```
/opt/bitwarden/
├── data/                   # Vaultwarden 核心数据（SQLite、密钥等）
├── docker-compose.yml      # 服务定义
└── backups/                # 本地临时备份（保留最近7天）

/usr/local/bin/bitwarden-backup.sh     # 每日加密备份脚本
/var/log/bitwarden-setup.log           # 安装日志
/var/log/bitwarden-backup.log          # 每日备份执行日志
```

---

## 🕒 自动化任务（cron）

| 任务 | 时间 | 命令 |
|------|------|------|
| 每日加密备份 | 每日凌晨 2:00 | `/usr/local/bin/bitwarden-backup.sh` |
| 证书自动续期 | 每日凌晨 3:00 | `certbot renew --post-hook 'systemctl reload nginx'` |

查看定时任务：
```bash
crontab -l
```

---

## 🔐 安全建议

| 项目 | 建议 |
|------|------|
| 加密密码 | 写在纸上并离线保存，切勿丢失 |
| Admin Token | 位于 `/opt/bitwarden/admin_token`，用于登录 `/admin` 管理面板 |
| 恢复演练 | 每季度测试一次恢复流程 |
| 客户端更新 | 更换服务器后，需在每台设备上更新自定义服务器地址 |
| 日志监控 | 定期检查 `/var/log/bitwarden-backup.log` 是否报错 |

---

## 📣 通知示例（Telegram）

```
🔐 加密备份成功
📅 Sun Apr 6 02:00:01 CST 2025
📄 bitwarden-20250406-020000.tar.gz.gpg
📍 CF1: bw-primary-backup
📍 CF2: bw-disaster-recovery
💡 使用 AES256-GPG 加密
```

---

## ❓ 常见问题

### Q：如果忘了加密密码怎么办？
❌ **无法恢复**。GPG 加密是单向的，必须记住密码才能解密。建议离线保存。

### Q：能否支持 Backblaze B2 / AWS S3？
✅ 可扩展。当前基于 `s3cmd`，只需修改 endpoint 即可对接其他 S3 兼容存储。

### Q：客户端如何切换服务器？
进入 Bitwarden App 或浏览器插件 → 设置 → 服务器 →  
关闭“使用官方服务器” → 输入你的域名（如 `https://vault.mysecrets.cloud`）

### Q：为什么必须 root 用户运行？
为了自动化安装 Docker、Nginx、Certbot 等系统级组件，避免权限不足。

---

## 📎 推荐附件（可自行创建）

你可以添加以下辅助文件到私有文档中：

- `recovery-guide.pdf` —— 图文恢复操作手册
- `credentials.txt.gpg` —— 加密保存所有敏感信息
- `backup-status.html` —— 简易网页展示最近备份状态

---

## 🤝 致谢

- [Vaultwarden](https://github.com/dani-garcia/vaultwarden) – 开源核心引擎
- [Cloudflare R2](https://www.cloudflare.com/products/r2/) – 低成本对象存储
- [Let's Encrypt](https://letsencrypt.org/) – 免费 HTTPS 证书颁发机构

---

## 📬 联系作者 & 反馈

欢迎提交 Issue 或 Pull Request！

GitHub: [https://github.com/sikiyz/bitwarden-auto](https://github.com/sikiyz/bitwarden-auto)  
Issues: [https://github.com/sikiyz/bitwarden-auto/issues](https://github.com/sikiyz/bitwarden-auto/issues)

> 🔐 你的密码，永远只属于你自己。不上传、不追踪、完全自主掌控。

---
