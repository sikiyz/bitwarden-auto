#!/bin/bash
# ========================================================
# Bitwarden + Caddy + R2 Encrypted Backup Auto Installer
# Author: Assistant (Qwen)
# Features:
#   - Install or Restore Bitwarden RS with Caddy reverse proxy
#   - Auto detect IPv4/v6 for domain binding
#   - Daily encrypted backup to two Cloudflare R2 buckets
#   - Email or Telegram notifications
#   - Test notification & cleanup options
# ========================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_FILE="/opt/bitwarden/bw-auto.conf"
BACKUP_DIR="/opt/bitwarden/backups"
SCRIPT_DIR="/opt/bitwarden/scripts"
LOG_FILE="/var/log/bitwarden-auto.log"
CRON_JOB="0 2 * * * /bin/bash $SCRIPT_DIR/backup.sh >> $LOG_FILE 2>&1"

# 日志函数
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "${RED}ERROR: $1${NC}"
    exit 1
}

# ============== 菜单选择 ==============
show_menu() {
    echo
    echo "=========================================="
    echo "   Bitwarden 一键部署与恢复脚本"
    echo "=========================================="
    echo "1) 初次搭建（Install from scratch）"
    echo "2) 恢复搭建（Restore from backup）"
    echo "3) 发送测试通知（Test Notification）"
    echo "4) 删除所有部署内容（Clean Up）"
    echo "5) 退出"
    echo "=========================================="
}

# ============== 配置收集 ==============
load_or_ask_config() {
    declare -A config_keys=(
        ["DOMAIN"]="主域名（例如：vault.example.com）"
        ["EMAIL"]="管理员邮箱（用于 Let's Encrypt）"
        ["TZ"]="时区（如 Asia/Shanghai）"
        ["R2_ENDPOINT"]="R2 终端节点（默认：https://\${BUCKET}.\${ACCOUNT}.r2.cloudflarestorage.com）"
        ["R2_ACCOUNT_ID"]="Cloudflare Account ID"
        ["R2_ACCESS_KEY_ID"]="R2 Access Key ID"
        ["R2_SECRET_ACCESS_KEY"]="R2 Secret Access Key"
        ["R2_BUCKET_1"]="第一个 R2 存储桶名称"
        ["R2_BUCKET_2"]="第二个 R2 存储桶名称"
        ["NOTIFY_METHOD"]="通知方式（telegram/email）"
        ["TELEGRAM_BOT_TOKEN"]="Telegram Bot Token（如果选择 telegram）"
        ["TELEGRAM_CHAT_ID"]="Telegram Chat ID（如果选择 telegram）"
        ["SMTP_HOST"]="SMTP 主机（如 smtp.gmail.com）"
        ["SMTP_PORT"]="SMTP 端口（如 587）"
        ["SMTP_USER"]="SMTP 用户名（邮箱地址）"
        ["SMTP_PASS"]="SMTP 密码或 App Password"
        ["ENCRYPTION_PASSWORD"]="备份加密密码（建议强密码）"
    )

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log "${GREEN}已加载现有配置文件。${NC}"
        read -p "是否重新配置？(y/N): " -n1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 0
    fi

    : > "$CONFIG_FILE"
    for key in "${!config_keys[@]}"; do
        local prompt="${config_keys[$key]}"
        while true; do
            read -p "$prompt: " input
            if [[ -z "$input" ]]; then
                if [[ "$key" == "TELEGRAM_BOT_TOKEN" || "$key" == "TELEGRAM_CHAT_ID" ]] && [[ "${NOTIFY_METHOD:-}" != "telegram" ]]; then
                    break
                elif [[ "$key" == "SMTP_"* ]] && [[ "${NOTIFY_METHOD:-}" != "email" ]]; then
                    break
                else
                    echo -e "${YELLOW}此项不能为空${NC}"
                fi
            else
                declare "$key=$input"
                echo "$key='$input'" >> "$CONFIG_FILE"
                break
            fi
        done
    done

    # 特殊处理 DOMAIN 协议
    if [[ "$DOMAIN" != http* ]]; then
        DOMAIN="https://$DOMAIN"
    fi
    echo "DOMAIN='$DOMAIN'" >> "$CONFIG_FILE"

    log "${GREEN}配置已保存至 $CONFIG_FILE${NC}"
}

