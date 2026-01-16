---

✅ **亮点功能：**
- ✅ 极简美观 + Markdown 高级排版
- ✅ 内嵌「运行过程演示」截图描述（纯文本模拟）
- ✅ 支持一键安装、快捷命令 `bd`
- ✅ 图标丰富、结构清晰
- ✅ 中文友好，适合国内用户

---

## 📄 `README.md`

```markdown
# 🔐 Bitwarden Auto — 一键部署 | 双 R2 容灾 | GPG 加密备份

> 🚀 三分钟部署属于你的私有密码管理服务 —— 安全、自动、高可用  
> 💾 支持双 Cloudflare R2 备份 + GPG 加密 + 自动 HTTPS + 多通知

![License](https://img.shields.io/github/license/sikiyz/bitwarden-auto)
![Stars](https://img.shields.io/github/stars/sikiyz/bitwarden-auto?style=social)
![Forks](https://img.shields.io/github/forks/sikiyz/bitwarden-auto?style=social)
![Last Commit](https://img.shields.io/github/last-commit/sikiyz/bitwarden-auto)

---

## 🌟 为什么选择它？

| 特性 | 说明 |
|------|------|
| 🔧 全自动部署 | 一行命令搞定 Docker + Caddy + Vaultwarden |
| 🛡️ 真·数据安全 | 所有备份均使用 **GPG AES256 加密**，云端也无法窥探 |
| ☁️ 双 R2 容灾 | 同时上传至两个 CF 账号，防止单点故障或误删 |
| 🕒 智能定时备份 | 每日凌晨 2:00 自动加密上传，并清理过期文件 |
| 📢 通知提醒 | Telegram / Email 实时推送部署与备份状态 |
| 🔄 快速恢复 | 支持从 R2 下载并解密还原全部数据 |
| 🆕 脚本自更新 | 输入 `4` 即可在线拉取最新版脚本 |
| ⌨️ 快捷命令 `bd` | 部署后可用 `bd` 唤起菜单，随时管理 |

---

## 🚀 快速开始

### 1. 一键安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/sikiyz/bitwarden-auto/main/setup.sh | sudo bash
```

### 2. 或手动运行

```bash
wget https://raw.githubusercontent.com/sikiyz/bitwarden-auto/main/setup.sh -O setup.sh
sudo chmod +x setup.sh
sudo ./setup.sh
```

> ✅ 首次运行将自动创建快捷命令 `bd`，之后只需输入：
>
> ```bash
> bd
> ```

---

## 🎮 使用流程演示

### 🖥️ 脚本运行全过程（文本模拟）

启动脚本后，您将看到如下交互式菜单：

```
========================================
   🔐 Bitwarden 一键部署（加密容灾版）
========================================

当前系统: Ubuntu 22.04.4 LTS (ID: ubuntu)

请选择模式：
0) 🚪 退出脚本
1) 💾 初次部署
2) 🔄 从 R2 恢复数据
3) 🖱️ 立即手动执行一次加密备份
4) 🔁 更新脚本至最新版
5) 📢 测试通知功能（Telegram / 邮箱）
6) 🔍 查看最近备份文件
选择 (0~6): 1
```

#### ➤ 输入域名和邮箱

```
🔹 域名 (如 vault.example.com): vault.mydomain.com
🔹 管理员邮箱 (Let's Encrypt 使用): admin@mydomain.com
```

#### ➤ 选择反向代理模式

```
请选择反向代理模式：
1) 自动检测（推荐：优先 IPv6 → IPv4 → 127.0.0.1）
2) 强制使用 IPv4
3) 强制使用 IPv6
4) 使用本地回环 127.0.0.1
请输入选项 [1-4] (默认为 1): 
```

> ✅ 推荐保持默认，自动识别最佳网络路径

#### ➤ 配置第一个 CF R2 账号

```
🔐 配置第一个 Cloudflare 账号
🔹 CF 账号1 Account ID: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
🔹 CF 账号1 Access Key: ********************************
🔹 CF 账号1 Secret Key: ******************************************************
🔹 CF 账号1 Bucket 名称: bitwarden-primary
```

