#!/bin/bash

# Bitwarden一键安装脚本 - 修复版
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log() { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# 检查root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用root权限运行此脚本"
    fi
}

# 修复系统
fix_system() {
    log "修复系统包管理器..."
    apt-get --fix-broken install -y 2>/dev/null || true
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
}

# 安装依赖
install_dependencies() {
    log "安装系统依赖..."
    apt-get update
    apt-get install -y curl wget jq openssl cron
}

# 安装Docker
install_docker() {
    if command -v docker &> /dev/null; then
        log "Docker已安装"
        return
    fi
    
    log "安装Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable docker
    systemctl start docker
    
    # 安装Docker Compose
    log "安装Docker Compose..."
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
    curl -L "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
}

# 获取用户配置
get_config() {
    echo ""
    echo "========================================"
    echo "    Bitwarden配置向导"
    echo "========================================"
    echo ""
    
    # 域名
    while true; do
        read -p "请输入域名 (例如: vault.example.com): " DOMAIN
        if [[ -n "$DOMAIN" ]]; then
            break
        else
            echo "域名不能为空"
        fi
    done
    
    read -p "请输入邮箱 (用于SSL证书): " EMAIL
    
    # 端口配置
    echo ""
    echo "=== 端口配置 ==="
    read -p "请输入Vaultwarden Web端口 [默认: 8080]: " VAULTWARDEN_PORT
    VAULTWARDEN_PORT=${VAULTWARDEN_PORT:-8080}
    
    read -p "请输入WebSocket端口 [默认: 3012]: " WEBSOCKET_PORT
    WEBSOCKET_PORT=${WEBSOCKET_PORT:-3012}
    
    read -p "请输入HTTP端口 [默认: 80]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-80}
    
    read -p "请输入HTTPS端口 [默认: 443]: " HTTPS_PORT
    HTTPS_PORT=${HTTPS_PORT:-443}
    
    # IP版本
    echo ""
    echo "选择反代IP版本:"
    echo "1) IPv4"
    echo "2) IPv6"
    read -p "请选择 (1-2): " IP_CHOICE
    case $IP_CHOICE in
        1) IP_VERSION="ipv4" ;;
        2) IP_VERSION="ipv6" ;;
        *) IP_VERSION="ipv4" ;;
    esac
    
    # 通知配置
    echo ""
    echo "=== 通知配置 ==="
    echo "1) 不启用通知"
    echo "2) Telegram通知"
    echo "3) 邮件通知"
    echo "4) 同时启用"
    read -p "请选择 (1-4): " NOTIF_CHOICE
    
    case $NOTIF_CHOICE in
        1) NOTIFICATION_TYPE="none" ;;
        2)
            NOTIFICATION_TYPE="telegram"
            read -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
            read -p "Telegram Chat ID: " TELEGRAM_CHAT_ID
            ;;
        3)
            NOTIFICATION_TYPE="email"
            read -p "接收通知的邮箱: " EMAIL_TO
            ;;
        4)
            NOTIFICATION_TYPE="both"
            read -p "Telegram Bot Token: " TELEGRAM_BOT_TOKEN
            read -p "Telegram Chat ID: " TELEGRAM_CHAT_ID
            read -p "接收通知的邮箱: " EMAIL_TO
            ;;
        *) NOTIFICATION_TYPE="none" ;;
    esac
    
    # Cloudflare R2配置
    echo ""
    echo "=== Cloudflare R2备份配置 ==="
    echo "第一个R2账户 (必填):"
    read -p "Account ID: " CF_ACCOUNT_ID_1
    read -p "Access Key ID: " CF_R2_ACCESS_KEY_1
    read -p "Secret Access Key: " CF_R2_SECRET_KEY_1
    read -p "Bucket名称: " CF_R2_BUCKET_1
    
    echo ""
    echo "第二个R2账户 (可选，留空跳过):"
    read -p "Account ID: " CF_ACCOUNT_ID_2
    if [[ -n "$CF_ACCOUNT_ID_2" ]]; then
        read -p "Access Key ID: " CF_R2_ACCESS_KEY_2
        read -p "Secret Access Key: " CF_R2_SECRET_KEY_2
        read -p "Bucket名称: " CF_R2_BUCKET_2
    fi
    
    # 生成密钥
    BACKUP_ENCRYPTION_KEY=$(openssl rand -base64 32)
    ADMIN_TOKEN=$(openssl rand -base64 48)
}

