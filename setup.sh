# 创建完整的Bitwarden安装脚本
cat > bitwarden_full.sh << 'EOF'
#!/bin/bash

# Bitwarden完整安装脚本 - 包含反代、备份、通知所有功能
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置
CONFIG_DIR="/opt/bitwarden"
CONFIG_FILE="$CONFIG_DIR/config.env"
BACKUP_DIR="$CONFIG_DIR/backups"
LOG_FILE="/var/log/bitwarden_install.log"

# 日志函数
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用root权限运行此脚本"
    fi
}

# 清理系统配置
clean_system() {
    log "清理系统配置..."
    
    # 清理旧的Docker配置
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    rm -f /etc/apt/keyrings/docker.asc 2>/dev/null
    
    # 更新系统源
    cat > /etc/apt/sources.list << 'SOURCES_EOF'
deb http://deb.debian.org/debian stable main contrib non-free
deb http://deb.debian.org/debian stable-updates main contrib non-free
deb http://security.debian.org/debian-security stable-security main contrib non-free
SOURCES_EOF
    
    apt-get update
}

# 安装依赖
install_dependencies() {
    log "安装系统依赖..."
    
    apt-get install -y \
        curl \
        wget \
        git \
        jq \
        sqlite3 \
        openssl \
        cron \
        ufw \
        certbot \
        python3-certbot-dns-cloudflare \
        mailutils
    
    # 安装Docker
    if ! command -v docker &> /dev/null; then
        log "安装Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
    fi
    
    # 安装Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        log "安装Docker Compose..."
        DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
        curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    
    # 启动Docker
    systemctl enable docker
    systemctl start docker
    
    success "依赖安装完成"
}

# 配置防火墙
setup_firewall() {
    log "配置防火墙..."
    
    ufw --force enable
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw reload
    
    success "防火墙配置完成"
}

# 用户配置
get_user_config() {
    echo ""
    echo "=== Bitwarden配置 ==="
    
    # 域名配置
    read -p "请输入域名 (例如: vault.example.com): " DOMAIN
    read -p "请输入邮箱 (用于SSL证书): " EMAIL
    
    # IP版本选择
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
    read -p "请选择通知方式 (1-4): " NOTIF_CHOICE
    
    case $NOTIF_CHOICE in
        1)
            NOTIFICATION_TYPE="none"
            ;;
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
        *)
            NOTIFICATION_TYPE="none"
            ;;
    esac
    
    # Cloudflare R2配置
    echo ""
    echo "=== Cloudflare R2备份配置 ==="
    echo "第一个R2账户（必填）:"
    read -p "Account ID: " CF_ACCOUNT_ID_1
    read -p "Access Key ID: " CF_R2_ACCESS_KEY_1
    read -p "Secret Access Key: " CF_R2_SECRET_KEY_1
    read -p "Bucket名称: " CF_R2_BUCKET_1
    
    echo ""
    echo "第二个R2账户（可选，留空跳过）:"
    read -p "Account ID: " CF_ACCOUNT_ID_2
    if [[ -n "$CF_ACCOUNT_ID_2" ]]; then
        read -p "Access Key ID: " CF_R2_ACCESS_KEY_2
        read -p "Secret Access Key: " CF_R2_SECRET_KEY_2
        read -p "Bucket名称: " CF_R2_BUCKET_2
    fi
    
    # 生成加密密钥
    BACKUP_ENCRYPTION_KEY=$(openssl rand -base64 32)
}

# 保存配置
save_config() {
    log "保存配置..."
    
    mkdir -p "$CONFIG_DIR"
    
    cat > "$CONFIG_FILE" << CONFIG_EOF
# Bitwarden配置
DOMAIN="$DOMAIN"
EMAIL="$EMAIL"
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
CONFIG_EOF
    
    chmod 600 "$CONFIG_FILE"
    success "配置已保存"
}

# 安装Caddy反代
install_caddy() {
    log "安装Caddy反代..."
    
    # 创建Caddy配置目录
    mkdir -p /etc/caddy
    mkdir -p /var/lib/caddy
    
    # 创建Caddyfile
    cat > /etc/caddy/Caddyfile << CADDY_EOF
$DOMAIN {
    encode gzip
    
    # 根据IP版本配置
    reverse_proxy $IP_VERSION://localhost:8080 {
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
        output file /var/log/caddy/access.log {
            roll_size 10mb
            roll_keep 10
        }
    }
}
CADDY_EOF
    
    # 创建docker-compose.yml
    cat > "$CONFIG_DIR/docker-compose.yml" << DOCKER_EOF
