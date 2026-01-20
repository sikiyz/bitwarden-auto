#!/bin/bash

# NodeSeek 自动签到一键安装脚本（支持交互式输入）
# 作者：助手 @AI
# 支持：Linux 系统（Ubuntu/CentOS/Debian等）

set -euo pipefail
IFS=$'\n\t'

echo "🚀 欢迎使用 NodeSeek 自动签到一键安装脚本"
echo "--------------------------------------------------"

# 获取当前用户家目录（兼容 sudo）
if [ "$HOME" = "/root" ] && [ -n "${SUDO_USER}" ]; then
    USER_HOME=$(eval echo ~${SUDO_USER})
else
    USER_HOME="$HOME"
fi

SCRIPT_DIR="$USER_HOME/node_seek_checkin"
LOG_FILE="$SCRIPT_DIR/checkin.log"

# 创建项目目录
mkdir -p "$SCRIPT_DIR"
cd "$SCRIPT_DIR"

# === 交互式输入配置信息 ===
echo ""
echo "📝 请输入你的账户信息（请确保准确）："
echo ""

read -rp "📧 NodeSeek 登录邮箱: " NODESEEK_USERNAME
while [ -z "$NODESEEK_USERNAME" ]; do
    echo "⚠️ 邮箱不能为空！"
    read -rp "📧 NodeSeek 登录邮箱: " NODESEEK_USERNAME
done

read -rsp "🔐 NodeSeek 登录密码: " NODESEEK_PASSWORD
echo ""
while [ -z "$NODESEEK_PASSWORD" ]; do
    echo "⚠️ 密码不能为空！"
    read -rsp "🔐 NodeSeek 登录密码: " NODESEEK_PASSWORD
    echo ""
done
echo ""