# 创建目录结构
create_directories() {
    log "创建目录结构..."
    mkdir -p /opt/bitwarden/{data,backups,config}
}

# 创建配置文件
create_configs() {
    log "创建配置文件..."
    
    # 主配置文件
    cat > /opt/bitwarden/config.env << CONFIG_EOF
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
VAULTWARDEN_PORT="$VAULTWARDEN_PORT"
WEBSOCKET_PORT="$WEBSOCKET_PORT"
HTTP_PORT="$HTTP_PORT"
HTTPS_PORT="$HTTPS_PORT"
IP_VERSION="$IP_VERSION"
NOTIFICATION_TYPE="$NOTIFICATION_TYPE"
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
EMAIL_TO="$EMAIL_TO"
CF_ACCOUNT_ID_1="$CF_ACCOUNT_ID_1"
CF_R2_ACCESS_KEY_1="$CF_R2_ACCESS_KEY_1"
CF_R2_SECRET_KEY_1="$CF_R2_SECRET_KEY_1"
CF_R2_BUCKET_1="$CF_R2_BUCKET_1"
CF_ACCOUNT_ID_2="$CF_ACCOUNT_ID_2"
CF_R2_ACCESS_KEY_2="$CF_R2_ACCESS_KEY_2"
CF_R2_SECRET_KEY_2="$CF_R2_SECRET_KEY_2"
CF_R2_BUCKET_2="$CF_R2_BUCKET_2"
BACKUP_ENCRYPTION_KEY="$BACKUP_ENCRYPTION_KEY"
ADMIN_TOKEN="$ADMIN_TOKEN"
CONFIG_EOF
    
    # docker-compose.yml - 使用Caddy自动SSL
    cat > /opt/bitwarden/docker-compose.yml << DOCKER_EOF
version: '3.8'

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    ports:
      - "127.0.0.1:$VAULTWARDEN_PORT:80"
      - "127.0.0.1:$WEBSOCKET_PORT:3012"
    volumes:
      - ./data:/data
    environment:
      - WEBSOCKET_ENABLED=true
      - SIGNUPS_ALLOWED=true
      - INVITATIONS_ALLOWED=true
      - DOMAIN=https://$DOMAIN
      - ADMIN_TOKEN=$ADMIN_TOKEN
      - LOG_FILE=/data/vaultwarden.log
      - LOG_LEVEL=warn
    env_file:
      - ./config/vaultwarden.env

  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "$HTTP_PORT:80"
      - "$HTTPS_PORT:443"
      - "$HTTPS_PORT:443/udp"
    volumes:
      - ./config/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy_data:/data
      - ./caddy_config:/config
    depends_on:
      - vaultwarden
DOCKER_EOF
    
    # Caddyfile - 使用自动SSL
    cat > /opt/bitwarden/config/Caddyfile << CADDY_EOF
{
    email $EMAIL
    admin off
}

# HTTP重定向到HTTPS
:$HTTP_PORT {
    bind 0.0.0.0
    redir https://$DOMAIN{uri}
}

# HTTPS站点
:$HTTPS_PORT {
    bind 0.0.0.0
    encode gzip
    
    # 根据IP版本配置
    reverse_proxy $IP_VERSION://vaultwarden:80 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
    
    # 安全头
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        -Server
    }
    
    # 日志
    log {
        output file /data/access.log {
            roll_size 10mb
            roll_keep 10
        }
    }
}
CADDY_EOF
    
    # Vaultwarden环境文件
    cat > /opt/bitwarden/config/vaultwarden.env << VAULTWARDEN_EOF
# 管理令牌已在config.env中设置
# SMTP配置示例:
# SMTP_HOST=smtp.gmail.com
# SMTP_FROM=your-email@gmail.com
# SMTP_PORT=587
# SMTP_SSL=true
# SMTP_USERNAME=your-email@gmail.com
# SMTP_PASSWORD=your-app-password
VAULTWARDEN_EOF
    
    chmod 600 /opt/bitwarden/config.env
}