# ============== 依赖检查与安装 ==============
install_dependencies() {
    log "正在安装必要依赖..."
    apt-get update
    apt-get install -y \
        docker.io \
        docker-compose \
        curl \
        wget \
        gnupg \
        ca-certificates \
        jq \
        rclone \
        haveged \
        ssmtp \
        mailutils \
        || error_exit "依赖安装失败"

    # 启用 Docker
    systemctl enable docker --now || true
}

# ============== 检查是否已安装 bitwarden ==============
is_bitwarden_installed() {
    [[ -d "/opt/bitwarden" ]] && [[ -f "/opt/bitwarden/docker-compose.yml" ]]
}

# ============== 获取公网 IP（优先 IPv6） ==============
get_preferred_ip() {
    local ipv6=$(curl -s6 --max-time 5 https://ifconfig.co)
    local ipv4=$(curl -s4 --max-time 5 https://ifconfig.co)

    if [[ -n "$ipv6" ]] && [[ "$ipv6" != *"timeout"* ]]; then
        echo "$ipv6"
        export USE_IPV6=true
    elif [[ -n "$ipv4" ]]; then
        echo "$ipv4"
        export USE_IPV6=false
    else
        error_exit "无法获取公网 IP"
    fi
}

# ============== Caddy 安装与配置 ==============
setup_caddy() {
    local domain=${DOMAIN#https://}
    local ip=$(get_preferred_ip)
    log "使用 IP: $ip (${USE_IPV6:+IPv6} ${USE_IPV6:-IPv4}) 绑定域名 $domain"

    # 写入 Caddyfile
    cat > /etc/caddy/Caddyfile << EOF
$domain {
    reverse_proxy http://127.0.0.1:8080
    tls $EMAIL
}
EOF

    # 安装 Caddy
    if ! command -v caddy &> /dev/null; then
        curl -1sLf 'https://dl.caddyserver.com/install.sh' | bash
    fi

    # 启动 Caddy
    systemctl enable caddy --now || error_exit "Caddy 启动失败"
    sleep 5
}

# ============== 初始化 Bitwarden ==============
setup_bitwarden() {
    local bw_dir="/opt/bitwarden"
    mkdir -p "$bw_dir"
    cd "$bw_dir"

    if [[ ! -f "docker-compose.yml" ]]; then
        curl -O https://raw.githubusercontent.com/dani-garcia/bitwarden_rs/master/docker-compose.yml
    fi

    # 修改端口为 8080 避免冲突
    sed -i 's/80:80/8080:80/g' docker-compose.yml

    # 创建 env 文件（可根据需要扩展）
    cat > .env << EOF
SIGNUPS_ALLOWED=true
ADMIN_TOKEN=$(openssl rand -base64 32)
WEBSOCKET_ENABLED=true
EOF

    # 启动容器
    docker-compose up -d
    sleep 10

    if ! docker-compose ps | grep -q "Up"; then
        error_exit "Bitwarden 容器启动失败"
    fi

    log "${GREEN}Bitwarden 已成功启动！访问 $DOMAIN${NC}"
}

# ============== Rclone 配置 R2 ==============
setup_rclone() {
    local name1="r2-$R2_BUCKET_1"
    local name2="r2-$R2_BUCKET_2"

    # 自动生成 rclone 配置
    cat > ~/.config/rclone/rclone.conf << EOF
[$name1]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com
region = auto

[$name2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com
region = auto
EOF

    log "Rclone 已配置完毕"
}

# ============== 创建备份脚本 ==============
create_backup_script() {
    mkdir -p "$SCRIPT_DIR"
    cat > "$SCRIPT_DIR/backup.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

source '/opt/bitwarden/bw-auto.conf'
export PASSPHRASE="$ENCRYPTION_PASSWORD"

DATE=$(date '+%Y%m%d-%H%M%S')
BACKUP_NAME="bitwarden-backup-$DATE.tar.gz"
ENCRYPTED_NAME="$BACKUP_NAME.gpg"
RAW_PATH="$BACKUP_DIR/$BACKUP_NAME"
ENC_PATH="$BACKUP_DIR/$ENCRYPTED_NAME"

BW_DIR="/opt/bitwarden"
TEMP_BACKUP="/tmp/bitwarden-full-backup.tar.gz"

# 创建备份
tar -czf "$TEMP_BACKUP" -C "$BW_DIR" . || exit 1

# 加密
gpg --batch --yes --passphrase "$PASSPHRASE" --symmetric --cipher-algo AES256 "$TEMP_BACKUP"
mv "$TEMP_BACKUP.gpg" "$ENC_PATH"
rm -f "$TEMP_BACKUP"

upload_to_r2() {
    local remote=$1
    local file=$2
    rclone copy "$file" "$remote" --progress
    echo "✅ 备份已上传至 $remote: $(basename "$file")"
}

RESULT=""
if upload_to_r2 "r2-$R2_BUCKET_1:$R2_BUCKET_1" "$ENC_PATH"; then
    RESULT+="Primary R2 ($R2_BUCKET_1): Success\n"
else
    RESULT+="Primary R2 ($R2_BUCKET_1): Failed\n"
fi

sleep 5

if upload_to_r2 "r2-$R2_BUCKET_2:$R2_BUCKET_2" "$ENC_PATH"; then
    RESULT+="Secondary R2 ($R2_BUCKET_2): Success\n"
else
    RESULT+="Secondary R2 ($R2_BUCKET_2): Failed\n"
fi

# 发送通知
NOTIFY_LOG="Backup on $(date)\nFiles: $ENCRYPTED_NAME\n$RESULT"
send_notification "$NOTIFY_LOG"
EOF

    # 添加 send_notification 函数
    cat >> "$SCRIPT_DIR/backup.sh" << EOF
send_notification() {
    local msg="\$(echo -e "\$1" | sed 's/^/    /')"
    case "$NOTIFY_METHOD" in
        telegram)
            curl -s -X POST "https://api.telegram.org/bot\$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="\$TELEGRAM_CHAT_ID" \
                -d text="🔔 Bitwarden Backup Report:\n\n\$msg"
            ;;
        email)
            echo "\$1" | mail -s "BitFields Backup Report - \$(date +%F)" "\$SMTP_USER"
            ;;
    esac
}
EOF

    chmod +x "$SCRIPT_DIR/backup.sh"
    log "备份脚本已创建：$SCRIPT_DIR/backup.sh"
}

# ============== 设置定时任务 ==============
setup_cron() {
    crontab -l | grep -v 'backup.sh' | crontab -
    (crontab -l ; echo "$CRON_JOB") 2>/dev/null | crontab -
    log "每日备份任务已添加（凌晨 2 点执行）"
}

# ============== 测试通知 ==============
test_notification() {
    if ! is_bitwarden_installed; then
        error_exit "Bitwarden 尚未安装，请先完成初次搭建。"
    fi

    source "$CONFIG_FILE"
    local test_msg="🔧 Bitwarden 一键脚本通知测试\n时间：$(date)\n状态：一切正常 ✅"

    case "$NOTIFY_METHOD" in
        telegram)
            response=$(curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$test_msg")
            if echo "$response" | jq -e '.ok == true' >/dev/null; then
                log "${GREEN}Telegram 测试消息发送成功！${NC}"
            else
                error_exit "Telegram 发送失败：$response"
            fi
            ;;
        email)
            echo -e "$test_msg" | mail -s "BitFields Test Notification" "$SMTP_USER"
            log "${GREEN}邮件测试已发送至 $SMTP_USER${NC}"
            ;;
        *)
            error_exit "无效的通知方式"
            ;;
    esac
}

