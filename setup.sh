#!/bin/bash

# Bitwarden自托管一键部署与恢复脚本
# 支持IPv4/IPv6反代、自动备份到Cloudflare R2、通知功能

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置文件路径
CONFIG_FILE="/opt/bitwarden/config.sh"
BACKUP_DIR="/opt/bitwarden/backups"
DATA_DIR="/opt/bitwarden/data"
LOG_FILE="/var/log/bitwarden_setup.log"

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

# 检查系统
check_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    else
        error "无法检测操作系统"
    fi
    
    log "检测到系统: $OS $VER"
    
    # 检查架构
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
        error "不支持的架构: $ARCH"
    fi
}

# 安装依赖
install_dependencies() {
    log "安装系统依赖..."
    
    if [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Debian"* ]]; then
        apt-get update
        apt-get install -y curl wget git docker.io docker-compose jq sqlite3 openssl cron certbot python3-certbot-dns-cloudflare
        systemctl enable docker
        systemctl start docker
    elif [[ "$OS" == *"CentOS"* ]] || [[ "$OS" == *"Rocky"* ]] || [[ "$OS" == *"AlmaLinux"* ]]; then
        yum install -y curl wget git docker docker-compose jq sqlite3 openssl cronie certbot python3-certbot-dns-cloudflare
        systemctl enable docker
        systemctl start docker
    else
        error "不支持的操作系统: $OS"
    fi
    
    # 安装acme.sh用于SSL证书
    curl https://get.acme.sh | sh
    
    success "依赖安装完成"
}

# 加载配置
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        # 默认配置
        DOMAIN=""
        EMAIL=""
        IP_VERSION="ipv4"
        NOTIFICATION_TYPE="none"
        TELEGRAM_BOT_TOKEN=""
        TELEGRAM_CHAT_ID=""
        EMAIL_TO=""
        CF_ACCOUNT_ID_1=""
        CF_R2_ACCESS_KEY_1=""
        CF_R2_SECRET_KEY_1=""
        CF_R2_BUCKET_1=""
        CF_ACCOUNT_ID_2=""
        CF_R2_ACCESS_KEY_2=""
        CF_R2_SECRET_KEY_2=""
        CF_R2_BUCKET_2=""
        BACKUP_ENCRYPTION_KEY=""
        ENABLE_AUTO_BACKUP="true"
    fi
}

# 保存配置
save_config() {
    cat > "$CONFIG_FILE" << EOF
#!/bin/bash
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
ENABLE_AUTO_BACKUP="$ENABLE_AUTO_BACKUP"
EOF
    
    chmod 600 "$CONFIG_FILE"
    success "配置已保存"
}

# 发送通知
send_notification() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local full_message="[Bitwarden Backup] $timestamp - $message"
    
    case "$NOTIFICATION_TYPE" in
        "telegram")
            send_telegram "$full_message"
            ;;
        "email")
            send_email "$full_message"
            ;;
        "both")
            send_telegram "$full_message"
            send_email "$full_message"
            ;;
        *)
            log "通知已禁用或未配置"
            ;;
    esac
}

# 发送Telegram通知
send_telegram() {
    local message="$1"
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="$message" \
            -d parse_mode="Markdown" > /dev/null 2>&1
    fi
}

# 发送邮件通知
send_email() {
    local message="$1"
    if [[ -n "$EMAIL_TO" ]]; then
        echo "$message" | mail -s "Bitwarden Backup Notification" "$EMAIL_TO" 2>/dev/null || \
        log "邮件发送失败，请检查邮件配置"
    fi
}

# 测试通知
test_notification() {
    log "测试通知功能..."
    
    if [[ "$NOTIFICATION_TYPE" == "none" ]]; then
        warning "通知功能未启用"
        return
    fi
    
    send_notification "测试通知: Bitwarden备份系统正常工作"
    success "测试通知已发送"
}

