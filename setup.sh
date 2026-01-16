#!/bin/bash

#================================================#
#     🔐 Bitwarden 一键部署（双 CF 账号 + GPG 加密） #
#   全平台兼容 | 自动 HTTPS | 智能清理 | 通知      #
#================================================#

set -eo pipefail

# ========== 日志与颜色 ==========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
log() { echo -e "[${GREEN}INFO${NC}] $(date '+%F %T') $1"; }
warn() { echo -e "[${YELLOW}WARN${NC}] $(date '+%F %T') $1"; }
error() { echo -e "[${RED}ERROR${NC}] $(date '+%F %T') $1"; }
debug() { echo -e "[${BLUE}DEBUG${NC}] $(date '+%F %T') $1"; }

# ========== 日志记录 ==========
LOG_FILE="/var/log/bitwarden-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ========== 常量 ==========
readonly DATA_DIR="/opt/bitwarden"
readonly BACKUP_DIR="$DATA_DIR/backups"
readonly S3CMD_CONF_A="/root/.s3cfg.r2-primary"
readonly S3CMD_CONF_B="/root/.s3cfg.r2-secondary"
readonly VALID_DOMAIN='^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
readonly VALID_EMAIL='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'

# ========== 变量初始化 ==========
MODE="" DOMAIN="" EMAIL=""
NOTIFY_METHOD="none"
TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID=""
SMTP_USER="" SMTP_PASS="" SMTP_SERVER="" SMTP_PORT=587
ENCRYPTION_PASSWORD=""
VW_VERSION="1.30.2"

# ---------- 第一个 CF 账号 ----------
CF1_ACCOUNT_ID=""
CF1_ACCESS_KEY=""
CF1_SECRET_KEY=""
CF1_BUCKET=""

# ---------- 第二个 CF 账号 ----------
CF2_ACCOUNT_ID=""
CF2_ACCESS_KEY=""
CF2_SECRET_KEY=""
CF2_BUCKET=""

# ========== 检测系统 ==========
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_NAME="$NAME"
    elif grep -q "CentOS" /etc/redhat-release; then
        OS_ID="centos"
        OS_NAME=$(cat /etc/redhat-release)
    elif grep -q "Rocky" /etc/redhat-release; then
        OS_ID="rocky"
        OS_NAME=$(cat /etc/redhat-release)
    elif grep -q "AlmaLinux" /etc/redhat-release; then
        OS_ID="almalinux"
        OS_NAME=$(cat /etc/redhat-release)
    else
        error "不支持的操作系统"
        exit 1
    fi
    log "检测到系统: $OS_NAME (ID: $OS_ID)"
}

# ========== 包管理器抽象 ==========
pkg_install() {
    case "$OS_ID" in
        ubuntu|debian) DEBIAN_FRONTEND=noninteractive apt install -y "$@" > /dev/null ;;
        centos|rocky|almalinux) yum install -y "$@" > /dev/null ;;
        fedora) dnf install -y "$@" > /dev/null ;;
        opensuse*|suse) zypper install -y --no-confirm "$@" > /dev/null ;;
        *) error "不支持的系统" && exit 1 ;;
    esac
}

install_dependencies() {
    log "🔧 安装必要依赖..."

    command -v curl || pkg_install curl
    command -v wget || pkg_install wget
    command -v jq || pkg_install jq
    command -v gpg || pkg_install gnupg

    # Nginx + Certbot
    if ! command -v nginx &> /dev/null; then
        pkg_install nginx certbot python3-certbot-nginx 2>/dev/null || true
    fi

    # s3cmd
    if ! command -v s3cmd &> /dev/null; then
        pkg_install s3cmd
    fi

    # 邮件支持
    if [[ "$NOTIFY_METHOD" == "email" ]] && ! command -v s-nail &> /dev/null; then
        pkg_install s-nail mailx
    fi

    # Docker
    if ! command -v docker &> /dev/null; then
        log "🐳 安装 Docker..."
        curl -fsSL https://get.docker.com | sh > /dev/null
        systemctl enable docker --now
    fi

    # Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        local url="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
        curl -L "$url" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi

    systemctl enable nginx --now 2>/dev/null || true
    log "✅ 依赖安装完成"
}

# ========== 输入函数 ==========
ask() {
    local prompt="$1"
    read -p "🔹 $prompt: " input
    eval "$2=\"\$input\""
}

confirm() {
    read -p "❓ $1 (y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]]
}

