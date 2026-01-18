#!/bin/bash

#================================================#
#     🔐 Bitwarden 一键部署（双 CF 账号 + GPG 加密） #
#   全平台兼容 | 自动 HTTPS | 智能容灾 | 多通知     #
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

# ========== 新增：反代相关变量 ==========
PROXY_MODE="1"
PROXY_TARGET="127.0.0.1:8080"

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

# ========== 脚本自身信息（请勿修改）==========
SCRIPT_NAME="bitwarden-deploy.sh"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
SCRIPT_REPO_URL="https://raw.githubusercontent.com/sikiyz/bitwarden-auto/main/setup.sh"
REMOTE_CHECK_URL="$SCRIPT_REPO_URL?$(date +%s)"  # 防缓存

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

    # ========== 替换：Nginx → Caddy ==========
    if ! command -v caddy &> /dev/null; then
        log "📦 安装 Caddy..."
        wget -qO- https://api.github.com/repos/caddyserver/caddy/releases/latest \
            | grep "browser_download_url.*linux_$(uname -m | sed 's|x86_64|amd64|;s|aarch64|arm64|').deb" \
            | head -n1 \
            | cut -d '"' -f4 \
            | xargs wget -O /tmp/caddy.deb
        dpkg -i /tmp/caddy.deb && rm -f /tmp/caddy.deb
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

    systemctl enable caddy --now 2>/dev/null || true
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

# ========== 新增：反代模式选择 ==========
choose_proxy_mode() {
    echo
    echo "请选择反向代理模式："
    echo "1) 自动检测（推荐：优先 IPv6 → IPv4 → 127.0.0.1）"
    echo "2) 强制使用 IPv4"
    echo "3) 强制使用 IPv6"
    echo "4) 使用本地回环 127.0.0.1"

    while true; do
        read -p "请输入选项 [1-4] (默认为 1): " PROXY_MODE
        PROXY_MODE=${PROXY_MODE:-1}
        [[ "$PROXY_MODE" =~ ^(1|2|3|4)$ ]] && break
        warn "请输入 1~4"
    done

    case $PROXY_MODE in
        1)
            log "自动检测网络环境..."
            if command -v curl &> /dev/null; then
                IPV6=$(curl -s6 --max-time 5 https://ifconfig.co 2>/dev/null | grep ':' | head -n1 | xargs)
            fi
            if [[ -n "$IPV6" ]]; then
                log "检测到公网 IPv6: $IPV6"
                if timeout 2 bash -c "echo > /dev/tcp/[$IPV6]/8080" 2>/dev/null; then
                    PROXY_TARGET="[$IPV6]:8080"
                    log "使用 IPv6 反代: [$IPV6]:8080"
                fi
            fi
            if [[ "$PROXY_TARGET" == "127.0.0.1:8080" ]]; then
                IPV4=$(curl -s4 --max-time 5 https://ifconfig.co 2>/dev/null || echo "")
                if [[ -n "$IPV4" ]]; then
                    if timeout 2 bash -c "echo > /dev/tcp/$IPV4/8080" 2>/dev/null; then
                        PROXY_TARGET="$IPV4:8080"
                        log "使用 IPv4 反代: $IPV4:8080"
                    fi
                fi
            fi
            ;;
        2)
            log "强制使用 IPv4"
            IPV4=$(curl -s4 --max-time 5 https://ifconfig.co 2>/dev/null || echo "127.0.0.1")
            PROXY_TARGET="$IPV4:8080"
            log "反代目标: $PROXY_TARGET"
            ;;
        3)
            log "强制使用 IPv6"
            if ! command -v curl &> /dev/null; then
                error "curl 未安装"
                exit 1
            fi
            IPV6=$(curl -s6 --max-time 5 https://ifconfig.co 2>/dev/null | grep ':' | head -n1 | xargs)
            if [[ -z "$IPV6" ]]; then
                error "无法获取公网 IPv6 地址"
                exit 1
            fi
            PROXY_TARGET="[$IPV6]:8080"
            log "反代目标: [$IPV6]:8080"
            ;;
        4)
            log "使用本地回环"
            PROXY_TARGET="127.0.0.1:8080"
            log "反代目标: $PROXY_TARGET"
            ;;
    esac
}