# 创建备份脚本
create_backup_script() {
    log "创建备份脚本..."
    
    cat > /opt/bitwarden/backup.sh << 'BACKUP_EOF'
#!/bin/bash
set -e

# 加载配置
source /opt/bitwarden/config.env

# 变量
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_NAME="bitwarden_backup_$TIMESTAMP"
BACKUP_FILE="/opt/bitwarden/backups/$BACKUP_NAME.tar.gz"
ENCRYPTED_FILE="$BACKUP_FILE.enc"
LOG_FILE="/var/log/bitwarden_backup.log"

# 日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 发送通知
send_notification() {
    local message="$1"
    
    case "$NOTIFICATION_TYPE" in
        "telegram")
            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d parse_mode="Markdown" > /dev/null 2>&1
            ;;
        "email")
            echo "$message" | mail -s "Bitwarden备份通知" "$EMAIL_TO" 2>/dev/null || true
            ;;
        "both")
            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d parse_mode="Markdown" > /dev/null 2>&1
            echo "$message" | mail -s "Bitwarden备份通知" "$EMAIL_TO" 2>/dev/null || true
            ;;
    esac
}

# 加密
encrypt() {
    openssl enc -aes-256-cbc -salt -in "$1" -out "$2" \
        -pass pass:"$BACKUP_ENCRYPTION_KEY" 2>/dev/null
}

# 上传到R2
upload_r2() {
    local file="$1" account_id="$2" access_key="$3" secret_key="$4" bucket="$5"
    [[ -z "$account_id" ]] && return 1
    
    local endpoint="https://$account_id.r2.cloudflarestorage.com"
    local filename=$(basename "$file")
    
    curl -X PUT "$endpoint/$bucket/$filename" \
        -H "Authorization: Bearer $access_key" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"$file" \
        --silent --show-error 2>&1
    return $?
}

# 主备份
main() {
    log "开始备份..."
    
    cd /opt/bitwarden
    docker-compose stop vaultwarden
    sleep 3
    
    # 创建备份
    tar -czf "$BACKUP_FILE" data config docker-compose.yml config.env
    
    # 加密
    if encrypt "$BACKUP_FILE" "$ENCRYPTED_FILE"; then
        rm -f "$BACKUP_FILE"
        BACKUP_FILE="$ENCRYPTED_FILE"
        log "备份已加密"
    fi
    
    # 上传结果
    RESULTS=""
    
    # R2账户1
    if upload_r2 "$BACKUP_FILE" "$CF_ACCOUNT_ID_1" "$CF_R2_ACCESS_KEY_1" \
        "$CF_R2_SECRET_KEY_1" "$CF_R2_BUCKET_1"; then
        RESULTS+="✅ R2账户1: 成功\n"
        log "R2账户1上传成功"
    else
        RESULTS+="❌ R2账户1: 失败\n"
        log "R2账户1上传失败"
    fi
    
    # R2账户2
    if [[ -n "$CF_ACCOUNT_ID_2" ]]; then
        if upload_r2 "$BACKUP_FILE" "$CF_ACCOUNT_ID_2" "$CF_R2_ACCESS_KEY_2" \
            "$CF_R2_SECRET_KEY_2" "$CF_R2_BUCKET_2"; then
            RESULTS+="✅ R2账户2: 成功\n"
            log "R2账户2上传成功"
        else
            RESULTS+="❌ R2账户2: 失败\n"
            log "R2账户2上传失败"
        fi
    fi
    
    # 启动服务
    docker-compose start vaultwarden
    
    # 清理旧备份（保留7天）
    find /opt/bitwarden/backups -name "*.tar.gz*" -mtime +7 -delete
    
    # 发送通知
    local message="📦 Bitwarden备份完成\n"
    message+="时间: $TIMESTAMP\n"
    message+="文件: $(basename $BACKUP_FILE)\n"
    message+="大小: $(du -h "$BACKUP_FILE" | cut -f1)\n"
    message+="$RESULTS"
    
    send_notification "$message"
    log "备份完成"
}

main
BACKUP_EOF
    
    chmod +x /opt/bitwarden/backup.sh
}