version: '3.8'

services:
  # Vaultwarden服务
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:80"
      - "127.0.0.1:3012:3012"
    volumes:
      - ./data:/data
    environment:
      - WEBSOCKET_ENABLED=true
      - SIGNUPS_ALLOWED=true
      - INVITATIONS_ALLOWED=true
      - DOMAIN=https://$DOMAIN
      - LOG_FILE=/data/vaultwarden.log
      - LOG_LEVEL=warn
      - EXTENDED_LOGGING=true
      - ADMIN_TOKEN=\${ADMIN_TOKEN:-}
    env_file:
      - ./vaultwarden.env
  
  # Caddy反代
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy_data:/data
      - ./caddy_config:/config
      - ./ssl:/ssl
    depends_on:
      - vaultwarden
DOCKER_EOF
    
    # 获取SSL证书
    log "获取SSL证书..."
    docker run --rm \
        -v "$CONFIG_DIR/ssl:/ssl" \
        -v "$CONFIG_DIR/caddy_config:/config" \
        -v "$CONFIG_DIR/caddy_data:/data" \
        caddy:latest caddy cert \
        --email "$EMAIL" \
        --domains "$DOMAIN" \
        --agree
    
    success "Caddy反代配置完成"
}

# 创建备份脚本
create_backup_script() {
    log "创建备份脚本..."
    
    mkdir -p "$BACKUP_DIR"
    
    cat > "$CONFIG_DIR/backup.sh" << 'BACKUP_EOF'
#!/bin/bash

set -e

# 加载配置
source /opt/bitwarden/config.env

# 变量
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_NAME="bitwarden_backup_$TIMESTAMP"
BACKUP_FILE="$BACKUP_DIR/$BACKUP_NAME.tar.gz"
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
            send_telegram "$message"
            ;;
        "email")
            send_email "$message"
            ;;
        "both")
            send_telegram "$message"
            send_email "$message"
            ;;
    esac
}

send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" > /dev/null
}

send_email() {
    local message="$1"
    echo "$message" | mail -s "Bitwarden备份通知" "$EMAIL_TO"
}

# 加密备份
encrypt_backup() {
    openssl enc -aes-256-cbc -salt -in "$1" -out "$2" \
        -pass pass:"$BACKUP_ENCRYPTION_KEY"
}

# 上传到R2
upload_to_r2() {
    local file="$1"
    local account_id="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    local endpoint="https://$account_id.r2.cloudflarestorage.com"
    
    curl -X PUT "$endpoint/$bucket/$(basename $file)" \
        -H "Authorization: Bearer $access_key" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"$file" \
        --silent --show-error
}

# 主备份函数
backup() {
    log "开始备份..."
    
    # 停止服务
    cd "$CONFIG_DIR"
    docker-compose stop vaultwarden
    
    # 创建备份
    tar -czf "$BACKUP_FILE" \
        -C "$CONFIG_DIR" \
        data \
        vaultwarden.env \
        config.env
    
    # 加密
    encrypt_backup "$BACKUP_FILE" "$ENCRYPTED_FILE"
    rm -f "$BACKUP_FILE"
    
    # 上传到R2账户1
    UPLOAD1_RESULT=0
    if [[ -n "$CF_ACCOUNT_ID_1" ]]; then
        upload_to_r2 "$ENCRYPTED_FILE" "$CF_ACCOUNT_ID_1" "$CF_R2_ACCESS_KEY_1" \
            "$CF_R2_SECRET_KEY_1" "$CF_R2_BUCKET_1"
        UPLOAD1_RESULT=$?
    fi
    
    # 上传到R2账户2
    UPLOAD2_RESULT=0
    if [[ -n "$CF_ACCOUNT_ID_2" ]]; then
        upload_to_r2 "$ENCRYPTED_FILE" "$CF_ACCOUNT_ID_2" "$CF_R2_ACCESS_KEY_2" \
            "$CF_R2_SECRET_KEY_2" "$CF_R2_BUCKET_2"
        UPLOAD2_RESULT=$?
    fi
    
    # 启动服务
    docker-compose start vaultwarden
    
    # 清理旧备份
    find "$BACKUP_DIR" -name "*.enc" -mtime +7 -delete
    
    # 发送通知
    local message="✅ Bitwarden备份完成\n"
    message+="时间: $TIMESTAMP\n"
    message+="文件: $BACKUP_NAME.tar.gz.enc\n"
    message+="大小: $(du -h "$ENCRYPTED_FILE" | cut -f1)\n"
    
    if [[ $UPLOAD1_RESULT -eq 0 ]]; then
        message+="R2账户1: 成功\n"
    else
        message+="R2账户1: 失败\n"
    fi
    
    if [[ $UPLOAD2_RESULT -eq 0 ]]; then
        message+="R2账户2: 成功\n"
    elif [[ -n "$CF_ACCOUNT_ID_2" ]]; then
        message+="R2账户2: 失败\n"
    fi
    
    send_notification "$message"
    log "备份完成"
}