# ========== 新增：输入配置函数 ==========
input_config() {
    echo
    log "📝 开始配置 Bitwarden 部署参数"

    # 输入域名
    ask "请输入您的域名（例如：vault.example.com）" DOMAIN
    while ! validate_domain "$DOMAIN"; do
        warn "域名格式不合法，请重新输入"
        ask "请输入有效的域名" DOMAIN
    done

    # 输入邮箱（用于 Let's Encrypt）
    ask "请输入管理员邮箱（用于 HTTPS 证书）" EMAIL
    while ! validate_email "$EMAIL"; do
        warn "邮箱格式不合法，请重新输入"
        ask "请输入有效的邮箱" EMAIL
    done

    # 加密密码（必须）
    read -sp "🔐 请输入备份加密密码（GPG 使用，不会明文保存）: " ENCRYPTION_PASSWORD
    echo
    while [[ -z "$ENCRYPTION_PASSWORD" ]]; do
        warn "加密密码不能为空"
        read -sp "请再次输入加密密码: " ENCRYPTION_PASSWORD
        echo
    done

    # 通知方式
    echo
    echo "请选择通知方式："
    echo "1) Telegram"
    echo "2) Email"
    echo "3) 不启用通知"
    while true; do
        read -p "选择 (1-3): " NOTIFY_CHOICE
        case "$NOTIFY_CHOICE" in
            1)
                ask "Telegram Bot Token" TELEGRAM_BOT_TOKEN
                ask "Telegram Chat ID" TELEGRAM_CHAT_ID
                NOTIFY_METHOD="telegram"
                break
                ;;
            2)
                ask "SMTP 邮箱地址" SMTP_USER
                read -sp "SMTP 密码: " SMTP_PASS
                echo
                ask "SMTP 服务器（如 smtp.gmail.com）" SMTP_SERVER
                ask "SMTP 端口（默认 587）" input_port
                SMTP_PORT="${input_port:-587}"
                NOTIFY_METHOD="email"
                break
                ;;
            3)
                NOTIFY_METHOD="none"
                log "已禁用通知功能"
                break
                ;;
            *)
                warn "请输入 1、2 或 3"
                ;;
        esac
    done

    # 第一个 CF R2 账号
    echo
    log "☁️  配置第一个 Cloudflare R2 存储账号"
    ask "CF 账号 Account ID" CF1_ACCOUNT_ID
    ask "R2 Access Key" CF1_ACCESS_KEY
    ask "R2 Secret Key" CF1_SECRET_KEY
    ask "R2 Bucket 名称" CF1_BUCKET

    # 第二个 CF R2 账号
    echo
    log "☁️  配置第二个 Cloudflare R2 存储账号（容灾备份）"
    ask "CF 账号 Account ID" CF2_ACCOUNT_ID
    ask "R2 Access Key" CF2_ACCESS_KEY
    ask "R2 Secret Key" CF2_SECRET_KEY
    ask "R2 Bucket 名称" CF2_BUCKET

    # 反向代理模式
    choose_proxy_mode

    log "✅ 所有配置项已输入完成"
}

choose_mode() {
    echo
    echo "========================================"
    echo "   🔐 Bitwarden 一键部署（加密容灾版）"
    echo "========================================"
    echo
    echo "当前系统: $OS_NAME"
    echo
    echo "请选择模式："
    echo "0) 🚪 退出脚本"
    echo "1) 💾 初次部署"
    echo "2) 🔄 从 R2 恢复数据"
    echo "3) 🖱️ 立即手动执行一次加密备份"
    echo "4) 🔁 更新脚本至最新版"
    echo "5) 📢 测试通知功能（Telegram / 邮箱）"
    echo "6) 🔍 查看最近备份文件"

    while true; do
        read -p "选择 (0~6): " MODE
        [[ "$MODE" =~ ^[0-6]$ ]] && break
        warn "请输入 0~6"
    done
}