# 配置通知
setup_notification() {
    echo ""
    echo "=== 配置通知方式 ==="
    echo "1) 不启用通知"
    echo "2) Telegram通知"
    echo "3) 邮件通知"
    echo "4) 同时启用Telegram和邮件"
    read -p "请选择通知方式 (1-4): " notif_choice
    
    case $notif_choice in
        1)
            NOTIFICATION_TYPE="none"
            ;;
        2)
            NOTIFICATION_TYPE="telegram"
            read -p "请输入Telegram Bot Token: " TELEGRAM_BOT_TOKEN
            read -p "请输入Telegram Chat ID: " TELEGRAM_CHAT_ID
            ;;
        3)
            NOTIFICATION_TYPE="email"
            read -p "请输入接收通知的邮箱: " EMAIL_TO
            ;;
        4)
            NOTIFICATION_TYPE="both"
            read -p "请输入Telegram Bot Token: " TELEGRAM_BOT_TOKEN
            read -p "请输入Telegram Chat ID: " TELEGRAM_CHAT_ID
            read -p "请输入接收通知的邮箱: " EMAIL_TO
            ;;
        *)
            NOTIFICATION_TYPE="none"
            ;;
    esac
}

# 配置Cloudflare R2
setup_r2() {
    echo ""
    echo "=== 配置Cloudflare R2备份 ==="
    
    # 第一个R2账户
    echo "配置第一个Cloudflare R2账户:"
    read -p "Cloudflare Account ID: " CF_ACCOUNT_ID_1
    read -p "R2 Access Key ID: " CF_R2_ACCESS_KEY_1
    read -p "R2 Secret Access Key: " CF_R2_SECRET_KEY_1
    read -p "R2 Bucket名称: " CF_R2_BUCKET_1
    
    # 第二个R2账户
    echo ""
    echo "配置第二个Cloudflare R2账户 (可选):"
    read -p "Cloudflare Account ID (留空跳过): " CF_ACCOUNT_ID_2
    if [[ -n "$CF_ACCOUNT_ID_2" ]]; then
        read -p "R2 Access Key ID: " CF_R2_ACCESS_KEY_2
        read -p "R2 Secret Access Key: " CF_R2_SECRET_KEY_2
        read -p "R2 Bucket名称: " CF_R2_BUCKET_2
    fi
    
    # 生成备份加密密钥
    if [[ -z "$BACKUP_ENCRYPTION_KEY" ]]; then
        BACKUP_ENCRYPTION_KEY=$(openssl rand -base64 32)
        log "已生成备份加密密钥"
    fi
}

# 安装Bitwarden
install_bitwarden() {
    log "开始安装Bitwarden..."
    
    # 创建目录
    mkdir -p "$DATA_DIR" "$BACKUP_DIR"
    
    # 下载Bitwarden安装脚本
    cd /opt/bitwarden
    if [[ ! -f "bitwarden.sh" ]]; then
        curl -Lso bitwarden.sh https://go.btwrdn.co/bw-sh
        chmod +x bitwarden.sh
    fi
    
    # 运行安装脚本
    ./bitwarden.sh install
    
    # 配置域名和SSL
    if [[ -n "$DOMAIN" ]]; then
        ./bitwarden.sh config-domain "$DOMAIN"
    fi
    
    # 启动Bitwarden
    ./bitwarden.sh start
    
    success "Bitwarden安装完成"
}

# 配置Caddy反代
setup_caddy() {
    log "配置Caddy反代..."
    
    # 创建Caddyfile
    cat > /opt/bitwarden/Caddyfile << EOF
$DOMAIN {
    encode gzip
    log {
        output file /opt/bitwarden/logs/access.log {
            roll_size 10mb
            roll_keep 10
        }
    }
    
    # 根据选择的IP版本配置
    reverse_proxy $IP_VERSION://localhost:8080
    
    # 安全头
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        -Server
    }
}
EOF
    
    # 获取SSL证书
    log "获取SSL证书..."
    if [[ "$IP_VERSION" == "ipv6" ]]; then
        certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" \
            --agree-tos --email "$EMAIL" --force-renewal --expand \
            --pre-hook "systemctl stop caddy" \
            --post-hook "systemctl start caddy" \
            --allow-subset-of-names
    else
        certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" \
            --agree-tos --email "$EMAIL" --force-renewal --expand
    fi
    
    # 配置证书自动续期
    echo "0 0 * * * certbot renew --quiet --post-hook 'systemctl reload caddy'" >> /etc/crontab
    
    success "Caddy反代配置完成"
}