# 创建管理脚本
create_management_script() {
    log "创建管理脚本..."
    
    cat > /opt/bitwarden/manage.sh << 'MANAGE_EOF'
#!/bin/bash

show_menu() {
    clear
    echo "========================================"
    echo "    Bitwarden管理面板"
    echo "========================================"
    echo ""
    echo "1) 启动服务"
    echo "2) 停止服务"
    echo "3) 重启服务"
    echo "4) 查看状态"
    echo "5) 查看日志"
    echo "6) 手动备份"
    echo "7) 测试通知"
    echo "8) 更新服务"
    echo "9) 卸载服务"
    echo "10) 退出"
    echo ""
}
test_notification() {
    source /opt/bitwarden/config.env 2>/dev/null || {
        echo "配置文件不存在"
        return
    }
    
    if [[ "$NOTIFICATION_TYPE" == "none" ]]; then
        echo "通知功能未启用"
        return
    fi
    
    local message="🔔 Bitwarden测试通知\n"
    message+="时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    message+="服务器: $(hostname)\n"
    message+="测试通知发送成功！"
    
    case "$NOTIFICATION_TYPE" in
        "telegram")
            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d parse_mode="Markdown"
            echo "Telegram通知已发送"
            ;;
        "email")
            echo "$message" | mail -s "Bitwarden测试通知" "$EMAIL_TO" 2>/dev/null || echo "邮件发送失败"
            echo "邮件通知已发送"
            ;;
        "both")
            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d parse_mode="Markdown"
            echo "$message" | mail -s "Bitwarden测试通知" "$EMAIL_TO" 2>/dev/null || echo "邮件发送失败"
            echo "通知已发送"
            ;;
    esac
}

uninstall_service() {
    echo "⚠️  警告：这将删除所有数据！"
    read -p "确认卸载？(输入yes继续): " confirm
    [[ "$confirm" != "yes" ]] && return
    
    cd /opt/bitwarden 2>/dev/null && docker-compose down 2>/dev/null || true
    docker system prune -af --volumes 2>/dev/null || true
    rm -rf /opt/bitwarden 2>/dev/null || true
    sed -i '/bitwarden_backup/d' /etc/crontab 2>/dev/null || true
    echo "Bitwarden已卸载"
    exit 0
}

while true; do
    show_menu
    read -p "请选择 (1-10): " choice
    
    case $choice in
        1) 
            cd /opt/bitwarden 2>/dev/null && docker-compose up -d 2>/dev/null && echo "服务已启动" || echo "启动失败"
            ;;
        2) 
            cd /opt/bitwarden 2>/dev/null && docker-compose down 2>/dev/null && echo "服务已停止" || echo "停止失败"
            ;;
        3) 
            cd /opt/bitwarden 2>/dev/null && docker-compose restart 2>/dev/null && echo "服务已重启" || echo "重启失败"
            ;;
        4) 
            cd /opt/bitwarden 2>/dev/null && docker-compose ps 2>/dev/null || echo "服务未运行"
            ;;
        5)
            echo "选择日志类型:"
            echo "1) Vaultwarden日志"
            echo "2) Caddy日志"
            echo "3) 所有日志"
            read -p "选择: " log_choice
            cd /opt/bitwarden 2>/dev/null || { echo "目录不存在"; break; }
            
            # 加载端口配置
            if [[ -f "/opt/bitwarden/config.env" ]]; then
                source /opt/bitwarden/config.env 2>/dev/null || true
            fi
            
            case $log_choice in
                1) 
                    echo "Vaultwarden运行在端口: ${VAULTWARDEN_PORT:-8080}"
                    docker-compose logs vaultwarden -f --tail=50 
                    ;;
                2) 
                    echo "Caddy运行在端口: HTTP:${HTTP_PORT:-80}, HTTPS:${HTTPS_PORT:-443}"
                    docker-compose logs caddy -f --tail=50 
                    ;;
                3) 
                    echo "端口信息:"
                    echo "- Vaultwarden: ${VAULTWARDEN_PORT:-8080}"
                    echo "- WebSocket: ${WEBSOCKET_PORT:-3012}"
                    echo "- HTTP: ${HTTP_PORT:-80}"
                    echo "- HTTPS: ${HTTPS_PORT:-443}"
                    docker-compose logs -f --tail=50 
                    ;;
                *) echo "无效选择" ;;
            esac
            ;;
        6)
            /opt/bitwarden/backup.sh 2>/dev/null && echo "备份完成" || echo "备份失败"
            ;;
        7)
            test_notification
            ;;
        8)
            cd /opt/bitwarden 2>/dev/null || { echo "目录不存在"; break; }
            docker-compose pull
            docker-compose down
            docker-compose up -d
            echo "服务已更新"
            ;;
        9)
            uninstall_service
            ;;
        10)
            echo "再见！"
            exit 0
            ;;
        *)
            echo "无效选择"
            ;;
    esac
    
    echo ""
    read -p "按Enter键继续..."