# ========== 创建 S3CMD 配置文件 ==========
setup_s3cfg() {
    cat > "$S3CMD_CONF_A" << 'EOF'
[default]
access_key = __CF1_ACCESS_KEY__
secret_key = __CF1_SECRET_KEY__
host_base = __CF1_ACCOUNT_ID__.r2.cloudflarestorage.com
use_https = True
signature_v2 = False
EOF
    sed -i "s|__CF1_ACCESS_KEY__|$CF1_ACCESS_KEY|g" "$S3CMD_CONF_A"
    sed -i "s|__CF1_SECRET_KEY__|$CF1_SECRET_KEY|g" "$S3CMD_CONF_A"
    sed -i "s|__CF1_ACCOUNT_ID__|$CF1_ACCOUNT_ID|g" "$S3CMD_CONF_A"
    chmod 600 "$S3CMD_CONF_A"

    cat > "$S3CMD_CONF_B" << 'EOF'
[default]
access_key = __CF2_ACCESS_KEY__
secret_key = __CF2_SECRET_KEY__
host_base = __CF2_ACCOUNT_ID__.r2.cloudflarestorage.com
use_https = True
signature_v2 = False
EOF
    sed -i "s|__CF2_ACCESS_KEY__|$CF2_ACCESS_KEY|g" "$S3CMD_CONF_B"
    sed -i "s|__CF2_SECRET_KEY__|$CF2_SECRET_KEY|g" "$S3CMD_CONF_B"
    sed -i "s|__CF2_ACCOUNT_ID__|$CF2_ACCOUNT_ID|g" "$S3CMD_CONF_B"
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

# ========== 替换：Nginx → Caddy ==========
setup_caddy() {
    local conf="/etc/caddy/Caddyfile.d/bitwarden"

    cat > "$conf" << EOF
https://$DOMAIN {
    reverse_proxy $PROXY_TARGET

    # WebSocket 支持
    @websocket {
        header Connection *Upgrade*
        header Upgrade websocket
    }
    reverse_proxy @websocket $PROXY_TARGET

    # 安全头
    header {
        X-Frame-Options DENY
        X-Content-Type-Options nosniff
        X-XSS-Protection "1; mode=block"
        Referrer-Policy no-referrer
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        -Server
    }

    # Let's Encrypt 验证
    acme {
        email $EMAIL
    }
}
EOF

    # 初始化主 Caddyfile
    mkdir -p /etc/caddy/Caddyfile.d
    if [[ ! -f /etc/caddy/Caddyfile ]] || ! grep -q "import Caddyfile.d/*" /etc/caddy/Caddyfile; then
        cat > /etc/caddy/Caddyfile << 'EOF'
{
    email auto@cloudflare.com
}
import Caddyfile.d/*
EOF
    fi

    systemctl reload caddy || systemctl restart caddy
    sleep 3

    if systemctl is-active --quiet caddy; then
        log "✅ Caddy 启动成功"
    else
        error "Caddy 启动失败"
        exit 1
    fi
}

# ========== 创建备份脚本（GPG 加密版）==========
# 注意：使用 << 'BACKUP_EOF' 防止变量提前展开，确保占位符能被后续 sed 正确替换
create_backup_script() {
    local script="/usr/local/bin/bitwarden-backup.sh"
    cat > "$script" << 'BACKUP_EOF'
#!/bin/bash

SOURCE="/opt/bitwarden/data"
BACKUP_DIR="/opt/bitwarden/backups"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
RAW_FILE="$BACKUP_DIR/bitwarden-$TIMESTAMP.tar.gz"
ENC_FILE="$RAW_FILE.gpg"

log() { echo "[INFO] $(date '+%F %T') \$1"; }
error() { echo "[ERROR] $(date '+%F %T') \$1"; }

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
mkdir -p "\$BACKUP_DIR"
tar -czf "\$RAW_FILE" -C "\$SOURCE" . || { error "打包失败"; exit 1; }
log "✅ 数据已打包: \$RAW_FILE"

# ======== GPG 加密 ========
log "🔐 正在使用 GPG AES256 加密..."
echo "\$ENCRYPTION_PASSWORD" | gpg --batch --yes --cipher-algo AES256 -c --passphrase-fd 0 "\$RAW_FILE" || { error "加密失败"; exit 1; }
rm -f "\$RAW_FILE"
log "✅ 已加密: \$ENC_FILE"

# ======== 写入 s3cmd 配置 ========
cat > "\$CONF1" << EOL
[default]
access_key = \$CF1_KEY
secret_key = \$CF1_SEC
host_base = \${CF1_ID}.r2.cloudflarestorage.com
use_https = True
signature_v2 = False
EOL
chmod 600 "\$CONF1"

cat > "\$CONF2" << EOL
[default]
access_key = \$CF2_KEY
secret_key = \$CF2_SEC
host_base = \${CF2_ID}.r2.cloudflarestorage.com
use_https = True
signature_v2 = False
EOL
chmod 600 "\$CONF2"

# ======== 上传到两个 R2 账号 ========
log "📤 正在上传加密备份到两个 R2 账号..."
s3cmd --config="\$CONF1" put "\$ENC_FILE" "s3://\$CF1_BKT/" && log "✅ 已上传至 CF1: \$CF1_BKT"
s3cmd --config="\$CONF2" put "\$ENC_FILE" "s3://\$CF2_BKT/" && log "✅ 已上传至 CF2: \$CF2_BKT"

# ======== 清理 R2 上过期的加密备份（>15天，最少保留1个）========
clean_r2_old_backups() {
    local config="\$1"
    local bucket="\$2"
    local cutoff_days=15
    local now=\$(date +%s)
    local list_file=\$(mktemp)

    log "🧹 扫描 \$bucket 中的加密备份文件..."
    s3cmd --config="\$config" ls "s3://\$bucket/" | grep 'bitwarden-.*\.tar\.gz\.gpg' > "\$list_file"

    local total_count=\$(wc -l < "\$list_file")
    if [ \$total_count -eq 0 ]; then
        log "✅ \$bucket 中无相关备份文件"
        rm -f "\$list_file"
        return
    fi

    if [ \$total_count -le 1 ]; then
        log "⚠️ 仅 \$total_count 个备份，启用保护：不删除任何文件"
        rm -f "\$list_file"
        return
    fi

    log "📊 发现 \$total_count 个备份，开始检查 >\$cutoff_days 天的文件..."
    while read -r line; do
        file_date_str="\$(echo "\$line" | awk '{print \$1, \$2}')"
        file_url="\$(echo "\$line" | awk '{print \$4}')"
        [ -z "\$file_date_str" ] || [ -z "\$file_url" ] && continue

        file_ts=\$(date -d "\$file_date_str" +%s 2>/dev/null) || continue
        days_old=$(( (now - file_ts) / 86400 ))

        if [ \$days_old -gt \$cutoff_days ]; then
            log "🗑️ 过期文件 (\$days_old 天): \$file_url"
            s3cmd --config="\$config" del "\$file_url" > /dev/null && log "✔️ 已删除 \$file_url"
        else
            log "📌 保留文件 (\$days_old 天): \$file_url"
        fi
    done < "\$list_file"
    rm -f "\$list_file"
}

clean_r2_old_backups "\$CONF1" "\$CF1_BKT"
clean_r2_old_backups "\$CONF2" "\$CF2_BKT"

# ======== 清理本地旧加密备份（保留7天） ========
find "\$BACKUP_DIR" -name "bitwarden-*.tar.gz.gpg" -mtime +7 -delete
log "🧹 本地旧备份已清理（保留7天内）"

# ======== 发送通知 ========
FILENAME=\$(basename "\$ENC_FILE")
MSG="🔐 加密备份成功\\n📅 \$(date)\\n📄 \$FILENAME\\n📍 CF1: \$CF1_BKT\\n📍 CF2: \$CF2_BKT\\n💡 使用 AES256-GPG 加密"

if [[ "\$NOTIFY_METHOD" == "telegram" && -n "\$TG_TOKEN" ]]; then
    curl -s -X POST "https://api.telegram.org/bot\$TG_TOKEN/sendMessage" \
        -d chat_id="\$TG_CHAT" -d text="\$MSG" > /dev/null
    log "📲 Telegram 通知已发送"
elif [[ "\$NOTIFY_METHOD" == "email" && -n "\$SMTP_USER" ]]; then
    {
        echo "To: \$SMTP_USER"
        echo "Subject: Bitwarden 加密备份完成"
        echo ""
        echo -e "\$MSG"
    } | s-nail -S smtp="\$SMTP_HOST:\$SMTP_PORT" -S smtp-use-starttls \
               -S smtp-auth=login \
               -S smtp-auth-user="\$SMTP_USER" \
               -S smtp-auth-password="\$SMTP_PASS" \
               -S ssl-verify=ignore \
               -v "\$SMTP_USER" > /dev/null
    log "📧 邮件通知已发送"
fi

log "🎉 全部完成"
BACKUP_EOF

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

# ========== 新增：手动立即备份函数 ==========
run_manual_backup() {
    local data_dir="$DATA_DIR/data"
    local backup_script="/usr/local/bin/bitwarden-backup.sh"

    log "🔍 检查数据目录是否存在有效数据..."
    if [[ ! -d "$data_dir" ]]; then
        error "数据目录不存在：$data_dir"
        error "请先部署服务或恢复数据后再执行手动备份"
        exit 1
    fi

    # 检查是否有非隐藏文件或关键文件
    if ! find "$data_dir" -mindepth 1 ! -name ".*" -print -quit | grep -q "."; then
        warn "数据目录为空或仅包含隐藏文件"
        if ! confirm "确定要对空数据进行备份吗？"; then
            log "用户取消空数据备份"
            exit 1
        fi
    fi

    if [[ ! -x "$backup_script" ]]; then
        error "备份脚本未找到或不可执行: $backup_script"
        error "请先以模式 1 部署服务以生成脚本"
        exit 1
    fi

    log "🔄 开始执行手动加密备份..."
    "$backup_script" >> /var/log/bitwarden-backup.log 2>&1

    log "✅ 手动备份已完成，详情查看日志: /var/log/bitwarden-backup.log"
    echo
    echo "📋 最近几次本地备份:"
    ls -lh "$BACKUP_DIR"/bitwarden-*.tar.gz.gpg 2>/dev/null | tail -n5 || echo "暂无本地加密备份"
}

# ========== 新增：更新脚本函数 ==========
update_script() {
    log "🔁 正在检查脚本更新..."

    local tmp_file=$(mktemp)
    if ! curl -fsSL "$SCRIPT_REPO_URL" -o "$tmp_file"; then
        error "无法下载最新脚本，请检查网络或 URL 是否正确"
        error "当前配置的更新地址: $SCRIPT_REPO_URL"
        exit 1
    fi

    if ! bash -n "$tmp_file"; then
        error "下载的脚本语法错误，可能损坏"
        rm -f "$tmp_file"
        exit 1
    fi

    local backup_path="${SCRIPT_PATH}.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$SCRIPT_PATH" "$backup_path"
    mv "$tmp_file" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"

    # 重新建立 bd 命令软链接
    ln -sf "$SCRIPT_PATH" /usr/local/bin/bd >/dev/null 2>&1

    log "✅ 脚本已更新！"
    log "📁 旧版本已备份至: $backup_path"
    log "💡 下次可通过 'bd' 快捷命令运行"
    exit 0
}

# ========== 新增：测试通知功能 ==========
test_notifications() {
    log "📩 开始测试通知功能..."

    local test_msg="🔔 【测试通知】\n🤖 Bitwarden 脚本运行于 $(hostname)\n📆 $(date)\n💬 这是一条测试消息。"

    # Telegram 测试
    if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
        log "📨 正在发送 Telegram 测试消息..."
        local tg_result=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" -d text="$test_msg")
        if echo "$tg_result" | grep -q '"ok":true'; then
            log "✅ Telegram 通知测试成功"
        else
            error "❌ Telegram 通知失败: $tg_result"
        fi
    else
        warn "⚠️ Telegram 未配置，跳过测试"
    fi

    # Email 测试
    if [[ -n "$SMTP_USER" && -n "$SMTP_PASS" && -n "$SMTP_SERVER" ]]; then
        log "📨 正在发送邮件测试消息..."
        {
            echo "To: $SMTP_USER"
            echo "Subject: Bitwarden 通知测试"
            echo ""
            echo -e "$test_msg"
        } | s-nail -S smtp="$SMTP_SERVER:$SMTP_PORT" -S smtp-use-starttls \
                   -S smtp-auth=login \
                   -S smtp-auth-user="$SMTP_USER" \
                   -S smtp-auth-password="$SMTP_PASS" \
                   -S ssl-verify=ignore \
                   -v "$SMTP_USER" > /dev/null 2>&1 && \
            log "✅ 邮件通知测试成功" || error "❌ 邮件发送失败"
    else
        warn "⚠️ 邮件未完整配置，跳过测试"
    fi

    log "🏁 通知测试完成"
}

# ========== 新增：查看最近备份 ==========
view_recent_backups() {
    echo
    echo "🔍 最近备份文件列表"
    echo "───────────────────────────────"

    # 本地备份
    echo "📁 本地备份 ($BACKUP_DIR):"
    if [[ -d "$BACKUP_DIR" ]]; then
        local local_files=("$BACKUP_DIR"/bitwarden-*.tar.gz.gpg 2>/dev/null)
        if [[ -f "${local_files[0]}" ]]; then
            ls -lt "$BACKUP_DIR"/bitwarden-*.tar.gz.gpg | head -n5 | awk '{print $6" "$7" "$8}'
        else
            echo "  （无）"
        fi
    else
        echo "  ❌ 目录不存在"
    fi

    # R2 备份（需要配置）
    if [[ -n "$CF1_ACCESS_KEY" && -n "$CF1_ACCOUNT_ID" && -n "$CF1_BUCKET" ]]; then
        setup_s3cfg
        echo
        echo "☁️  R2 账号1 ($CF1_BUCKET):"
        s3cmd --config="$S3CMD_CONF_A" ls "s3://$CF1_BUCKET/" 2>/dev/null \
            | grep 'bitwarden-.*\.tar\.gz\.gpg' | tail -n5 | awk '{print $1" "$2" "$4}'
        [[ $? -ne 0 ]] && echo "  ❌ 获取失败（权限或网络问题）"
    else
        echo
        echo "☁️  R2 账号1: 未配置，无法查看"
    fi

    if [[ -n "$CF2_ACCESS_KEY" && -n "$CF2_ACCOUNT_ID" && -n "$CF2_BUCKET" ]]; then
        echo
        echo "☁️  R2 账号2 ($CF2_BUCKET):"
        s3cmd --config="$S3CMD_CONF_B" ls "s3://$CF2_BUCKET/" 2>/dev/null \
            | grep 'bitwarden-.*\.tar\.gz\.gpg' | tail -n5 | awk '{print $1" "$2" "$4}'
        [[ $? -ne 0 ]] && echo "  ❌ 获取失败（权限或网络问题）"
    else
        echo
        echo "☁️  R2 账号2: 未配置，无法查看"
    fi
    echo
}

# ========== 主流程 ==========
main() {
    log "=== Bitwarden 加密容灾部署开始 ==="

    detect_os
    choose_mode

    case "$MODE" in
        0)
            log "🚪 用户选择退出脚本"
            echo "👋 感谢使用，再见！"
            exit 0
            ;;

        1)
            input_config
            install_dependencies
            deploy_service
            setup_caddy
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
            ;;

        2)
            input_config
            install_dependencies
            restore_from_r2
            deploy_service
            setup_caddy
            create_backup_script
            log "✅ 恢复并部署完成"
            ;;

        3)
            run_manual_backup
            ;;

        4)
            update_script
            ;;

        5)
            input_config
            test_notifications
            ;;

        6)
            input_config
            view_recent_backups
            ;;

        *)
            error "未知操作模式"
            exit 1
            ;;
    esac
}

# ========== 设置快捷命令 bd ==========
setup_bd_command() {
    if ! command -v bd &> /dev/null; then
        ln -sf "$SCRIPT_PATH" /usr/local/bin/bd >/dev/null 2>&1
        log "⌨️ 已设置快捷命令 'bd' -> '$SCRIPT_PATH'"
    fi
}

# ========== 执行 ==========
if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户运行此脚本"
    exit 1
fi

# 保存当前脚本到标准路径
[[ -f "$SCRIPT_PATH" ]] || cp "$0" "$SCRIPT_PATH"
chmod +x "$SCRIPT_PATH"

# 设置快捷方式
setup_bd_command

# 启动主流程
main "$@"
