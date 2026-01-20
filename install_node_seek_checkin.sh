#!/bin/bash
# NodeSeek 自动签到一键安装脚本（交互式配置）
# 说明：
# - 支持账号密码或浏览器 Cookie 两种登录方式
# - 自动创建 Python 虚拟环境、安装依赖、定时任务
# - 每天定时执行，支持自定义时间
# - Telegram 通知签到结果
# 注意：请确保系统已安装 python3（建议 3.7+）

set -eo pipefail
IFS=$'\n\t'

echo "================ NodeSeek 自动签到一键安装 ================"

# 确定实际用户的家目录（兼容 sudo 和普通用户）
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ -d "/home/${SUDO_USER}" ]; then
  USER_HOME="/home/${SUDO_USER}"
elif [ "$(id -u)" -eq 0 ]; then
  USER_HOME="/root"
else
  USER_HOME="$HOME"
fi

SCRIPT_DIR="$USER_HOME/node_seek_checkin"
VENV_DIR="$SCRIPT_DIR/venv"
LOG_FILE="$SCRIPT_DIR/checkin.log"

mkdir -p "$SCRIPT_DIR"
cd "$SCRIPT_DIR"

echo ""
echo "请选择登录方式："
echo "  1) 账号密码（输入邮箱和密码）"
echo "  2) 浏览器 Cookie（稳定性更高，推荐）"
read -rp "请输入数字选择 [1/2] (默认 1): " LOGIN_CHOICE
LOGIN_CHOICE="${LOGIN_CHOICE:-1}"

USE_COOKIE="0"
NODESEEK_USERNAME=""
NODESEEK_PASSWORD=""
NODESEEK_COOKIE=""

if [ "$LOGIN_CHOICE" = "2" ]; then
  USE_COOKIE="1"
  echo ""
  echo "请在已登录 NodeSeek 的浏览器里复制完整 Cookie（包含多个键值对，用分号空格分隔）"
  echo "示例：cf_clearance=...; nodeseek_session=...; xxx=..."
  read -rp "粘贴你的 Cookie: " NODESEEK_COOKIE
  while [ -z "$NODESEEK_COOKIE" ]; do
    echo "Cookie 不能为空！"
    read -rp "粘贴你的 Cookie: " NODESEEK_COOKIE
  done
else
  echo ""
  read -rp "NodeSeek 登录邮箱: " NODESEEK_USERNAME
  while [ -z "$NODESEEK_USERNAME" ]; do
    echo "邮箱不能为空！"
    read -rp "NodeSeek 登录邮箱: " NODESEEK_USERNAME
  done

  read -rsp "NodeSeek 登录密码: " NODESEEK_PASSWORD
  echo ""
  while [ -z "$NODESEEK_PASSWORD" ]; do
    echo "密码不能为空！"
    read -rsp "NodeSeek 登录密码: " NODESEEK_PASSWORD
    echo ""
  done
fi

echo ""
echo "配置 Telegram 通知（必填，用于接收签到结果）"
read -rp "Telegram Bot Token（形如 123456:ABC-DEF...）: " TELEGRAM_BOT_TOKEN
while [ -z "$TELEGRAM_BOT_TOKEN" ]; do
  echo "Bot Token 不能为空！"
  read -rp "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
done

read -rp "Telegram Chat ID（你的 ID 或群 ID，可为负数）: " TELEGRAM_CHAT_ID
while ! [[ "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]]; do
  echo "请输入有效的数字 Chat ID（可为负数）"
  read -rp "Telegram Chat ID: " TELEGRAM_CHAT_ID
done

echo ""
read -rp "设置每日签到时间（24小时制，格式 HH:MM，默认 08:00）: " SCHEDULE_TIME
SCHEDULE_TIME="${SCHEDULE_TIME:-08:00}"
if [[ ! "$SCHEDULE_TIME" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
  echo "时间格式无效，使用默认 08:00"
  SCHEDULE_TIME="08:00"
fi
CRON_HOUR="${SCHEDULE_TIME%%:*}"
CRON_MIN="${SCHEDULE_TIME##*:}"

# 写入 .env（仅当前用户可读写）
cat > "$SCRIPT_DIR/.env" <<EOF
USE_COOKIE=${USE_COOKIE}
NODESEEK_USERNAME=${NODESEEK_USERNAME}
NODESEEK_PASSWORD=${NODESEEK_PASSWORD}
NODESEEK_COOKIE=${NODESEEK_COOKIE}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
# 如需自定义接口，可调整以下地址（默认无需修改）
LOGIN_URL=https://www.nodeseek.com/api/user/login
CHECKIN_URL=https://www.nodeseek.com/api/checkin
EOF
chmod 600 "$SCRIPT_DIR/.env"
echo "已生成配置文件：$SCRIPT_DIR/.env（权限已设为 600）"

# 生成 Python 签到脚本
cat > "$SCRIPT_DIR/checkin.py" <<'PYEOF'
import os
import sys
import json
import time
import requests
from datetime import datetime

USE_COOKIE = os.getenv("USE_COOKIE", "0") == "1"
USERNAME = os.getenv("NODESEEK_USERNAME", "")
PASSWORD = os.getenv("NODESEEK_PASSWORD", "")
COOKIE_STR = os.getenv("NODESEEK_COOKIE", "")

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "")

LOGIN_URL = os.getenv("LOGIN_URL", "https://www.nodeseek.com/api/user/login")
CHECKIN_URL = os.getenv("CHECKIN_URL", "https://www.nodeseek.com/api/checkin")

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0 Safari/537.36"

def send_telegram(text: str):
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        print("[Warn] Telegram 配置缺失，无法发送通知")
        return
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    payload = {
        "chat_id": TELEGRAM_CHAT_ID,
        "text": text,
        "disable_web_page_preview": True,
    }
    try:
        r = requests.post(url, data=payload, timeout=10)
        if r.status_code != 200:
            print(f"[Telegram] 发送失败：{r.status_code} {r.text}")
    except Exception as e:
        print(f"[Telegram] 异常：{e}")

def parse_cookie_dict(cookie_str: str):
    cookie = {}
    for part in cookie_str.split(";"):
        part = part.strip()
        if not part:
            continue
        if "=" in part:
            k, v = part.split("=", 1)
            cookie[k.strip()] = v.strip()
    return cookie

def do_login(session: requests.Session):
    headers = {
        "User-Agent": UA,
        "Origin": "https://www.nodeseek.com",
        "Referer": "https://www.nodeseek.com/",
        "Content-Type": "application/json;charset=UTF-8",
    }
    payload = {"username": USERNAME, "password": PASSWORD}
    r = session.post(LOGIN_URL, headers=headers, json=payload, timeout=15)
    if r.status_code != 200:
        raise RuntimeError(f"登录请求失败 HTTP {r.status_code}")
    try:
        j = r.json()
    except Exception:
        raise RuntimeError(f"登录接口返回非 JSON：{r.text[:200]}")
    if not j.get("success"):
        raise RuntimeError(f"登录失败：{j.get('message','未知错误')}")
    return True

def do_checkin(session: requests.Session):
    headers = {"User-Agent": UA, "Origin": "https://www.nodeseek.com", "Referer": "https://www.nodeseek.com/"}
    r = session.post(CHECKIN_URL, headers=headers, timeout=15)
    if r.status_code != 200:
        raise RuntimeError(f"签到请求失败 HTTP {r.status_code}")
    try:
        j = r.json()
    except Exception:
        raise RuntimeError(f"签到接口返回非 JSON：{r.text[:200]}")
    return j

def main():
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    sess = requests.Session()
    sess.headers