# 执行备份
backup
BACKUP_EOF
    
    chmod +x "$CONFIG_DIR/backup.sh"
    
    # 添加定时任务
    echo "0 2 * * * $CONFIG_DIR/backup.sh" >> /etc/crontab
    
    success "备份脚本创建完成（每天凌晨2点自动备份）"
}

# 创建恢复脚本
create_restore_script() {
    cat > "$CONFIG_DIR/restore.sh" << 'RESTORE_EOF'
#!/bin/bash

set -e

source /opt/bitwarden/config.env

echo "=== Bitwarden恢复脚本 ==="
echo ""
echo "请选择恢复方式:"
echo "1) 从本地备份恢复"
echo "2) 从Cloudflare R2恢复"
read -p "选择 (1-2): " choice

case $choice in
    1)
        echo "可用的本地备份:"
        ls -lh "$BACKUP_DIR"/*.enc 2>/dev/null || {
            echo "没有找到本地备份"
            exit 1
        }
        
        read -p "输入备份文件名: " backup_file
        if [[ ! -f "$backup_file" ]]; then
            echo "文件不存在"
            exit 1
        fi
        
        # 解密
        DECRYPTED_FILE="${backup_file%.enc}"
        openssl enc -aes-256-cbc -d -in "$backup_file" -out "$DECRYPTED_FILE" \
            -pass pass:"$BACKUP_ENCRYPTION_KEY"
        # 停止服务
        cd "$CONFIG_DIR"
        docker-compose down
        
        # 恢复
        tar -xzf "$DECRYPTED_FILE" -C "$CONFIG_DIR"
        rm -f "$DECRYPTED_FILE"
        
        # 启动服务
        docker-compose up -d
        
        echo "恢复完成"
        ;;
    2)
        echo "从R2恢复功能需要手动配置"
        echo "请下载备份文件到 $BACKUP_DIR 后使用选项1恢复"
        ;;
    *)
        echo "无效选择"
        exit 1
        ;;
esac

# 发送通知
if [[ "$NOTIFICATION_TYPE" != "none" ]]; then
    local message="✅ Bitwarden恢复完成\n"
    message+="时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
    message+="恢复方式: $([ $choice -eq 1 ] && echo "本地备份" || echo "R2备份")"
    
    case "$NOTIFICATION_TYPE" in
        "telegram")
            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d parse_mode="Markdown" > /dev/null
            ;;
        "email")
            echo "$message" | mail -s "Bitwarden恢复通知" "$EMAIL_TO"
            ;;
        "both")
            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d parse_mode="Markdown" > /dev/null
            echo "$message" | mail -s "Bitwarden恢复通知" "$EMAIL_TO"
            ;;
    esac
fi
RESTORE_EOF
    
    chmod +x "$CONFIG_DIR/restore.sh"
    success "恢复脚本创建完成"
}

# 创建管理脚本
create_management_script() {
    cat > "$CONFIG_DIR/manage.sh" << 'MANAGE_EOF'
#!/bin/bash

# Bitwarden管理脚本

CONFIG_DIR="/opt/bitwarden"

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
    echo "7) 恢复备份"
    echo "8) 测试通知"
    echo "9) 更新服务"
    echo "10) 卸载服务"
    echo "11) 退出"
    echo ""
}

test_notification() {
    source "$CONFIG_DIR/config.env"
    
    if [[ "$NOTIFICATION_TYPE" == "none" ]]; then
        echo "通知功能未启用"
        return
    fi
    
    local message="🔔 Bitwarden通知测试\n"
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
            echo "$message" | mail -s "Bitwarden测试通知" "$EMAIL_TO"
            echo "邮件通知已发送"
            ;;
        "both")
            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d parse_mode="Markdown"
            echo "$message" | mail -s "Bitwarden测试通知" "$EMAIL_TO"
            echo "Telegram和邮件通知已发送"
            ;;
    esac
}

update_service() {
    echo "更新Bitwarden服务..."
    cd "$CONFIG_DIR"
    docker-compose pull
    docker-compose down
    docker-compose up -d
    echo "更新完成"
}

uninstall_service() {
    echo "⚠️  警告：这将删除所有Bitwarden数据！"
    read -p "确认卸载？(输入yes继续): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo "取消卸载"
        return
    fi
    
    cd "$CONFIG_DIR"
    docker-compose down
    docker system prune -af --volumes
    
    # 删除目录
    rm -rf "$CONFIG_DIR"
    
    # 删除定时任务
    sed -i '/bitwarden_backup/d' /etc/crontab
    
    echo "Bitwarden已完全卸载"
}

while true; do
    show_menu
    read -p "请选择操作 (1-11): " choice
    
    case $choice in
        1)
            cd "$CONFIG_DIR" && docker-compose up -d
            echo "服务已启动"
            ;;
        2)
            cd "$CONFIG_DIR" && docker-compose down
            echo "服务已停止"
            ;;
        3)
            cd "$CONFIG_DIR" && docker-compose restart
            echo "服务已重启"
            ;;
        4)
            cd "$CONFIG_DIR" && docker-compose ps
            ;;
        5)
            cd "$CONFIG_DIR" && docker-compose logs -f --tail=50
            ;;
        6)
            "$CONFIG_DIR/backup.sh"
            ;;
        7)
            "$CONFIG_DIR/restore.sh"
            ;;
        8)
            test_notification
            ;;
        9)
            update_service
            ;;
        10)
            uninstall_service
            exit 0
            ;;
        11)
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
    
    chmod +x "$CONFIG_DIR/manage.sh"
    
    # 创建全局命令
    ln -sf "$CONFIG_DIR/manage.sh" /usr/local/bin/bw-manage
    
    success "管理脚本创建完成"
    echo "使用 'bw-manage' 命令管理Bitwarden服务"
}

# 创建初始化脚本
create_init_script() {
    cat > "$CONFIG_DIR/init.sh" << 'INIT_EOF'
#!/bin/bash

# Bitwarden初始化脚本

CONFIG_DIR="/opt/bitwarden"

# 检查是否已初始化
if [[ -f "$CONFIG_DIR/docker-compose.yml" ]]; then
    echo "Bitwarden似乎已经初始化过了"
    read -p "是否重新初始化？(y/N): " reinit
    if [[ "$reinit" != "y" && "$reinit" != "Y" ]]; then
        exit 0
    fi
fi

# 创建必要目录
mkdir -p "$CONFIG_DIR/data"
mkdir -p "$CONFIG_DIR/backups"
mkdir -p "$CONFIG_DIR/ssl"
mkdir -p "$CONFIG_DIR/caddy_data"
mkdir -p "$CONFIG_DIR/caddy_config"

# 创建vaultwarden环境文件
if [[ ! -f "$CONFIG_DIR/vaultwarden.env" ]]; then
    cat > "$CONFIG_DIR/vaultwarden.env" << 'VAULTWARDEN_ENV'
# Vaultwarden环境配置
# 生成管理令牌: openssl rand -base64 48
# ADMIN_TOKEN=your_admin_token_here

# 其他可选配置
# SMTP_HOST=smtp.example.com
# SMTP_FROM=bitwarden@example.com
# SMTP_PORT=587
# SMTP_SSL=true
# SMTP_USERNAME=username
# SMTP_PASSWORD=password
VAULTWARDEN_ENV
    
    echo "请编辑 $CONFIG_DIR/vaultwarden.env 配置管理令牌和SMTP"
fi

# 启动服务
cd "$CONFIG_DIR"
docker-compose up -d

echo ""
echo "=== 初始化完成 ==="
echo ""
echo "重要信息:"
echo "1. 管理面板: bw-manage"
echo "2. 数据目录: $CONFIG_DIR/data"
echo "3. 备份目录: $CONFIG_DIR/backups"
echo "4. 配置文件: $CONFIG_DIR/config.env"
echo ""
echo "访问地址: https://您的域名"
echo ""
echo "首次访问需要注册管理员账户"
INIT_EOF
    
    chmod +x "$CONFIG_DIR/init.sh"
}

# 安装完成提示
show_completion() {
    echo ""
    echo "========================================"
    echo "    Bitwarden安装完成！"
    echo "========================================"
    echo ""
    echo "📁 目录结构:"
    echo "  /opt/bitwarden/          - 主目录"
    echo "  ├── data/                - 数据文件"
    echo "  ├── backups/             - 备份文件"
    echo "  ├── docker-compose.yml   - Docker配置"
    echo "  ├── config.env           - 主配置"
    echo "  ├── vaultwarden.env      - Vaultwarden配置"
    echo "  ├── manage.sh            - 管理脚本"
    echo "  ├── backup.sh            - 备份脚本"
    echo "  └── restore.sh           - 恢复脚本"
    echo ""
    echo "🔧 管理命令:"
    echo "  bw-manage                - 打开管理面板"
    echo "  /opt/bitwarden/backup.sh - 手动备份"
    echo "  /opt/bitwarden/restore.sh - 恢复备份"
    echo ""
    echo "🌐 访问地址:"
    echo "  https://$DOMAIN"
    echo ""
    echo "📅 自动备份:"
    echo "  每天凌晨2点自动备份到Cloudflare R2"
    echo "  保留最近7天的本地备份"
    echo ""
    echo "🔔 通知方式: $NOTIFICATION_TYPE"
    echo ""
    echo "接下来步骤:"
    echo "1. 运行: cd /opt/bitwarden && ./init.sh"
    echo "2. 编辑 vaultwarden.env 设置管理令牌"
    echo "3. 访问 https://$DOMAIN 注册账户"
    echo ""
}

# 主安装流程
main_install() {
    clear
    echo "========================================"
    echo "    Bitwarden完整安装向导"
    echo "========================================"
    echo ""
    
    # 检查root
    check_root
    
    # 清理系统
    clean_system
    
    # 安装依赖
    install_dependencies
    
    # 配置防火墙
    setup_firewall
    
    # 获取用户配置
    get_user_config
    
    # 保存配置
    save_config
    
    # 安装Caddy反代
    install_caddy
    
    # 创建备份脚本
    create_backup_script
    
    # 创建恢复脚本
    create_restore_script
    
    # 创建管理脚本
    create_management_script
    
    # 创建初始化脚本
    create_init_script
    
    # 显示完成信息
    show_completion
    
    # 询问是否立即初始化
    echo ""
    read -p "是否立即初始化Bitwarden？(Y/n): " init_now
    
    if [[ "$init_now" != "n" && "$init_now" != "N" ]]; then
        cd "$CONFIG_DIR"
        ./init.sh
    fi
}

# 恢复模式
restore_mode() {
    echo "=== Bitwarden恢复模式 ==="
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "未找到配置文件，请先运行安装模式"
    fi
    
    source "$CONFIG_FILE"
    
    echo "检测到现有配置:"
    echo "域名: $DOMAIN"
    echo "邮箱: $EMAIL"
    echo ""
    
    read -p "是否使用现有配置恢复？(Y/n): " use_existing
    
    if [[ "$use_existing" == "n" || "$use_existing" == "N" ]]; then
        get_user_config
        save_config
    fi
    
    # 安装依赖
    install_dependencies
    
    # 安装Caddy反代
    install_caddy
    
    # 创建脚本
    create_backup_script
    create_restore_script
    create_management_script
    create_init_script
    
    echo ""
    echo "恢复完成！"
    echo "运行以下命令启动服务:"
    echo "cd /opt/bitwarden && ./init.sh"
    echo "或使用: bw-manage"
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

# 启动
main_menu
EOF

# 添加执行权限
chmod +x bitwarden_full.sh

# 运行完整脚本
echo "运行完整版Bitwarden安装脚本..."
echo "这将包含所有您需要的功能："
echo "1. Caddy反代（支持IPv4/IPv6）"
echo "2. 自动备份到两个Cloudflare R2账户"
echo "3. Telegram/邮件通知"
echo "4. 一键恢复功能"
echo "5. 管理面板"
echo ""
echo "开始安装..."
./bitwarden_full.sh