done
MANAGE_EOF
    
    chmod +x /opt/bitwarden/manage.sh
    
    # 创建全局命令
    ln -sf /opt/bitwarden/manage.sh /usr/local/bin/bw-manage 2>/dev/null || true
}

# 创建恢复脚本
create_restore_script() {
    log "创建恢复脚本..."
    
    cat > /opt/bitwarden/restore.sh << 'RESTORE_EOF'
#!/bin/bash

# Bitwarden恢复脚本
set -e

CONFIG_DIR="/opt/bitwarden"
BACKUP_DIR="$CONFIG_DIR/backups"

echo "=== Bitwarden恢复向导 ==="
echo ""

# 检查备份
if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A $BACKUP_DIR/*.tar.gz* 2>/dev/null)" ]]; then
    echo "没有找到备份文件"
    exit 1
fi

echo "可用的备份文件:"
ls -lh "$BACKUP_DIR"/*.tar.gz* 2>/dev/null | cat -n

echo ""
read -p "请输入备份文件编号: " file_num

# 获取文件名
backup_file=$(ls -1 "$BACKUP_DIR"/*.tar.gz* 2>/dev/null | sed -n "${file_num}p")

if [[ ! -f "$backup_file" ]]; then
    echo "文件不存在"
    exit 1
fi

echo "选择的备份: $backup_file"

# 加载配置
if [[ -f "$CONFIG_DIR/config.env" ]]; then
    source "$CONFIG_DIR/config.env"
fi

# 检查是否需要解密
if [[ "$backup_file" == *.enc ]]; then
    if [[ -z "$BACKUP_ENCRYPTION_KEY" ]]; then
        echo "需要加密密钥但未找到"
        exit 1
    fi
    
    echo "正在解密备份..."
    DECRYPTED_FILE="${backup_file%.enc}"
    openssl enc -aes-256-cbc -d -in "$backup_file" -out "$DECRYPTED_FILE" \
        -pass pass:"$BACKUP_ENCRYPTION_KEY" 2>/dev/null || {
        echo "解密失败"
        exit 1
    }
    backup_file="$DECRYPTED_FILE"
fi

# 停止服务
echo "停止服务..."
cd "$CONFIG_DIR" 2>/dev/null && docker-compose down 2>/dev/null || true

# 备份当前数据
echo "备份当前数据..."
if [[ -d "$CONFIG_DIR/data" ]]; then
    TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    mv "$CONFIG_DIR/data" "$CONFIG_DIR/data_backup_$TIMESTAMP" 2>/dev/null || true
fi

# 恢复备份
echo "恢复备份..."
tar -xzf "$backup_file" -C "$CONFIG_DIR" --strip-components=0

# 清理解密文件
if [[ -f "$DECRYPTED_FILE" ]]; then
    rm -f "$DECRYPTED_FILE"
fi

# 启动服务
echo "启动服务..."
cd "$CONFIG_DIR" && docker-compose up -d

echo ""
echo "恢复完成！"
echo "访问地址: https://$DOMAIN"
echo "管理令牌: $ADMIN_TOKEN"
echo "端口配置:"
echo "- Vaultwarden: ${VAULTWARDEN_PORT:-8080}"
echo "- WebSocket: ${WEBSOCKET_PORT:-3012}"
echo "- HTTP: ${HTTP_PORT:-80}"
echo "- HTTPS: ${HTTPS_PORT:-443}"
RESTORE_EOF
    
    chmod +x /opt/bitwarden/restore.sh
}

# 设置定时任务
setup_cron() {
    log "设置定时备份..."
    echo "0 2 * * * /opt/bitwarden/backup.sh" >> /etc/crontab
    systemctl restart cron 2>/dev/null || true
}

# 启动服务
start_services() {
    log "启动Bitwarden服务..."
    cd /opt/bitwarden
    docker-compose up -d
    
    # 等待服务启动
    sleep 5
    
    # 检查服务状态
    if docker-compose ps | grep -q "Up"; then
        success "服务启动成功"
    else
        warning "服务启动可能有问题，请检查日志"
    fi
}

# 显示安装完成信息
show_completion() {
    echo ""
    echo "========================================"
    echo "    Bitwarden安装完成！"
    echo "========================================"
    echo ""
    
    # 加载配置显示信息
    if [[ -f "/opt/bitwarden/config.env" ]]; then
        source /opt/bitwarden/config.env 2>/dev/null || true
    fi
    
    echo "📋 安装信息:"
    echo "• 域名: https://${DOMAIN:-未设置}"
    echo "• 管理令牌: ${ADMIN_TOKEN:0:20}..."
    echo "• 数据目录: /opt/bitwarden/data"
    echo "• 备份目录: /opt/bitwarden/backups"
    echo ""
    
    echo "🔧 端口配置:"
    echo "• Vaultwarden Web端口: ${VAULTWARDEN_PORT:-8080}"
    echo "• WebSocket端口: ${WEBSOCKET_PORT:-3012}"
    echo "• HTTP端口: ${HTTP_PORT:-80}"
    echo "• HTTPS端口: ${HTTPS_PORT:-443}"
    echo ""
    
    echo "🔧 管理命令:"
    echo "• bw-manage              - 管理面板"
    echo "• /opt/bitwarden/backup.sh  - 手动备份"
    echo "• /opt/bitwarden/restore.sh - 恢复备份"
    echo ""
    
    echo "📅 自动备份:"
    echo "• 每天凌晨2点自动执行"
    echo "• 备份到Cloudflare R2"
    echo "• 本地保留7天备份"
    echo ""
    
    echo "🔔 通知方式: ${NOTIFICATION_TYPE:-未设置}"
    echo ""
    
    echo "🌐 访问地址:"
    if [[ "${HTTPS_PORT:-443}" == "443" ]]; then
        echo "• https://${DOMAIN:-请配置域名}"
    else
        echo "• https://${DOMAIN:-请配置域名}:${HTTPS_PORT}"
    fi
    echo ""
    
    echo "⚠️  重要提示:"
    echo "1. 首次访问需要注册管理员账户"
    echo "2. 请妥善保存管理令牌"
    echo "3. 建议立即测试备份功能"
    echo "4. 如果使用非标准端口，请确保防火墙已开放相应端口"
    echo ""
    
    echo "运行 'bw-manage' 开始管理您的Bitwarden服务"
}

# 主安装流程
main_install() {
    clear
    echo "========================================"
    echo "    Bitwarden一键安装脚本"
    echo "========================================"
    echo ""
    
    # 检查root
    check_root
    
    # 修复系统
    fix_system
    
    # 安装依赖
    install_dependencies
    
    # 安装Docker
    install_docker
    
    # 获取配置
    get_config
    
    # 创建目录
    create_directories
    
    # 创建配置文件
    create_configs
    
    # 创建备份脚本
    create_backup_script
    
    # 创建恢复脚本
    create_restore_script
    
    # 创建管理脚本
    create_management_script
    
    # 设置定时任务
    setup_cron
    
    # 启动服务
    start_services
    
    # 显示完成信息
    show_completion
}

# 恢复模式
restore_mode() {
    echo "=== Bitwarden恢复模式 ==="
    echo ""
    
    if [[ -f "/opt/bitwarden/config.env" ]]; then
        echo "检测到现有配置，使用现有配置恢复"
        source /opt/bitwarden/config.env
    else
        echo "未找到现有配置，需要重新配置"
        get_config
        create_directories
        create_configs
    fi
    
    # 安装依赖
    install_dependencies
    install_docker
    
    # 创建脚本
    create_backup_script
    create_restore_script
    create_management_script
    setup_cron
    
    echo ""
    echo "恢复完成！"
    echo "运行以下命令:"
    echo "1. bw-manage 启动服务"
    echo "2. /opt/bitwarden/restore.sh 恢复备份"
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo "========================================"
        echo "    Bitwarden部署工具"
        echo "========================================"
        echo ""
        echo "请选择模式:"
        echo "1) 全新安装"
        echo "2) 恢复安装"
        echo "3) 退出"
        echo ""
        
        read -p "请选择 (1-3): " mode
        
        case $mode in
            1)
                main_install
                break
                ;;
            2)
                restore_mode
                break
                ;;
            3)
                echo "再见！"
                exit 0
                ;;
            *)
                echo "无效选择"
                sleep 2
                ;;
        esac
    done
}

# 直接运行安装
if [[ "$1" == "--install" ]]; then
    main_install
elif [[ "$1" == "--restore" ]]; then
    restore_mode
else
    main_menu
fi