#### ➤ 配置第二个 CF R2 账号（容灾）

```
🔐 配置第二个 Cloudflare 账号
🔹 CF 账号2 Account ID: yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy
🔹 CF 账号2 Access Key: ********************************
🔹 CF 账号2 Secret Key: ******************************************************
🔹 CF 账号2 Bucket 名称: bitwarden-secondary
```

#### ➤ 设置加密密码（关键！）

```
🔹 为备份设置加密密码（用于 GPG 加密）: ************
```

> 🔑 此密码不会被记录，请务必牢记！恢复时必须输入相同密码。

#### ➤ 选择通知方式

```
❓ 启用 Telegram 通知？(y/N): y
🔹 Bot Token: 1234567890:AAHxyz...
🔹 Chat ID: -1001234567890

❓ 启用邮件通知？(y/N): N
```

#### ➤ 确认配置

```
❓ 确认使用以上配置？(y/N): y
```

---

### 🚀 部署完成提示

```
==================================================
✅ 部署完成！
🌐 访问: https://vault.mydomain.com
🛠️  管理: https://vault.mydomain.com/admin
🔑 Token: a1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuVwXyZ==
📁 数据目录: /opt/bitwarden/data
📝 日志: /var/log/bitwarden-setup.log
🔐 双 R2 备份: bitwarden-primary (账号1), bitwarden-secondary (账号2)
🔒 加密算法: GPG + AES256
⏰ 自动备份: 每日凌晨 2:00
🧼 自动清理: R2 >15天（最少保留1个），本地 >7天
💡 重要：加密密码已保存，恢复时需手动输入
==================================================
```

🎉 同时您会收到一条 Telegram 通知：

> 🚀 Bitwarden 部署完成  
> 📍 vault.mydomain.com  
> 🔐 查看 Token: cat /opt/bitwarden/admin_token

---

## 🧰 功能详解

### ✅ `bd` 快捷命令（部署后可用）

| 命令 | 功能 |
|------|------|
| `bd` | 打开主菜单 |
| `bd` → `3` | 立即手动备份 |
| `bd` → `5` | 测试通知是否正常 |
| `bd` → `6` | 查看本地和云端最近备份 |

### ✅ 自动备份脚本

路径：`/usr/local/bin/bitwarden-backup.sh`  
日志：`/var/log/bitwarden-backup.log`

每天凌晨执行：
1. 打包 `/opt/bitwarden/data`
2. 使用 GPG 密码加密
3. 上传至两个 R2 存储桶
4. 删除超过 15 天的远程备份（至少保留 1 个）
5. 删除超过 7 天的本地备份

### ✅ 如何恢复数据？

1. 运行 `bd`
2. 选择 `2) 从 R2 恢复数据`
3. 输入相同的 **GPG 加密密码**
4. 脚本自动下载、解密、还原

---

## 🔐 安全策略

| 环节 | 保护措施 |
|------|----------|
| 传输 | HTTPS + Let's Encrypt |
| 存储 | GPG AES256 加密 `.tar.gz.gpg` 文件 |
| 备份 | 双 R2 账号异地冗余 |
| 清理 | 自动删除陈旧备份，防止堆积 |
| 权限 | 所有敏感文件权限设为 `600` |

> ⚠️ **警告**：忘记加密密码 = 无法恢复数据！

---

## ❗ 注意事项

- 请确保服务器开放 **端口 80 和 443**
- 域名需正确解析到本机 IP（支持 IPv4/IPv6）
- 推荐使用非 root 用户配合 `sudo`，但脚本需以 `root` 运行
- 不要随意删除 `/opt/bitwarden/` 目录
- 若更换服务器，请先通过 `bd` → `2` 恢复数据

---

## 🤝 反馈与贡献

欢迎提交 Issue 或 Pull Request！

如果您觉得这个项目对您有帮助，不妨给个 ⭐ Star 支持一下 ❤️

👉 [GitHub 仓库地址](https://github.com/sikiyz/bitwarden-auto)

---

## 📜 许可证

MIT License © 2025 sikiyz
```
