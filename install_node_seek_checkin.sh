#!/bin/bash

# NodeSeek 自动签到一键安装脚本
# 支持：自动签到、Telegram 通知、每日定时执行

set -e

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 检查依赖
check_dependencies() {
    echo -e "${YELLOW}[*] 检查系统依赖...${NC}"
    
    # 检查 Python
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}[!] 未找到 Python3，正在安装...${NC}"
        if [ -x "$(command -v apt)" ]; then
            sudo apt update
            sudo apt install -y python3 python3-pip
        elif [ -x "$(command -v yum)" ]; then
            sudo yum install -y python3 python3-pip
        else
            echo -e "${RED}[!] 无法自动安装 Python3，请手动安装。${NC}"
            exit 1
        fi
    fi

    # 安装 Python 依赖
    pip3 install requests &> /dev/null
}

# 交互式输入配置
input_config() {
    echo -e "${GREEN}[+] NodeSeek 自动签到配置${NC}"
    
    # 登录方式选择
    echo -e "${YELLOW}请选择登录方式：${NC}"
    echo "1) 账号密码登录"
    echo "2) Cookie 登录（推荐）"
    read -p "请选择 (默认 2): " LOGIN_TYPE
    LOGIN_TYPE=${LOGIN_TYPE:-2}

    # 根据登录方式获取凭证
    if [ "$LOGIN_TYPE" = "1" ]; then
        read -p "请输入 NodeSeek 登录邮箱: " NODESEEK_USERNAME
        read -sp "请输入 NodeSeek 登录密码: " NODESEEK_PASSWORD
        echo
    else
        read -p "请粘贴完整 Cookie (多个 Cookie 用分号分隔): " NODESEEK_COOKIE
    fi

    # Telegram 配置
    read -p "请输入 Telegram Bot Token: " TELEGRAM_BOT_TOKEN
    read -p "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID

    # 签到时间
    read -p "设置每日签到时间 (24小时制, 默认 08:00): " CHECKIN_TIME
    CHECKIN_TIME=${CHECKIN_TIME:-08:00}
}

# 创建签到脚本
create_checkin_script() {
    mkdir -p ~/nodeseek_checkin
    
    cat > ~/nodeseek_checkin/checkin.py << EOF
import os
import sys
import requests
from datetime import datetime

# 配置信息
LOGIN_TYPE = os.getenv('LOGIN_TYPE', '2')
USERNAME = os.getenv('NODESEEK_USERNAME', '')
PASSWORD = os.getenv('NODESEEK_PASSWORD', '')
COOKIE = os.getenv('NODESEEK_COOKIE', '')
TELEGRAM_BOT_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
TELEGRAM_CHAT_ID = os.getenv('TELEGRAM_CHAT_ID')

def send_telegram_message(message):
    try:
        url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
        params = {
            "chat_id": TELEGRAM_CHAT_ID,
            "text": message
        }
        requests.post(url, json=params)
    except Exception