# 创建备份脚本
create_backup_script() {
    cat > /opt/bitwarden/backup.sh << 'EOF'
#!/bin/bash

set -e

# 加载配置
source /opt/bitwarden/config.sh

# 变量
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_NAME="bitwarden_backup_$TIMESTAMP"
BACKUP_FILE="$BACKUP_DIR/$BACKUP_NAME.tar.gz"
ENCRYPTED_FILE="$BACKUP_FILE.enc"
LOG_FILE="/var/log/bitwarden_backup.log"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 加密备份
encrypt_backup() {
    local input_file="$1"
    local output_file="$2"
    
    openssl enc -aes-256-cbc -salt -in "$input_file" -out "$output_file" \
        -pass pass:"$BACKUP_ENCRYPTION_KEY" 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        log "备份文件已加密: $output_file"
        rm -f "$input_file"
    else
        log "加密失败"
        return 1
    fi
}

# 上传到R2
upload_to_r2() {
    local file="$1"
    local account_id="$2"
    local access_key="$3"
    local secret_key="$4"
    local bucket="$5"
    local endpoint="https://$account_id.r2.cloudflarestorage.com"
    
    # 使用curl上传
    curl -X PUT "$endpoint/$bucket/$BACKUP_NAME.tar.gz.enc" \
        -H "Authorization: Bearer $access_key" \
        -H "X-Amz-Date: $(date -u +'%Y%m%dT%H%M%SZ')" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"$file" \
        --silent --show-error
    
    if [[ $? -eq 0 ]]; then
        log "成功上传到R2: $bucket"
        return 0
    else
        log "上传到R2失败: $bucket"
        return 1
    fi
}

# 主备份函数
backup() {
    log "开始Bitwarden备份..."
    
    # 停止Bitwarden服务
    cd /opt/bitwarden
    ./bitwarden.sh stop
    
    # 创建备份
    tar -czf "$BACKUP_FILE" \
        -C /opt/bitwarden \
        --exclude="*.log" \
        --exclude="*.tmp" \
        .
    
    # 加密备份
    encrypt_backup "$BACKUP_FILE" "$ENCRYPTED_FILE"
    
    # 上传到第一个R2
    if [[ -n "$CF_ACCOUNT_ID_1" ]]; then
        upload_to_r2 "$ENCRYPTED_FILE" "$CF_ACCOUNT_ID_1" "$CF_R2_ACCESS_KEY_1" \
            "$CF_R2_SECRET_KEY_1" "$CF_R2_BUCKET_1"
        UPLOAD_1_RESULT=$?
    fi
    
    # 上传到第二个R2
    if [[ -n "$CF_ACCOUNT_ID_2" ]]; then
        upload_to_r2 "$ENCRYPTED_FILE" "$CF_ACCOUNT_ID_2" "$CF_R2_ACCESS_KEY_2" \
            "$CF_R2_SECRET_KEY_2" "$CF_R2_BUCKET_2"
        UPLOAD_2_RESULT=$?
    fi
    
    # 清理旧备份（保留最近7天）
    find "$BACKUP_DIR" -name "bitwarden_backup_*.tar.gz.enc" -mtime +7 -delete
    
    # 启动Bitwarden服务
    ./bitwarden.sh start
    
    # 发送通知
    local message="备份完成\n"
    message+="时间: $TIMESTAMP\n"
    message+="备份文件: $BACKUP_NAME.tar.gz.enc\n"
    message+="文件大小: $(du -h "$ENCRYPTED_FILE" | cut -f1)\n"
    
    if [[ -n "$CF_ACCOUNT_ID_1" ]]; then
        if [[ $UPLOAD_1_RESULT -eq 0 ]]; then
            message+="✅ R2账户1: $CF_R2_BUCKET_1\n"
        else
            message+="❌ R2账户1: 上传失败\n"
        fi
    fi
    
    if [[ -n "$CF_ACCOUNT_ID_2" ]]; then
        if [[ $UPLOAD_2_RESULT -eq 0 ]]; then
            message+="✅ R2账户2: $CF_R2_BUCKET_2\n"
        else
            message+="❌ R2账户2: 上传失败\n"
        fi
    fi
    
    send_notification "$message"
    log "备份流程完成"
}

# 执行备份
backup
EOF
    
    chmod +x /opt/bitwarden/backup.sh
    
    # 添加定时任务
    if [[ "$ENABLE_AUTO_BACKUP" == "true" ]]; then
        echo "0 2 * * * /opt/bitwarden/backup.sh" >> /etc/crontab
        log "已添加自动备份定时任务 (每天凌晨2点)"
    fi
}