# ============== 清理部署 ==============
cleanup_all() {
    read -p "⚠️  此操作将删除 Bitwarden、Caddy、备份和所有相关数据！确认？(y/N): " -n1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && return

    log "正在清理..."

    # 停止服务
    if [[ -d "/opt/bitwarden" ]]; then
        cd /opt/bitwarden && docker-compose down 2>/dev/null || true
    fi

    # 删除目录
    rm -rf /opt/bitwarden
    rm -rf /etc/caddy
    rm -f /etc/systemd/system/caddy.service
    systemctl disable caddy 2>/dev/null || true

    # 删除 cron
    crontab -l | grep -v 'backup.sh' | crontab -

    # 删除 rclone
    sed -i '/r2-/d' ~/.config/rclone/rclone.conf 2>/dev/null || true

    log "${GREEN}清理完成！${NC}"
}

# ============== 恢复流程 ==============
restore_bitwarden() {
    source "$CONFIG_FILE"
    local bw_dir="/opt/bitwarden"
    mkdir -p "$bw_dir"

    log "请输入要恢复的加密备份文件名（位于 $BACKUP_DIR），例如：bitwarden-backup-20240405-100000.tar.gz.gpg"
    read -r backup_file
    local full_path="$BACKUP_DIR/$backup_file"

    if [[ ! -f "$full_path" ]]; then
        error_exit "文件不存在：$full_path"
    fi

    export PASSPHRASE="$ENCRYPTION_PASSWORD"
    local decrypted="/tmp/restored-backup.tar.gz"

    # 解密
    gpg --batch --yes --passphrase "$PASSPHRASE" --decrypt "$full_path" > "$decrypted" 2>/dev/null || error_exit "解密失败，请检查密码"

    # 提取
    mkdir -p "$bw_dir.tmp"
    tar -xzf "$decrypted" -C "$bw_dir.tmp"
    cp -r "$bw_dir.tmp/"* "$bw_dir/"
    rm -rf "$bw_dir.tmp" "$decrypted"

    cd "$bw_dir"
    docker-compose up -d

    log "${GREEN}恢复完成！请访问 $DOMAIN${NC}"
}