validate_domain() { [[ "$1" =~ $VALID_DOMAIN ]] && [ ${#1} -le 253 ]; }
validate_email() { [[ "$1" =~ $VALID_EMAIL ]]; }

choose_mode() {
    echo
    echo "========================================"
    echo "   🔐 Bitwarden 一键部署（加密容灾版）"
    echo "========================================"
    echo
    echo "当前系统: $OS_NAME"
    echo
    echo "请选择模式："
    echo "1) 初次部署"
    echo "2) 从 R2 恢复数据"
    while true; do
        read -p "选择 (1/2): " MODE
        [[ "$MODE" =~ ^(1|2)$ ]] && break
        warn "请输入 1 或 2"
    done
}

input_config() {
    until validate_domain "$DOMAIN"; do ask "域名 (如 vault.example.com)" DOMAIN; done
    until validate_email "$EMAIL"; do ask "管理员邮箱 (Let's Encrypt 使用)" EMAIL; done

    # ======== 第一个 CF 账号 ========
    log "🔐 配置第一个 Cloudflare 账号"
    ask "CF 账号1 Account ID" CF1_ACCOUNT_ID
    while [[ -z "$CF1_ACCOUNT_ID" ]]; do ask "Account ID 不能为空" CF1_ACCOUNT_ID; done
    ask "CF 账号1 Access Key" CF1_ACCESS_KEY
    ask "CF 账号1 Secret Key" CF1_SECRET_KEY
    ask "CF 账号1 Bucket 名称" CF1_BUCKET

    # ======== 第二个 CF 账号 ========
    log "🔐 配置第二个 Cloudflare 账号"
    ask "CF 账号2 Account ID" CF2_ACCOUNT_ID
    while [[ -z "$CF2_ACCOUNT_ID" ]]; do ask "Account ID 不能为空" CF2_ACCOUNT_ID; done
    ask "CF 账号2 Access Key" CF2_ACCESS_KEY
    ask "CF 账号2 Secret Key" CF2_SECRET_KEY
    ask "CF 账号2 Bucket 名称" CF2_BUCKET

    # ======== 加密密码 ========
    read -sp "🔹 为备份设置加密密码（用于 GPG 加密）: " ENCRYPTION_PASSWORD
    echo
    while [[ -z "$ENCRYPTION_PASSWORD" ]]; do
        warn "加密密码不能为空"
        read -sp "🔹 请设置加密密码: " ENCRYPTION_PASSWORD
        echo
    done

    # ======== 通知方式 ========
    if confirm "启用 Telegram 通知？"; then
        NOTIFY_METHOD="telegram"
        ask "Bot Token" TELEGRAM_BOT_TOKEN
        ask "Chat ID" TELEGRAM_CHAT_ID
    elif confirm "启用邮件通知？"; then
        NOTIFY_METHOD="email"
        until validate_email "$SMTP_USER"; do ask "SMTP 用户名" SMTP_USER; done
        read -sp "SMTP 密码" SMTP_PASS
        echo
        ask "SMTP 服务器 (默认 smtp.gmail.com)" input_smtp
        SMTP_SERVER="${input_smtp:-smtp.gmail.com}"
        ask "SMTP 端口 (默认 587)" input_port
        SMTP_PORT="${input_port:-587}"
    fi

    confirm "确认使用以上配置？" || { error "用户取消"; exit 1; }
}

# ========== 创建 S3CMD 配置文件 ==========
setup_s3cfg() {
    cat > "$S3CMD_CONF_A" << EOF
[default]
access_key = $CF1_ACCESS_KEY
secret_key = $CF1_SECRET_KEY
host_base = ${CF1_ACCOUNT_ID}.r2.cloudflarestorage.com
use_https = True
signature_v2 = False
EOF
    chmod 600 "$S3CMD_CONF_A"

    cat > "$S3CMD_CONF_B" << EOF
[default]
access_key = $CF2_ACCESS_KEY
secret_key = $CF2_SECRET_KEY
host_base = ${CF2_ACCOUNT_ID}.r2.cloudflarestorage.com
use_https = True
signature_v2 = False
EOF
    chmod 600 "$S3CMD_CONF_B"

    log "✅ 已生成两个 R2 配置文件"
}

# ========== 恢复数据（支持 GPG 解密）==========
restore_from_r2() {
    log "🔄 从 R2 恢复加密数据..."

    setup_s3cfg

    echo "请选择从哪个账号恢复："
    echo "1) CF 账号1: $CF1_BUCKET"
    echo "2) CF 账号2: $CF2_BUCKET"
    read -p "选择 (1/2): " RESTORE_FROM

    local bucket conf
    case "$RESTORE_FROM" in
        1) bucket="$CF1_BUCKET"; conf="$S3CMD_CONF_A" ;;
        2) bucket="$CF2_BUCKET"; conf="$S3CMD_CONF_B" ;;
        *) error "无效选择"; exit 1 ;;
    esac

    local latest=$(s3cmd --config="$conf" ls "s3://$bucket/" 2>/dev/null | grep 'bitwarden-.*\.tar\.gz\.gpg' | tail -n1 | awk '{print $4}')
    [[ -z "$latest" ]] && { error "在 $bucket 中未找到加密备份文件"; exit 1; }

    mkdir -p "$BACKUP_DIR"
    local enc_file="$BACKUP_DIR/restore_encrypted.tar.gz.gpg"
    
    log "📥 下载加密备份: $latest"
    s3cmd --config="$conf" get "$latest" "$enc_file" || { error "下载失败"; exit 1; }

    log "🔓 正在解密备份文件..."
    read -sp "请输入加密密码: " DECRYPTION_PASSWORD
    echo
    echo "$DECRYPTION_PASSWORD" | gpg --batch --yes --passphrase-fd 0 --decrypt "$enc_file" > "$BACKUP_DIR/decrypted.tar.gz" || { error "解密失败，请检查密码"; exit 1; }
    rm -f "$enc_file"
    log "✅ 解密成功"

    mkdir -p "$DATA_DIR/data"
    tar -xzf "$BACKUP_DIR/decrypted.tar.gz" -C "$DATA_DIR/data" --strip-components=1
    rm -f "$BACKUP_DIR/decrypted.tar.gz"
    log "✅ 数据已恢复到 $DATA_DIR/data"
}