# 恢复备份
restore_backup() {
    log "开始恢复Bitwarden..."
    
    echo "请选择恢复方式:"
    echo "1) 从本地备份恢复"
    echo "2) 从Cloudflare R2恢复"
    read -p "请选择 (1-2): " restore_choice
    
    case $restore_choice in
        1)
            restore_from_local
            ;;
        2)
            restore_from_r2
            ;;
        *)
            error "无效的选择"
            ;;
    esac
}

# 从本地恢复
restore_from_local() {
    echo "可用的本地备份:"
    ls -lh "$BACKUP_DIR"
    local backups=($(ls -t "$BACKUP_DIR"/*.tar.gz.enc 2>/dev/null))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        error "没有找到本地备份文件"
    fi
    
    echo "请选择要恢复的备份:"
    for i in "${!backups[@]}"; do
        echo "$((i+1))) ${backups[$i]}"
    done
    
    read -p "请输入编号: " backup_num
    selected_backup="${backups[$((backup_num-1))]}"
    
    if [[ ! -f "$selected_backup" ]]; then
        error "选择的备份文件不存在"
    fi
    
    # 解密备份
    log "解密备份文件..."
    DECRYPTED_FILE="${selected_backup%.enc}"
    openssl enc -aes-256-cbc -d -in "$selected_backup" -out "$DECRYPTED_FILE" \
        -pass pass:"$BACKUP_ENCRYPTION_KEY" 2>/dev/null || error "解密失败，请检查加密密钥"
    
    # 停止服务
    cd /opt/bitwarden
    ./bitwarden.sh stop
    
    # 恢复文件
    log "恢复文件..."
    tar -xzf "$DECRYPTED_FILE" -C /opt/bitwarden --strip-components=1
    
    # 清理解密文件
    rm -f "$DECRYPTED_FILE"
    
    # 启动服务
    ./bitwarden.sh start
    
    success "恢复完成"
}

# 从R2恢复
restore_from_r2() {
    echo "请选择R2账户:"
    echo "1) 第一个R2账户"
    echo "2) 第二个R2账户"
    read -p "请选择 (1-2): " r2_choice
    
    case $r2_choice in
        1)
            account_id="$CF_ACCOUNT_ID_1"
            access_key="$CF_R2_ACCESS_KEY_1"
            secret_key="$CF_R2_SECRET_KEY_1"
            bucket="$CF_R2_BUCKET_1"
            ;;
        2)
            account_id="$CF_ACCOUNT_ID_2"
            access_key="$CF_R2_ACCESS_KEY_2"
            secret_key="$CF_R2_SECRET_KEY_2"
            bucket="$CF_R2_BUCKET_2"
            ;;
        *)
            error "无效的选择"
            ;;
    esac
    
    if [[ -z "$account_id" ]]; then
        error "选择的R2账户未配置"
    fi
    
    # 列出R2中的备份文件
    log "获取R2备份列表..."
    endpoint="https://$account_id.r2.cloudflarestorage.com"
    
    # 获取备份列表
    backup_list=$(curl -s -X GET "$endpoint/$bucket" \
        -H "Authorization: Bearer $access_key" \
        -H "X-Amz-Date: $(date -u +'%Y%m%dT%H%M%SZ')" | grep -o 'bitwarden_backup_[^<]*' | sort -r)
    
    if [[ -z "$backup_list" ]]; then
        error "R2中没有找到备份文件"
    fi
    
    echo "可用的R2备份:"
    select backup_name in $backup_list; do
        if [[ -n "$backup_name" ]]; then
            break
        fi
    done
    
    # 下载备份
    log "下载备份文件: $backup_name"
    ENCRYPTED_FILE="$BACKUP_DIR/$backup_name"
    
    curl -s -X GET "$endpoint/$bucket/$backup_name" \
        -H "Authorization: Bearer $access_key" \
        -H "X-Amz-Date: $(date -u +'%Y%m%dT%H%M%SZ')" \
        -o "$ENCRYPTED_FILE" || error "下载失败"
    
    # 解密并恢复
    DECRYPTED_FILE="${ENCRYPTED_FILE%.enc}"
    openssl enc -aes-256-cbc -d -in "$ENCRYPTED_FILE" -out "$DECRYPTED_FILE" \
        -pass pass:"$BACKUP_ENCRYPTION_KEY" 2>/dev/null || error "解密失败"
    
    # 停止服务
    cd /opt/bitwarden
    ./bitwarden.sh stop
    
    # 恢复文件
    tar -xzf "$DECRYPTED_FILE" -C /opt/bitwarden --strip-components=1
    
    # 清理文件
    rm -f "$ENCRYPTED_FILE" "$DECRYPTED_FILE"
    
    # 启动服务
    ./bitwarden.sh start
    
    success "从R2恢复完成"
}

# 检查Bitwarden状态
check_bitwarden_status() {
    if [[ -f "/opt/bitwarden/bitwarden.sh" ]]; then
        cd /opt/bitwarden
        if ./bitwarden.sh status | grep -q "running"; then
            return 0
        else
            return 1
        fi
    else
        return 2
    fi
}

# 删除Bitwarden
remove_bitwarden() {
    warning "警告：这将删除所有Bitwarden数据！"
    read -p "确认删除？(输入yes继续): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log "取消删除操作"
        return
    fi
    
    log "开始删除Bitwarden..."
    
    # 停止服务
    if [[ -f "/opt/bitwarden/bitwarden.sh" ]]; then
        cd /opt/bitwarden
        ./bitwarden.sh stop
        ./bitwarden.sh uninstall
    fi
    
    # 删除目录
    rm -rf /opt/bitwarden
    rm -f "$CONFIG_FILE"
    
    # 删除定时任务
    sed -i '/bitwarden_backup/d' /etc/crontab
    sed -i '/certbot renew/d' /etc/crontab
    
    success "Bitwarden已完全删除"
}

# 主菜单
main_menu() {
    clear
    echo "========================================"
    echo "    Bitwarden自托管管理脚本"
    echo "========================================"
    echo ""
    
    # 检查Bitwarden状态
    check_bitwarden_status
    bitwarden_status=$?
    
    case $bitwarden_status in
        0)
            echo "📊 Bitwarden状态: ${GREEN}运行中${NC}"
            ;;
        1)
            echo "📊 Bitwarden状态: ${YELLOW}已安装但未运行${NC}"
            ;;
        2)
            echo "📊 Bitwarden状态: ${RED}未安装${NC}"
            ;;
    esac
    
    echo ""
    echo "请选择操作:"
    echo "1) 初次安装Bitwarden"
    echo "2) 恢复Bitwarden"
    echo "3) 手动执行备份"
    echo "4) 测试通知功能"
    echo "5) 删除Bitwarden"
    echo "6) 查看日志"
    echo "7) 退出"
    echo ""
    
    read -p "请输入选项 (1-7): " choice
    
    case $choice in
        1)
            initial_setup
            ;;
        2)
            restore_setup
            ;;
        3)
            manual_backup
            ;;
        4)
            test_notification
            ;;
        5)
            remove_bitwarden
            ;;
        6)
            view_logs
            ;;
        7)
            exit 0
            ;;
        *)
            error "无效选项"
            ;;
    esac
}

# 初始安装
initial_setup() {
    log "开始初始安装流程..."
    
    # 检查依赖
    if ! command -v docker &> /dev/null; then
        install_dependencies
    fi
    
    # 获取用户输入
    echo ""
    echo "=== Bitwarden安装配置 ==="
    read -p "请输入域名 (例如: vault.example.com): " DOMAIN
    read -p "请输入邮箱 (用于SSL证书): " EMAIL
    
    echo ""
    echo "请选择反代IP版本:"
    echo "1) IPv4"
    echo "2) IPv6"
    read -p "请选择 (1-2): " ip_choice
    
    case $ip_choice in
        1)
            IP_VERSION="ipv4"
            ;;
        2)
            IP_VERSION="ipv6"
            ;;
        *)
            IP_VERSION="ipv4"
            ;;
    esac
    
    # 配置通知
    setup_notification
    
    # 配置R2备份
    setup_r2
    
    # 保存配置
    save_config
    
    # 安装Bitwarden
    install_bitwarden
    
    # 配置Caddy反代
    if [[ -n "$DOMAIN" ]]; then
        setup_caddy
    fi
    
    # 创建备份脚本
    create_backup_script
    
    # 发送安装完成通知
    send_notification "Bitwarden安装完成\n域名: $DOMAIN\nIP版本: $IP_VERSION\n备份已配置: ${ENABLE_AUTO_BACKUP}"
    
    success "Bitwarden初始安装完成！"
    echo ""
    echo "访问地址: https://$DOMAIN"
    echo "管理目录: /opt/bitwarden"
    echo "备份目录: $BACKUP_DIR"
    echo ""
    read -p "按Enter键返回主菜单..." -n 1
}

# 恢复安装
restore_setup() {
    log "开始恢复安装流程..."
    
    # 检查是否有配置文件
    if [[ ! -f "$CONFIG_FILE" ]]; then
        warning "未找到配置文件，将进行全新安装"
        initial_setup
        return
    fi
    
    # 加载配置
    load_config
    
    # 检查依赖
    if ! command -v docker &> /dev/null; then
        install_dependencies
    fi
    
    # 恢复备份
    restore_backup
    
    # 重新配置Caddy
    if [[ -n "$DOMAIN" ]]; then
        setup_caddy
    fi
    
    # 重新创建备份脚本
    create_backup_script
    
    success "Bitwarden恢复完成！"
    read -p "按Enter键返回主菜单..." -n 1
}

# 手动备份
manual_backup() {
    log "执行手动备份..."
    
    if [[ ! -f "/opt/bitwarden/backup.sh" ]]; then
        error "备份脚本不存在，请先完成初始安装"
    fi
    
    /opt/bitwarden/backup.sh
    
    success "手动备份完成"
    read -p "按Enter键返回主菜单..." -n 1
}

# 查看日志
view_logs() {
    echo ""
    echo "=== 系统日志 ==="
    echo "1) 安装日志"
    echo "2) 备份日志"
    echo "3) Caddy访问日志"
    echo "4) 返回"
    echo ""
    
    read -p "请选择: " log_choice
    
    case $log_choice in
        1)
            less "$LOG_FILE"
            ;;
        2)
            less "/var/log/bitwarden_backup.log"
            ;;
        3)
            less "/opt/bitwarden/logs/access.log"
            ;;
        4)
            return
            ;;
        *)
            error "无效选项"
            ;;
    esac
}

# 初始化
init() {
    check_root
    check_system
    load_config
    
    # 创建必要目录
    mkdir -p /opt/bitwarden/logs
    mkdir -p "$BACKUP_DIR"
    
    # 设置定时任务检查
    if [[ ! -f /etc/cron.d/bitwarden_cleanup ]]; then
        echo "0 3 * * * root find /opt/bitwarden/logs -name '*.log' -mtime +30 -delete" > /etc/cron.d/bitwarden_cleanup
    fi
}

# 主程序
main() {
    init
    
    while true; do
        main_menu
    done
}

# 执行主程序
main "$@"