# ============== 主函数 ==============
main() {
    while true; do
        show_menu
        read -p "请选择操作 [1-5]: " choice
        echo

        case $choice in
            1)
                log "开始初次搭建..."
                load_or_ask_config
                install_dependencies
                setup_bitwarden
                setup_caddy
                setup_rclone
                create_backup_script
                setup_cron
                log "${GREEN}🎉 初次搭建完成！Bitwarden 已运行在 $DOMAIN${NC}"
                ;;
            2)
                if ! is_bitwarden_installed; then
                    log "未检测到 Bitwarden 安装，开始恢复流程..."
                    load_or_ask_config
                    install_dependencies
                    setup_rclone
                    restore_bitwarden
                else
                    log "已存在 Bitwarden 实例。"
                    read -p "是否继续恢复？这会覆盖现有数据！(y/N): " -n1 -r
                    echo
                    [[ $REPLY =~ ^[Yy]$ ]] && restore_bitwarden
                fi
                ;;
            3)
                if [[ -f "$CONFIG_FILE" ]]; then
                    test_notification
                else
                    error_exit "未找到配置文件，请先完成初次搭建。"
                fi
                ;;
            4)
                cleanup_all
                ;;
            5)
                log "再见！"
                exit 0
                ;;
            *)
                log "${RED}无效选项${NC}"
                ;;
        esac
    done
}

# ============== 执行入口 ==============
if [[ "$EUID" -ne 0 ]]; then
    error_exit "请以 root 或 sudo 运行此脚本"
fi

mkdir -p /opt/bitwarden /var/log
touch "$LOG_FILE"

# 检查 rclone 是否存在，否则安装
if ! command -v rclone &> /dev/null; then
    curl https://rclone.org/install.sh | bash
fi

# 创建 GPG 密钥（用于加密）
if ! command -v gpg &> /dev/null; then
    apt-get install -y gnupg
fi

# 生成临时密钥（仅用于脚本内加密）
if ! gpg --list-keys "$ENCRYPTION_PASSWORD" 2>/dev/null; then
    cat > /tmp/gpg-batch << EOF
%echo Generating a basic OpenPGP key
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: Bitwarden Backup
Name-Email: backup@local
Expire-Date: 0
Passphrase: $ENCRYPTION_PASSWORD
%commit
%echo Done
EOF
    gpg --batch --gen-key /tmp/gpg-batch 2>/dev/null || true
    rm -f /tmp/gpg-batch
fi

# 启动主菜单
main
