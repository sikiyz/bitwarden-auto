#!/bin/bash

# ============================================
# NodeSeek 自动签到一键安装脚本
# 功能：自动签到 + Telegram 通知 + 每日定时执行
# 作者：AI助手
# 版本：v1.0
# ============================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查依赖
check_dependencies() {
    print_info "检查系统依赖..."
    
    # 检查 Python3
    if ! command -v python3 &> /dev/null; then
        print_warning "Python3 未安装，正在安装..."
        if command -v apt &> /dev/null; then
            apt update && apt install -y python3 python3-pip
        elif command -v yum &> /dev/null; then
            yum install -y python3 python3-pip
        elif command -v dnf &> /dev/null; then
            dnf install -y python3 python3-pip
        else
            print_error "无法自动安装 Python3，请手动安装后重试"
            exit 1
        fi
    fi
    
    # 检查 pip3
    if ! command -v pip3 &> /dev/null; then
        print_warning "pip3 未安装，正在安装..."
        if command -v apt &> /dev/null; then
            apt install -y python3-pip
        elif command -v yum &> /dev/null; then
            yum install -y python3-pip
        fi
    fi
    
    print_success "系统依赖检查完成"
}

# 交互式配置
get_config() {
    echo ""
    print_info "开始配置 NodeSeek 自动签到"
    echo "========================================"
    
    # 登录方式选择
    echo ""
    echo "请选择登录方式："
    echo "1) 账号密码登录（输入邮箱和密码）"
    echo "2) Cookie 登录（推荐，更稳定）"
    read -p "请选择 [1/2] (默认 2): " login_choice
    login_choice=${login_choice:-2}
    
    if [ "$login_choice" = "1" ]; then
        USE_COOKIE=0
        read -p "请输入 NodeSeek 登录邮箱: " NODESEEK_USERNAME
        while [ -z "$NODESEEK_USERNAME" ]; do
            read -p "邮箱不能为空，请重新输入: " NODESEEK_USERNAME
        done
        
        read -sp "请输入 NodeSeek 登录密码: " NODESEEK_PASSWORD
        echo ""
        while [ -z "$NODESEEK_PASSWORD" ]; do
            read -sp "密码不能为空，请重新输入: " NODESEEK_PASSWORD
            echo ""
        done
    else
        USE_COOKIE=1
        echo ""
        echo "请在浏览器中登录 NodeSeek 后，按 F12 打开开发者工具"
        echo "在 Network 标签中找到任意请求，复制 Request Headers 中的 Cookie"
        echo ""
        read -p "请粘贴完整的 Cookie: " NODESEEK_COOKIE
        while [ -z "$NODESEEK_COOKIE" ]; do
            read -p "Cookie 不能为空，请重新输入: " NODESEEK_COOKIE
        done
    fi
    
    # Telegram 配置
    echo ""
    echo "Telegram 通知配置："
    echo "1. 在 Telegram 中搜索 @BotFather"
    echo "2. 创建新的 bot，获取 Bot Token"
    echo "3. 在 Telegram 中搜索 @getmyid_bot，获取你的 Chat ID"
    echo ""
    read -p "请输入 Telegram Bot Token: " TELEGRAM_BOT_TOKEN
    while [ -z "$TELEGRAM_BOT_TOKEN" ]; do
        read -p "Bot Token 不能为空，请重新输入: " TELEGRAM_BOT_TOKEN
    done
    
    read -p "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID
    while [ -z "$TELEGRAM_CHAT_ID" ]; do
        read -p "Chat ID 不能为空，请重新输入: " TELEGRAM_CHAT_ID
    done
    
    # 签到时间
    echo ""
    read -p "设置每日签到时间 (24小时制，格式 HH:MM，默认 08:00): " CHECKIN_TIME
    CHECKIN_TIME=${CHECKIN_TIME:-08:00}
    
    # 验证时间格式
    if [[ ! "$CHECKIN_TIME" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
        print_warning "时间格式无效，使用默认 08:00"
        CHECKIN_TIME="08:00"
    fi
    
    # 解析小时和分钟
    CRON_HOUR=$(echo $CHECKIN_TIME | cut -d: -f1)
    CRON_MIN=$(echo $CHECKIN_TIME | cut -d: -f2)
    
    print_success "配置信息收集完成"
}

# 创建项目目录
setup_project() {
    PROJECT_DIR="$HOME/nodeseek_checkin"
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    
    print_info "项目目录: $PROJECT_DIR"
}

# 创建配置文件
create_config_file() {
    cat > "$PROJECT_DIR/config.env" << EOF
# NodeSeek 自动签到配置
USE_COOKIE=$USE_COOKIE
NODESEEK_USERNAME='$NODESEEK_USERNAME'
NODESEEK_PASSWORD='$NODESEEK_PASSWORD'
NODESEEK_COOKIE='$NODESEEK_COOKIE'
TELEGRAM_BOT_TOKEN='$TELEGRAM_BOT_TOKEN'
TELEGRAM_CHAT_ID='$TELEGRAM_CHAT_ID'
EOF
    
    chmod 600 "$PROJECT_DIR/config.env"
    print_success "配置文件已创建: $PROJECT_DIR/config.env"
}

# 创建签到脚本
create_checkin_script() {
    cat > "$PROJECT_DIR/checkin.py" << 'PYEOF'
#!/usr/bin/env python3
"""
NodeSeek 自动签到脚本
支持账号密码和 Cookie 两种登录方式
"""

import os
import sys
import json
import time
import requests
from datetime import datetime
from urllib.parse import urlparse

# 加载配置
def load_config():
    config = {}
    config_file = os.path.join(os.path.dirname(__file__), 'config.env')
    
    if not os.path.exists(config_file):
        print("❌ 配置文件不存在")
        sys.exit(1)
    
    with open(config_file, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                if '=' in line:
                    key, value = line.split('=', 1)
                    config[key.strip()] = value.strip().strip("'\"")
    
    return config

# 发送 Telegram 通知
def send_telegram_message(bot_token, chat_id, message):
    """发送消息到 Telegram"""
    try:
        url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
        data = {
            "chat_id": chat_id,
            "text": message,
            "parse_mode": "Markdown"
        }
        response = requests.post(url, data=data, timeout=10)
        if response.status_code == 200:
            return True
        else:
            print(f"Telegram 发送失败: {response.text}")
            return False
    except Exception as e:
        print(f"Telegram 发送异常: {e}")
        return False

# 解析 Cookie 字符串为字典
def parse_cookie(cookie_str):
    """将 Cookie 字符串解析为字典"""
    cookies = {}
    for item in cookie_str.split(';'):
        item = item.strip()
        if '=' in item:
            key, value = item.split('=', 1)
            cookies[key.strip()] = value.strip()
    return cookies

# 主签到函数
def main():
    print("🚀 开始 NodeSeek 自动签到...")
    
    # 加载配置
    config = load_config()
    
    use_cookie = config.get('USE_COOKIE') == '1'
    username = config.get('NODESEEK_USERNAME', '')
    password = config.get('NODESEEK_PASSWORD', '')
    cookie_str = config.get('NODESEEK_COOKIE', '')
    bot_token = config.get('TELEGRAM_BOT_TOKEN', '')
    chat_id = config.get('TELEGRAM_CHAT_ID', '')
    
    # 检查必要配置
    if use_cookie and not cookie_str:
        msg = "❌ Cookie 配置为空"
        print(msg)
        if bot_token and chat_id:
            send_telegram_message(bot_token, chat_id, msg)
        sys.exit(1)
    
    if not use_cookie and (not username or not password):
        msg = "❌ 账号或密码为空"
        print(msg)
        if bot_token and chat_id:
            send_telegram_message(bot_token, chat_id, msg)
        sys.exit(1)
    
    # 创建会话
    session = requests.Session()
    session.headers.update({
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Origin': 'https://www.nodeseek.com',
        'Referer': 'https://www.nodeseek.com/',
    })
    
    try:
        # 登录或设置 Cookie
        if use_cookie:
            # 使用 Cookie 登录
            cookies = parse_cookie(cookie_str)
            for key, value in cookies.items():
                session.cookies.set(key, value)
            print("✅ 已设置 Cookie")
        else:
            # 使用账号密码登录
            login_url = "https://www.nodeseek.com/api/user/login"
            login_data = {
                "username": username,
                "password": password
            }
            
            print("🔐 正在登录...")
            response = session.post(login_url, json=login_data, timeout=10)
            
            if response.status_code != 200:
                msg = f"❌ 登录失败: HTTP {response.status_code}"
                print(msg)
                if bot_token and chat_id:
                    send_telegram_message(bot_token, chat_id, msg)
                sys.exit(1)
            
            result = response.json()
            if not result.get('success'):
                msg = f"❌ 登录失败: {result.get('message', '未知错误')}"
                print(msg)
                if bot_token and chat_id:
                    send_telegram_message(bot_token, chat_id, msg)
                sys.exit(1)
            
            print("✅ 登录成功")
        
        # 执行签到
        checkin_url = "https://www.nodeseek.com/api/checkin"
        print("📝 正在签到...")
        
        response = session.post(checkin_url, timeout=10)
        
        if response.status_code != 200:
            msg = f"❌ 签到请求失败: HTTP {response.status_code}"
            print(msg)
            if bot_token and chat_id:
                send_telegram_message(bot_token, chat_id, msg)
            sys.exit(1)
        
        result = response.json()
        current_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        if result.get('success'):
            data = result.get('data', {})
            checkin_days = data.get('checkinDays', '未知')
            add_points = data.get('addPoints', '未知')
            
            msg = f"""✅ *NodeSeek 签到成功*
📅 时间: {current_time}
📊 连续签到: {checkin_days} 天
🎁 获得积分: {add_points}"""
            
            print(f"✅ 签到成功: 连续 {checkin_days} 天，获得 {add_points} 积分")
        else:
            error_msg = result.get('message', '未知错误')
            if '已经签到' in error_msg or '今日已签到' in error_msg:
                msg = f"""ℹ️ *今日已签到*
📅 时间: {current_time}
💡 无需重复签到"""
                print("ℹ️ 今日已签到")
            else:
                msg = f"""❌ *签到失败*
📅 时间: {current_time}
⚠️ 错误: {error_msg}"""
                print(f"❌ 签到失败: {error_msg}")
        
        # 发送 Telegram 通知
        if bot_token and chat_id:
            send_telegram_message(bot_token, chat_id, msg)
        
        print("🎉 签到流程完成")
        
    except requests.exceptions.RequestException as e:
        msg = f"""❌ *网络请求异常*
📅 时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
⚠️ 错误: {str(e)}"""
        print(f"❌ 网络异常: {e}")
        if bot_token and chat_id:
            send_telegram_message(bot_token, chat_id, msg)
        sys.exit(1)
    except Exception as e:
        msg = f"""❌ *程序执行异常*
📅 时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
⚠️ 错误: {str(e)}"""
        print(f"❌ 程序异常: {e}")
        if bot_token and chat_id:
            send_telegram_message(bot_token, chat_id, msg)
        sys.exit(1)

if __name__ == "__main__":
    main()
PYEOF
    
    chmod +x "$PROJECT_DIR/checkin.py"
    print_success "签到脚本已创建: $PROJECT_DIR/checkin.py"
}

# 安装 Python 依赖
install_dependencies() {
    print_info "安装 Python 依赖..."
    
    # 创建虚拟环境（可选）
    if [ ! -d "$PROJECT_DIR/venv" ]; then
        python3 -m venv "$PROJECT_DIR/venv" 2>/dev/null || true
    fi
    
    # 安装 requests
    pip3 install requests --quiet
    
    print_success "Python 依赖安装完成"
}

# 设置定时任务
setup_cron_job() {
    print_info "设置定时任务..."
    
    # 创建执行脚本
    cat > "$PROJECT_DIR/run_checkin.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
source config.env 2>/dev/null || true
python3 checkin.py >> checkin.log 2>&1
EOF
    
    chmod +x "$PROJECT_DIR/run_checkin.sh"
    
    # 添加定时任务
    CRON_JOB="$CRON_MIN $CRON_HOUR * * * cd $PROJECT_DIR && bash run_checkin.sh"
    
    # 检查是否已有相同任务
    (crontab -l 2>/dev/null | grep -v "run_checkin.sh") | crontab -
    
    # 添加新任务
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    
    print_success "定时任务已设置: 每天 $CHECKIN_TIME 自动签到"
}

# 测试运行
test_run() {
    echo ""
    print_info "测试运行签到脚本..."
    
    cd "$PROJECT_DIR"
    python3 checkin.py
    
    echo ""
    read -p "是否收到 Telegram 通知？[y/N] " test_result
    if [[ "$test_result" =~ ^[Yy]$ ]]; then
        print_success "测试成功！"
    else
        print_warning "请检查配置信息是否正确"
    fi
}

# 显示使用说明
show_instructions() {
    echo ""
    echo "========================================"
    print_success "NodeSeek 自动签到安装完成！"
    echo "========================================"
    echo ""
    echo "📁 项目目录: $PROJECT_DIR"
    echo "📄 配置文件: $PROJECT_DIR/config.env"
    echo "🐍 签到脚本: $PROJECT_DIR/checkin.py"
    echo "📅 定时任务: 每天 $CHECKIN_TIME 自动执行"
    echo "📊 运行日志: $PROJECT_DIR/checkin.log"
    echo ""
    echo "🔧 管理命令:"
    echo "   手动签到: cd $PROJECT_DIR && python3 checkin.py"
    echo "   查看日志: tail -f $PROJECT_DIR/checkin.log"
    echo "   修改时间: crontab -e"
    echo "   卸载: 删除目录 $PROJECT_DIR 并运行 crontab -e 删除对应行"
    echo ""
    echo "📱 Telegram 通知已启用"
    echo "   请确保 Bot 已添加到对话中"
    echo ""
    echo "🌟 祝你使用愉快！"
}

# 主函数
main() {
    clear
    echo "========================================"
    echo "    NodeSeek 自动签到一键安装脚本"
    echo "========================================"
    echo ""
    
    # 检查依赖
    check_dependencies
    
    # 获取配置
    get_config
    
    # 设置项目
    setup_project
    
    # 创建配置文件
    create_config_file
    
    # 创建签到脚本
    create_checkin_script
    
    # 安装依赖
    install_dependencies