read -rp "🤖 Telegram Bot Token (如 123456:ABC-DEF...): " TELEGRAM_BOT_TOKEN
while [[ ! "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]{35}$ ]]; do
    echo "⚠️ 格式错误！请输入正确的 Bot Token（格式：数字:字母数字组合）"
    read -rp "🤖 Telegram Bot Token: " TELEGRAM_BOT_TOKEN
done

read -rp "🆔 Telegram Chat ID (你的ID或群组ID): " TELEGRAM_CHAT_ID
while ! [[ "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]]; then
    echo "⚠️ 请输入有效的数字 ID（可为负数，如群组）"
    read -rp "🆔 Telegram Chat ID: " TELEGRAM_CHAT_ID
done

echo ""
echo "✅ 所有信息已收集，正在生成配置文件..."

# 写入 .env 文件（仅当前用户可读写）
cat > ".env" << EOF
NODESEEK_USERNAME=${NODESEEK_USERNAME}
NODESEEK_PASSWORD=${NODESEEK_PASSWORD}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
EOF

chmod 600 ".env"  # 设为私有，防止泄露
echo "🔒 配置已保存并设为私有权限 (.env)"

# === Python 脚本内容 ===
cat > "checkin.py" << 'EOF'
import requests
from datetime import datetime
import os
import sys
import time

# 加载环境变量
USERNAME = os.getenv("NODESEEK_USERNAME")
PASSWORD = os.getenv("NODESEEK_PASSWORD")
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID")

if not all([USERNAME, PASSWORD, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID]):
    print("❌ 环境变量缺失，请检查 .env 文件。")
    sys.exit(1)

LOGIN_URL = "https://www.nodeseek.com/api/user/login"
CHECKIN_URL = "https://www.nodeseek.com/api/checkin"

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Referer": "https://www.nodeseek.com/",
    "Origin": "https://www.nodeseek.com",
    "Content-Type": "application/json;charset=UTF-8"
}

def send_telegram_message(message):
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    try:
        response = requests.post(url, data={"chat_id": TELEGRAM_CHAT_ID, "text": message, "parse_mode": "Markdown"})
        if response.status_code != 200:
            print(f"[Telegram] 发送失败: {response.text}")
    except Exception as e:
        print(f"[Telegram] 请求异常: {e}")

def check_in():
    session = requests.Session()
    session.headers.update(HEADERS)

    try:
        # --- 登录 ---
        print("[+] 正在登录...")
        login_res = session.post(LOGIN_URL, json={"username": USERNAME, "password": PASSWORD}, timeout=10)
        if login_res.status_code != 200:
            msg = f"❌ HTTP {login_res.status_code} 登录请求失败"
            print(msg)
            send_telegram_message(msg)
            return

        login_json = login_res.json()
        if not login_json.get("success"):
            err_msg = login_json.get("message", "未知错误")
            msg = f"❌ 登录失败：{err_msg}"
            print(msg)
            send_telegram_message(msg)
            return

        print("[+] 登录成功")

        # --- 签到 ---
        print("[+] 正在签到...")
        checkin_res = session.post(CHECKIN_URL, timeout=10)
        if checkin_res.status_code != 200:
            msg = f"❌ HTTP {checkin_res.status_code} 签到失败"
            print(msg)
            send_telegram_message(msg)
            return

        checkin_json = checkin_res.json()
        now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        if checkin_json.get("success"):
            data = checkin_json["data"]
            msg = (
                f"✅ *NodeSeek 签到成功*\n"
                f"📅 时间：{now}\n"
                f"📊 连续签到：{data['checkinDays']} 天\n"
                f"🎁 获得积分：{data['addPoints']}"
            )
        elif "已经签到" in checkin_json.get("message", "") or "今日已签到" in checkin_json.get("message", ""):
            msg = f"ℹ️ 今日已签到 ✅\n📅 {now}"
        else:
            msg = f"❌ 签到失败：{checkin_json.get('message', '未知错误')}"

        print(msg)
        send_telegram_message(msg)

    except requests.exceptions.RequestException as e:
        error_msg = str(e)
        msg = f"🌐 网络错误：{error_msg}"
        print(msg)
        send_telegram_message(msg)
    except Exception as e:
        error_msg = str(e)
        msg = f"🚨 脚本异常：{error_msg}"
        print(msg)
        send_telegram_message(msg)

if __name__ == "__main__":
    check_in()
EOF

# === 安装 Python 依赖 ===
echo ""
echo "📦 正在安装 Python 依赖..."

if ! command -v python3 &> /dev/null; then
    echo "❌ 错误：未找到 python3，请先安装（例如：sudo apt install python3 python3-pip）"
    exit 1
fi

if ! command -v pip3 &> /dev/null; then
    echo "⚠️ pip3 未安装，正在尝试安装..."
    sudo apt update && sudo apt install -y python3-pip || true
fi

# 使用虚拟环境更安全
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip > /dev/null
pip install requests > /dev/null

echo "✅ Python 环境准备完成"

# === 创建测试运行脚本 ===
cat > "run_once.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")" || exit 1
source .env
source venv/bin/activate
python3 checkin.py
EOF
chmod +x run_once.sh

# === 添加定时任务（每天 08:00 自动签到）===
CRON_JOB="0 8 * * * cd $SCRIPT_DIR && source .env && source venv/bin/activate && python3 checkin.py >> checkin.log 2>&1"

# 先清除旧任务（避免重复）
(crontab -l 2>/dev/null | grep -v "node_seek_checkin") | crontab - || true
# 添加新任务
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo ""
echo "🎉 安装完成！"
echo "--------------------------------------------------"
echo "✅ 功能已启用："
echo "   • 自动登录 NodeSeek"
echo "   • 每天 08:00 自动签到"
echo "   • 结果通过 Telegram 发送通知"
echo "   • 已防重复签到"
echo ""
echo "📄 日志路径：$LOG_FILE"
echo ""
echo "🧪 现在你可以测试一次："
echo ""
echo "   $SCRIPT_DIR/run_once.sh"
echo ""
echo "📌 小贴士："
echo "   • 如需修改时间，请运行：crontab -e"
echo "   • 如需查看日志：tail -f $LOG_FILE"
echo "   • 配置文件已加密存储，安全可靠"
echo ""
echo "📬 注意：请确保你的 Telegram Bot 已向你发送过消息，否则无法接收通知！"
echo ""
echo "🌟 感谢使用！祝你天天签到顺利~"