# ========== 部署服务 ==========
deploy_service() {
    log "🚀 部署 Vaultwarden"

    mkdir -p "$DATA_DIR"
    cat > "$DATA_DIR/docker-compose.yml" << EOF
version: '3'
services:
  vaultwarden:
    image: vaultwarden/server:$VW_VERSION
    container_name: vaultwarden
    restart: always
    volumes:
      - ./data:/data
    environment:
      - WEBSOCKET_ENABLED=true
      - ROCKET_LISTENER_ADDRESS=0.0.0.0
      - DOMAIN=https://$DOMAIN
      - SIGNUPS_ALLOWED=false
      - ADMIN_TOKEN=\$(cat /data/admin_token 2>/dev/null || openssl rand -base64 32 | tee /data/admin_token)
    ports:
      - "127.0.0.1:8080:80"
EOF

    cd "$DATA_DIR" && docker-compose down -v 2>/dev/null || true
    docker-compose up -d
    docker exec vaultwarden cat /data/admin_token > "$DATA_DIR/admin_token" 2>/dev/null || true
    log "✅ 服务启动完成"
}

# ========== Nginx + HTTPS ==========
setup_nginx_ssl() {
    local conf="/etc/nginx/conf.d/bitwarden.conf"
    cat > "$conf" << EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { alias /var/www/certbot/; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    client_max_body_size 128M;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /notifications/hub {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    nginx -t && systemctl reload nginx

    if [[ ! -d "/etc/letsencrypt/live/$DOMAIN" ]]; then
        mkdir -p /var/www/certbot
        certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" --email "$EMAIL" --agree-tos -n || true
    fi

    # 自动续期
    (crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
    log "✅ HTTPS 已配置"
}

# ========== 创建备份脚本（GPG 加密版）==========
create_backup_script() {
    local script="/usr/local/bin/bitwarden-backup.sh"
    cat > "$script" << 'EOF'
#!/bin/bash

SOURCE="/opt/bitwarden/data"
BACKUP_DIR="/opt/bitwarden/backups"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
RAW_FILE="$BACKUP_DIR/bitwarden-$TIMESTAMP.tar.gz"
ENC_FILE="$RAW_FILE.gpg"
TEMP_LIST=$(mktemp)

log() { echo "[INFO] $(date '+%F %T') $1"; }
error() { echo "[ERROR] $(date '+%F %T') $1"; }

# ======== 注入配置变量 ========
ENCRYPTION_PASSWORD="__ENCRYPTION_PASSWORD__"
CF1_ID="__CF1_ID__"
CF1_KEY="__CF1_KEY__"
CF1_SEC="__CF1_SEC__"
CF1_BKT="__CF1_BKT__"
CF2_ID="__CF2_ID__"
CF2_KEY="__CF2_KEY__"
CF2_SEC="__CF2_SEC__"
CF2_BKT="__CF2_BKT__"
NOTIFY_METHOD="__NOTIFY_METHOD__"
TG_TOKEN="__TG_TOKEN__"
TG_CHAT="__TG_CHAT__"
SMTP_USER="__SMTP_USER__"
SMTP_PASS="__SMTP_PASS__"
SMTP_HOST="__SMTP_HOST__"
SMTP_PORT="__SMTP_PORT__"

CONF1="/tmp/.s3cfg.cf1"
CONF2="/tmp/.s3cfg.cf2"

# ======== 打包数据 ========
log "📦 开始打包 Bitwarden 数据..."
mkdir -p "$BACKUP_DIR"
tar -czf "$RAW_FILE" -C "$SOURCE" . || { error "打包失败"; exit 1; }
log "✅ 数据已打包: $RAW_FILE"

# ======== GPG 加密 ========
log "🔐 正在使用 GPG AES256 加密..."
echo "$ENCRYPTION_PASSWORD" | gpg --batch --yes --cipher-algo AES256 -c --passphrase-fd 0 "$RAW_FILE" || { error "加密失败"; exit 1; }
rm -f "$RAW_FILE"
log "✅ 已加密: $ENC_FILE"

# ======== 写入 s3cmd 配置 ========
cat > "$CONF1" << EOL
[default]
access_key = $CF1_KEY
secret_key = $CF1_SEC
host_base = ${CF1_ID}.r2.cloudflarestorage.com
use_https = True
signature_v2 = False
EOL
chmod 600 "$CONF1"

cat > "$CONF2" << EOL
[default]
access_key = $CF2_KEY
secret_key = $CF2_SEC
host_base = ${CF2_ID}.r2.cloudflarestorage.com
use_https = True
signature_v2 = False
EOL
chmod 600 "$CONF2"

# ======== 上传到两个 R2 账号 ========
log "📤 正在上传加密备份到两个 R2 账号..."
s3cmd --config="$CONF1" put "$ENC_FILE" "s3://$CF1_BKT/" && log "✅ 已上传至 CF1: $CF1_BKT"
s3cmd --config="$CONF2" put "$ENC_FILE" "s3://$CF2_BKT/" && log "✅ 已上传至 CF2: $CF2_BKT"

# ======== 清理 R2 上过期的加密备份（>15天，最少保留1个）========
clean_r2_old_backups() {
    local config="$1"
    local bucket="$2"
    local cutoff_days=15
    local now=$(date +%s)
    local list_file=$(mktemp)

    log "🧹 扫描 $bucket 中的加密备份文件..."
    s3cmd --config="$config" ls "s3://$bucket/" | grep 'bitwarden-.*\.tar\.gz\.gpg' > "$list_file"

    local total_count=$(wc -l < "$list_file")
    if [ $total_count -eq 0 ]; then
        log "✅ $bucket 中无相关备份文件"
        rm -f "$list_file"
        return
    fi

    if [ $total_count -le 1 ]; then
        log "⚠️ 仅 $total_count 个备份，启用保护：不删除任何文件"
        rm -f "$list_file"
        return
    fi

    log "📊 发现 $total_count 个备份，开始检查 >$cutoff_days 天的文件..."
    while read -r line; do
        file_date_str="$(echo "$line" | awk '{print $1, $2}')"
        file_url="$(echo "$line" | awk '{print $4}')"
        [ -z "$file_date_str" ] || [ -z "$file_url" ] && continue

        file_ts=$(date -d "$file_date_str" +%s 2>/dev/null) || continue
        days_old=$(( (now - file_ts) / 86400 ))

        if [ $days_old -gt $cutoff_days ]; then
            log "🗑️ 过期文件 ($days_old 天): $file_url"
            s3cmd --config="$config" del "$file_url" > /dev/null && log "✔️ 已删除 $file_url"
        else
            log "📌 保留文件 ($days_old 天): $file_url"
        fi
    done < "$list_file"
    rm -f "$list_file"
}

clean_r2_old_backups "$CONF1" "$CF1_BKT"
clean_r2_old_backups "$CONF2" "$CF2_BKT"

# ======== 清理本地旧加密备份（保留7天） ========
find "$BACKUP_DIR" -name "bitwarden-*.tar.gz.gpg" -mtime +7 -delete
log "🧹 本地旧备份已清理（保留7天内）"

# ======== 发送通知 ========
FILENAME=$(basename "$ENC_FILE")
MSG="🔐 加密备份成功\n📅 $(date)\n📄 $FILENAME\n📍 CF1: $CF1_BKT\n📍 CF2: $CF2_BKT\n💡 使用 AES256-GPG 加密"

if [[ "$NOTIFY_METHOD" == "telegram" && -n "$TG_TOKEN" ]]; then
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT" -d text="$MSG" > /dev/null
    log "📲 Telegram 通知已发送"
elif [[ "$NOTIFY_METHOD" == "email" && -n "$SMTP_USER" ]]; then
    {
        echo "To: $SMTP_USER"
        echo "Subject: Bitwarden 加密备份完成"
        echo ""
        echo -e "$MSG"
    } | s-nail -S smtp="$SMTP_HOST:$SMTP_PORT" -S smtp-use-starttls \
               -S smtp-auth=login \
               -S smtp-auth-user="$SMTP_USER" \
               -S smtp-auth-password="$SMTP_PASS" \
               -S ssl-verify=ignore \
               -v "$SMTP_USER" > /dev/null
    log "📧 邮件通知已发送"
fi

log "🎉 全部完成"
EOF

    # 替换占位符
    sed -i "s|__ENCRYPTION_PASSWORD__|$ENCRYPTION_PASSWORD|g" "$script"
    sed -i "s|__CF1_ID__|$CF1_ACCOUNT_ID|g" "$script"
    sed -i "s|__CF1_KEY__|$CF1_ACCESS_KEY|g" "$script"
    sed -i "s|__CF1_SEC__|$CF1_SECRET_KEY|g" "$script"
    sed -i "s|__CF1_BKT__|$CF1_BUCKET|g" "$script"
    sed -i "s|__CF2_ID__|$CF2_ACCOUNT_ID|g" "$script"
    sed -i "s|__CF2_KEY__|$CF2_ACCESS_KEY|g" "$script"
    sed -i "s|__CF2_SEC__|$CF2_SECRET_KEY|g" "$script"
    sed -i "s|__CF2_BKT__|$CF2_BUCKET|g" "$script"
    sed -i "s|__NOTIFY_METHOD__|$NOTIFY_METHOD|g" "$script"
    sed -i "s|__TG_TOKEN__|$TELEGRAM_BOT_TOKEN|g" "$script"
    sed -i "s|__TG_CHAT__|$TELEGRAM_CHAT_ID|g" "$script"
    sed -i "s|__SMTP_USER__|$SMTP_USER|g" "$script"
    sed -i "s|__SMTP_PASS__|$SMTP_PASS|g" "$script"
    sed -i "s|__SMTP_HOST__|$SMTP_SERVER|g" "$script"
    sed -i "s|__SMTP_PORT__|$SMTP_PORT|g" "$script"

    chmod +x "$script"

    # 添加定时任务
    (crontab -l 2>/dev/null | grep -v bitwarden-backup; echo "0 2 * * * $script >> /var/log/bitwarden-backup.log 2>&1") | crontab -

    log "✅ 加密备份脚本已创建并启用"
}

# ========== 主流程 ==========
main() {
    log "=== Bitwarden 加密容灾部署开始 ==="

    detect_os
    choose_mode
    input_config
    install_dependencies

    if [[ "$MODE" == "2" ]]; then
        restore_from_r2
    fi

    deploy_service
    setup_nginx_ssl
    create_backup_script

    echo
    echo "=================================================="
    echo "✅ 部署完成！"
    echo "🌐 访问: https://$DOMAIN"
    echo "🛠️  管理: https://$DOMAIN/admin"
    [[ -f "$DATA_DIR/admin_token" ]] && echo "🔑 Token: $(cat "$DATA_DIR/admin_token")"
    echo "📁 数据目录: $DATA_DIR/data"
    echo "📝 日志: $LOG_FILE"
    echo "🔐 双 R2 备份: $CF1_BUCKET (账号1), $CF2_BUCKET (账号2)"
    echo "🔒 加密算法: GPG + AES256"
    echo "⏰ 自动备份: 每日凌晨 2:00"
    echo "🧼 自动清理: R2 >15天（最少保留1个），本地 >7天"
    echo "💡 重要：加密密码已保存，恢复时需手动输入"
    echo "=================================================="

    MSG="🚀 Bitwarden 部署完成\n📍 $DOMAIN\n🔐 查看 Token: cat $DATA_DIR/admin_token"
    if [[ "$NOTIFY_METHOD" == "telegram" && -n "$TELEGRAM_BOT_TOKEN" ]]; then
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" -d text="$MSG" > /dev/null
    elif [[ "$NOTIFY_METHOD" == "email" && -n "$SMTP_USER" ]]; then
        echo -e "$MSG" | s-nail -S smtp="$SMTP_SERVER:$SMTP_PORT" -S smtp-use-starttls \
                   -S smtp-auth=login -S "smtp-auth-user=$SMTP_USER" \
                   -S "smtp-auth-password=$SMTP_PASS" -S ssl-verify=ignore \
                   -v "$SMTP_USER" > /dev/null
    fi
}

# ========== 执行 ==========
if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户运行此脚本"
    exit 1
fi

main "$@"
