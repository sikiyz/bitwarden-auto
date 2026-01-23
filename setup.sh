#!/bin/bash

# Bitwarden一键安装脚本 - Worker备份版（IPv6兼容）
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
    apt-get install -y curl wget jq openssl cron sqlite3
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
    
    # ============================================
    # Worker备份配置（新）
    # ============================================
    echo ""
    echo "=== Cloudflare Worker备份配置 ==="
    echo "Worker方案更安全，使用预签名URL上传到R2"
    echo ""
    
    echo "第一个Worker（必需）:"
    read -p "Worker URL [例如: https://bitwarden-backup1.workers.dev]: " WORKER_URL_1
    read -p "Worker API Token: " WORKER_TOKEN_1
    
    echo ""
    echo "第二个Worker（可选，用于备份到另一个账号）:"
    read -p "Worker URL [留空跳过]: " WORKER_URL_2
    if [[ -n "$WORKER_URL_2" ]]; then
        read -p "Worker API Token: " WORKER_TOKEN_2
    fi
    
    # 生成密钥
    BACKUP_ENCRYPTION_KEY=$(openssl rand -base64 32)
    ADMIN_TOKEN=$(openssl rand -base64 48)
}

# 创建目录结构
create_directories() {
    log "创建目录结构..."
    mkdir -p /opt/bitwarden/{data,backups,config,scripts}
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
WORKER_URL_1="$WORKER_URL_1"
WORKER_TOKEN_1="$WORKER_TOKEN_1"
WORKER_URL_2="$WORKER_URL_2"
WORKER_TOKEN_2="$WORKER_TOKEN_2"
BACKUP_ENCRYPTION_KEY="$BACKUP_ENCRYPTION_KEY"
ADMIN_TOKEN="$ADMIN_TOKEN"
CONTAINER_NAME="vaultwarden"
BACKUP_DIR="/opt/bitwarden/backups"
RETENTION_DAYS=7
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
    
    # ==========================================
    # 关键修复：根据IP版本创建不同的Caddyfile
    # ==========================================
    log "创建Caddy配置（IPv6兼容版）..."
    
    if [ "$IP_VERSION" = "ipv6" ]; then
        log "检测到IPv6选择，应用IPv6优化配置..."
        # IPv6优化配置（修复了ipv6://协议问题）
        cat > /opt/bitwarden/config/Caddyfile << IPV6_CADDY_EOF
{
    email $EMAIL
    admin off
}

# HTTP自动重定向到HTTPS（IPv6兼容）
$DOMAIN:$HTTP_PORT {
    bind [::]:$HTTP_PORT
    redir https://{host}{uri} permanent
}

# HTTPS主站点（IPv6兼容）
$DOMAIN:$HTTPS_PORT {
    bind [::]:$HTTPS_PORT
    encode gzip
    
    # IPv6优化配置 - 直接使用容器名，Caddy会自动处理
    reverse_proxy vaultwarden:80 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
    
    # WebSocket支持（实时通知）
    handle_path /notifications/hub {
        reverse_proxy vaultwarden:3012 {
            header_up Host {host}
            header_up X-Real-IP {remote}
            header_up X-Forwarded-For {remote}
            header_up X-Forwarded-Proto {scheme}
            header_up Upgrade {http.upgrade}
            header_up Connection {http.request.header.Connection}
        }
    }
    
    handle_path /notifications/hub/negotiate {
        reverse_proxy vaultwarden:80 {
            header_up Host {host}
            header_up X-Real-IP {remote}
            header_up X-Forwarded-For {remote}
            header_up X-Forwarded-Proto {scheme}
        }
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
IPV6_CADDY_EOF
        success "IPv6优化配置已创建"
    else
        log "使用标准IPv4配置..."
        # 标准IPv4配置
        cat > /opt/bitwarden/config/Caddyfile << IPV4_CADDY_EOF
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
    
    # IPv4配置
    reverse_proxy vaultwarden:80 {
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
IPV4_CADDY_EOF
        success "标准IPv4配置已创建"
    fi
    
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

# ============================================
# 创建Worker备份脚本（新）
# ============================================
create_worker_backup_script() {
    log "创建Worker备份脚本..."
    
    cat > /opt/bitwarden/scripts/backup_to_workers.sh << 'BACKUP_WORKER_EOF'
#!/bin/bash
set -e

# ============================================
#    Bitwarden双Worker备份脚本
# ============================================

# 加载配置
CONFIG_FILE="/opt/bitwarden/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "配置文件不存在: $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# 发送通知
send_notification() {
    local message="$1"
    
    case "$NOTIFICATION_TYPE" in
        "telegram")
            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d parse_mode="Markdown" > /dev/null 2>&1 || true
            ;;
        "email")
            echo "$message" | mail -s "Bitwarden备份通知" "$EMAIL_TO" 2>/dev/null || true
            ;;
        "both")
            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d parse_mode="Markdown" > /dev/null 2>&1 || true
            echo "$message" | mail -s "Bitwarden备份通知" "$EMAIL_TO" 2>/dev/null || true
            ;;
    esac
}

# 检查Worker状态
check_worker() {
    local worker_url="$1"
    local api_token="$2"
    local description="$3"
    
    log "检查 $description..."
    
    local response=$(curl -s -w "%{http_code}" "${worker_url}/health" 2>/dev/null)
    local http_code="${response: -3}"
    local response_body="${response%???}"
    
    if [[ "$http_code" == "200" ]] && echo "$response_body" | grep -q '"status":"ok"'; then
        success "$description 状态正常"
        return 0
    else
        error "$description 状态异常 (HTTP $http_code)"
        return 1
    fi
}

# 备份数据库
backup_database() {
    log "备份数据库..."
    
    # 检查容器
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        error "容器未运行: $CONTAINER_NAME"
        return 1
    fi
    
    # 临时目录
    local temp_dir="/tmp/db_backup_$(date +%s)"
    mkdir -p "$temp_dir"
    
    # 复制数据库文件
    if ! docker cp "${CONTAINER_NAME}:/data/db.sqlite3" "${temp_dir}/db.sqlite3"; then
        error "数据库复制失败"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # 验证文件
    local db_size=$(stat -c%s "${temp_dir}/db.sqlite3" 2>/dev/null || echo "0")
    if [[ $db_size -lt 1000 ]]; then
        error "数据库文件太小或为空: $db_size 字节"
        rm -rf "$temp_dir"
        return 1
    fi
    
    success "数据库备份完成: $((db_size/1024)) KB"
    
    # 复制相关文件
    docker cp "${CONTAINER_NAME}:/data/db.sqlite3-wal" "${temp_dir}/db.sqlite3-wal" 2>/dev/null
    docker cp "${CONTAINER_NAME}:/data/db.sqlite3-shm" "${temp_dir}/db.sqlite3-shm" 2>/dev/null
    
    echo "$temp_dir"
}

# 备份附件
backup_attachments() {
    log "备份附件..."
    
    # 检查容器内附件
    if docker exec "$CONTAINER_NAME" ls /data/attachments >/dev/null 2>&1; then
        local temp_dir="/tmp/attachments_$(date +%s)"
        mkdir -p "$temp_dir"
        
        docker cp "${CONTAINER_NAME}:/data/attachments" "${temp_dir}/" 2>/dev/null
        if [[ -d "${temp_dir}/attachments" ]]; then
            local count=$(find "${temp_dir}/attachments" -type f 2>/dev/null | wc -l)
            log "附件复制完成: $count 个文件"
            echo "$temp_dir"
            return 0
        fi
        rm -rf "$temp_dir"
    fi
    
    # 检查宿主机附件
    if [[ -d "/opt/bitwarden/attachments" ]]; then
        local count=$(find "/opt/bitwarden/attachments" -type f 2>/dev/null | wc -l)
        log "使用宿主机附件目录: $count 个文件"
        echo "/opt/bitwarden/attachments"
        return 0
    fi
    
    log "未找到附件"
    echo ""
}

# 创建备份包
create_backup_package() {
    local db_dir="$1"
    local attachments_dir="$2"
    
    log "创建备份包..."
    
    # 创建备份目录
    mkdir -p "$BACKUP_DIR"
    
    # 生成时间戳
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="$BACKUP_DIR/bitwarden_backup_${timestamp}.tar.gz"
    
    # 临时工作目录
    local work_dir="/tmp/backup_work_$(date +%s)"
    mkdir -p "$work_dir"
    
    # 复制数据库文件
    if [[ -d "$db_dir" ]]; then
        cp -r "$db_dir"/* "$work_dir/" 2>/dev/null
    fi
    
    # 处理附件
    if [[ -n "$attachments_dir" ]]; then
        if [[ -d "$attachments_dir" ]]; then
            tar -czf "$work_dir/attachments.tar.gz" -C "$attachments_dir" . 2>/dev/null
        fi
    fi
    
    # 添加备份信息
    cat > "$work_dir/backup_info.txt" << INFO
备份时间: $(date)
容器: $CONTAINER_NAME
数据库版本: $(date -r "$work_dir/db.sqlite3" 2>/dev/null || echo "未知")
备份类型: 完整备份
INFO
    
    # 创建tar包
    cd "$work_dir"
    tar -czf "$backup_file" . 2>/dev/null
    
    # 清理
    rm -rf "$work_dir" "$db_dir"
    if [[ "$attachments_dir" != "/opt/bitwarden/attachments" ]] && [[ -d "$attachments_dir" ]]; then
        rm -rf "$attachments_dir"
    fi
    
    # 验证备份包
    local backup_size=$(stat -c%s "$backup_file" 2>/dev/null || echo "0")
    if [[ $backup_size -gt 1000 ]]; then
        success "备份包创建完成: $(basename "$backup_file") ($((backup_size/1024/1024)) MB)"
        echo "$backup_file"
    else
        error "备份包创建失败 (大小: $backup_size 字节)"
        echo ""
    fi
}

# 上传到Worker
upload_to_worker() {
    local file_path="$1"
    local worker_url="$2"
    local api_token="$3"
    local description="$4"
    
    if [[ ! -f "$file_path" ]]; then
        error "文件不存在: $file_path"
        return 1
    fi
    
    local filename=$(basename "$file_path")
    local file_size=$(stat -c%s "$file_path")
    local remote_name="$filename"
    
    log "上传到 $description..."
    log "文件: $filename ($((file_size/1024/1024)) MB)"
    
    local response=$(curl -s -w "\n%{http_code}" -X PUT \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"$file_path" \
        "${worker_url}/upload?filename=${remote_name}" 2>&1)
    
    local http_code=$(echo "$response" | tail -1)
    local response_body=$(echo "$response" | sed '$d')
    
    if [[ "$http_code" == "200" ]] && echo "$response_body" | grep -q '"success":true'; then
        success "$description 上传成功"
        return 0
    else
        error "$description 上传失败 (HTTP $http_code)"
        log "错误响应: $response_body"
        return 1
    fi
}

# 清理旧备份
cleanup_old_backups() {
    log "清理超过${RETENTION_DAYS}天的旧备份..."
    
    if [[ -d "$BACKUP_DIR" ]]; then
        local deleted=$(find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete -print 2>/dev/null | wc -l)
        log "清理了 $deleted 个旧备份文件"
    fi
}

# 主备份函数
main_backup() {
    echo "========================================"
    echo "    Bitwarden双Worker备份"
    echo "========================================"
    echo ""
    
    # 检查容器
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        error "容器未运行: $CONTAINER_NAME"
        return 1
    fi
    success "容器运行正常"
    
    # 检查Worker
    local main_worker_ok=0
    local second_worker_ok=0
    
    if [[ -n "$WORKER_URL_1" ]] && [[ -n "$WORKER_TOKEN_1" ]]; then
        check_worker "$WORKER_URL_1" "$WORKER_TOKEN_1" "主Worker" && main_worker_ok=1
    else
        error "主Worker配置不完整"
    fi
    
    if [[ -n "$WORKER_URL_2" ]] && [[ -n "$WORKER_TOKEN_2" ]]; then
        check_worker "$WORKER_URL_2" "$WORKER_TOKEN_2" "备份Worker" && second_worker_ok=1
    else
        log "备份Worker未配置，跳过"
    fi
    
    if [[ $main_worker_ok -eq 0 ]] && [[ $second_worker_ok -eq 0 ]]; then
        error "所有Worker都不可用"
        return 1
    fi
    
    # 1. 备份数据库
    log "步骤1: 备份数据库"
    local db_dir=$(backup_database)
    if [[ -z "$db_dir" ]]; then
        error "数据库备份失败"
        return 1
    fi
    
    # 2. 备份附件
    log "步骤2: 备份附件"
    local attachments_dir=$(backup_attachments)
    
    # 3. 创建备份包
    log "步骤3: 创建备份包"
    local backup_file=$(create_backup_package "$db_dir" "$attachments_dir")
    if [[ -z "$backup_file" ]]; then
        error "备份包创建失败"
        return 1
    fi
    
    local backup_size=$(stat -c%s "$backup_file")
    
    # 4. 上传到Worker
    log "步骤4: 上传备份"
    local upload_results=()
    
    if [[ $main_worker_ok -eq 1 ]]; then
        upload_to_worker "$backup_file" "$WORKER_URL_1" "$WORKER_TOKEN_1" "主Worker"
        upload_results+=($?)
    fi
    
    if [[ $second_worker_ok -eq 1 ]]; then
        upload_to_worker "$backup_file" "$WORKER_URL_2" "$WORKER_TOKEN_2" "备份Worker"
        upload_results+=($?)
    fi
    
    # 5. 清理
    cleanup_old_backups
    
    # 检查上传结果
    local success_count=0
    for result in "${upload_results[@]}"; do
        if [[ $result -eq 0 ]]; then
            ((success_count++))
        fi
    done
    
    echo ""
    if [[ $success_count -gt 0 ]]; then
        success "✅ 备份完成！成功上传到 $success_count 个Worker"
        
        # 发送成功通知
        local message="📦 Bitwarden备份完成\n"
        message+="时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
        message+="文件: $(basename "$backup_file")\n"
        message+="大小: $((backup_size/1024/1024)) MB\n"
        message+="状态: 成功上传到 $success_count 个Worker\n"
        message+="本地保留: $RETENTION_DAYS 天"
        
        send_notification "$message"
    else
        error "❌ 备份创建成功但上传失败"
        
        # 发送失败通知
        local message="❌ Bitwarden备份失败\n"
        message+="时间: $(date '+%Y-%m-%d %H:%M:%S')\n"
        message+="错误: 所有Worker上传失败\n"
        message+="请检查Worker配置和网络连接"
        
        send_notification "$message"
    fi
    
    log "本地备份: $backup_file"
    return $((success_count > 0 ? 0 : 1))
}

# 列出备份
list_backups() {
    echo "=== 本地备份 ==="
    ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "暂无备份"
    
    echo ""
    echo "=== Worker备份列表 ==="
    
    # 主Worker
    if [[ -n "$WORKER_URL_1" ]] && [[ -n "$WORKER_TOKEN_1" ]]; then
        echo "主Worker备份:"
        curl -s -H "Authorization: Bearer $WORKER_TOKEN_1" "${WORKER_URL_1}/list" 2>/dev/null | \
            grep -o '"key":"[^"]*"' | cut -d'"' -f4 | grep -i backup | sort
        echo ""
    fi
    
    # 备份Worker
    if [[ -n "$WORKER_URL_2" ]] && [[ -n "$WORKER_TOKEN_2" ]]; then
        echo "备份Worker备份:"
        curl -s -H "Authorization: Bearer $WORKER_TOKEN_2" "${WORKER_URL_2}/list" 2>/dev/null | \
            grep -o '"key":"[^"]*"' | cut -d'"' -f4 | grep -i backup | sort
    fi
}

# 测试Worker连接
test_workers() {
    echo "=== 测试Worker连接 ==="
    echo ""
    
    if [[ -n "$WORKER_URL_1" ]] && [[ -n "$WORKER_TOKEN_1" ]]; then
        echo "测试主Worker..."
        check_worker "$WORKER_URL_1" "$WORKER_TOKEN_1" "主Worker"
        echo ""
    fi
    
    if [[ -n "$WORKER_URL_2" ]] && [[ -n "$WORKER_TOKEN_2" ]]; then
        echo "测试备份Worker..."
        check_worker "$WORKER_URL_2" "$WORKER_TOKEN_2" "备份Worker"
        echo ""
    fi
    
    echo "测试上传小文件..."
    TEST_FILE="/tmp/test_upload_$(date +%s).txt"
    echo "Worker测试文件 - $(date)" > "$TEST_FILE"
    
    if [[ -n "$WORKER_URL_1" ]] && [[ -n "$WORKER_TOKEN_1" ]]; then
        echo "上传到主Worker..."
        upload_to_worker "$TEST_FILE" "$WORKER_URL_1" "$WORKER_TOKEN_1" "主Worker测试"
        echo ""
    fi
    
    rm -f "$TEST_FILE"
}

# 主程序
case "${1:-}" in
    backup)
        main_backup
        ;;
    list)
        list_backups
        ;;
    test)
        test_workers
        ;;
    *)
        echo "用法: $0 <命令>"
        echo ""
        echo "命令:"
        echo "  backup    执行备份"
        echo "  list      列出备份"
        echo "  test      测试Worker连接"
        echo ""
        echo "配置:"
        echo "  配置文件: /opt/bitwarden/config.env"
        echo "  备份目录: $BACKUP_DIR"
        echo "  容器名称: $CONTAINER_NAME"
        ;;
esac
BACKUP_WORKER_EOF

    chmod +x /opt/bitwarden/scripts/backup_to_workers.sh
    
    # 创建主备份脚本（兼容旧调用）
    cat > /opt/bitwarden/backup.sh << 'MAIN_BACKUP_EOF'
#!/bin/bash
# 主备份脚本 - 调用Worker备份脚本

/opt/bitwarden/scripts/backup_to_workers.sh backup
MAIN_BACKUP_EOF

    chmod +x /opt/bitwarden/backup.sh
}

# ============================================
# 创建管理脚本（更新版）
# ============================================
create_management_script() {
    log "创建管理脚本..."
    
    cat > /opt/bitwarden/manage.sh << 'MANAGE_EOF'
#!/bin/bash

show_menu() {
    clear
    echo "========================================"
    echo "    Bitwarden管理面板 - Worker备份版"
    echo "========================================"
    echo ""
    echo "1) 启动服务"
    echo "2) 停止服务"
    echo "3) 重启服务"
    echo "4) 查看状态"
    echo "5) 查看日志"
    echo "6) 手动备份"
    echo "7) 测试通知"
    echo "8) 测试Worker连接"
    echo "9) 列出备份"
    echo "10) 更新服务"
    echo "11) 卸载服务"
    echo "12) IPv6诊断"
    echo "13) 查看Worker指南"
    echo "14) 退出"
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

# IPv6诊断功能
ipv6_diagnose() {
    echo "=== IPv6连接诊断 ==="
    echo ""
    
    # 加载配置
    if [[ -f "/opt/bitwarden/config.env" ]]; then
        source /opt/bitwarden/config.env 2>/dev/null || true
    fi
    
    echo "1. 系统IPv6信息:"
    echo "   IPv6地址: $(ip -6 addr show | grep inet6 | grep global | head -1 | awk '{print $2}' | cut -d'/' -f1 2>/dev/null || echo '未检测到')"
    echo ""
    
    echo "2. 服务状态:"
    cd /opt/bitwarden 2>/dev/null && docker-compose ps 2>/dev/null || echo "服务未运行"
    echo ""
    
    echo "3. 端口监听:"
    echo "   HTTP端口 ($HTTP_PORT): $(netstat -tln | grep ":$HTTP_PORT " || echo '未监听')"
    echo "   HTTPS端口 ($HTTPS_PORT): $(netstat -tln | grep ":$HTTPS_PORT " || echo '未监听')"
    echo "   IPv6 HTTPS端口: $(netstat -tln6 | grep ":$HTTPS_PORT " || echo '未监听')"
    echo ""
    
    echo "4. DNS解析测试:"
    nslookup $DOMAIN 2>&1 | grep -A2 "Address:"
    echo ""
    
    echo "5. 连接测试:"
    echo "   HTTP测试: $(curl -s -o /dev/null -w "%{http_code}" -I http://$DOMAIN:$HTTP_PORT 2>/dev/null || echo '失败')"
    echo "   HTTPS测试: $(curl -s -k -o /dev/null -w "%{http_code}" -I https://$DOMAIN:$HTTPS_PORT 2>/dev/null || echo '失败')"
    echo "   IPv6 HTTPS测试: $(curl -6 -s -k -o /dev/null -w "%{http_code}" -I https://$DOMAIN:$HTTPS_PORT 2>/dev/null || echo '失败')"
    echo ""
    
    if [[ "$IP_VERSION" == "ipv6" ]]; then
        echo "6. IPv6专用建议:"
        echo "   • 确保域名正确解析到IPv6地址"
        echo "   • 检查防火墙是否开放IPv6端口"
        echo "   • 如果使用Cloudflare，请关闭代理（灰色云）"
        echo "   • 运行: curl -6 -v -k https://$DOMAIN:$HTTPS_PORT 查看详细错误"
    fi
    echo ""
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
    read -p "请选择 (1-14): " choice
    
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
            echo "测试Worker连接..."
            /opt/bitwarden/scripts/backup_to_workers.sh test
            ;;
        9)
            echo "列出备份..."
            /opt/bitwarden/scripts/backup_to_workers.sh list
            ;;
        10)
            cd /opt/bitwarden 2>/dev/null || { echo "目录不存在"; break; }
            docker-compose pull
            docker-compose down
            docker-compose up -d
            echo "服务已更新"
            ;;
        11)
            uninstall_service
            ;;
        12)
            ipv6_diagnose
            ;;
        13)
            echo "Worker部署指南:"
            echo "文件位置: /opt/bitwarden/scripts/deploy_worker.md"
            echo ""
            echo "快速查看:"
            head -50 /opt/bitwarden/scripts/deploy_worker.md
            echo ""
            echo "... (更多内容请查看完整文件)"
            ;;
        14)
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

# ============================================
# 创建恢复脚本（更新版）
# ============================================
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
    echo "没有找到本地备份文件"
    echo ""
    echo "你可以从Worker恢复:"
    echo "1. 运行: bw-manage"
    echo "2. 选择'列出备份'查看Worker中的备份"
    echo "3. 手动从Worker下载备份文件到: $BACKUP_DIR"
    exit 1
fi

echo "可用的本地备份文件:"
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
echo "- IP版本: ${IP_VERSION:-ipv4}"
echo ""
echo "Worker备份配置:"
echo "- 主Worker: ${WORKER_URL_1:-未配置}"
echo "- 备份Worker: ${WORKER_URL_2:-未配置}"
RESTORE_EOF
    
    chmod +x /opt/bitwarden/restore.sh
}

# 设置定时任务
setup_cron() {
    log "设置定时备份..."
    echo "0 2 * * * /opt/bitwarden/backup.sh >> /var/log/bitwarden_backup.log 2>&1" >> /etc/crontab
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
    echo "• IP版本: ${IP_VERSION:-ipv4}"
    echo ""
    
    if [ "$IP_VERSION" = "ipv6" ]; then
        echo "🔧 IPv6配置已启用:"
        echo "• 已应用IPv6优化配置"
        echo "• 支持IPv6直接访问"
        echo "• 如需诊断IPv6连接，请在管理面板选择'IPv6诊断'"
        echo ""
    fi
    
    echo "🔧 Worker备份配置:"
    echo "• 主Worker: ${WORKER_URL_1:-未配置}"
    if [[ -n "$WORKER_URL_2" ]]; then
        echo "• 备份Worker: $WORKER_URL_2"
    fi
    echo ""
    
    echo "🔧 管理命令:"
    echo "• bw-manage              - 管理面板"
    echo "• /opt/bitwarden/backup.sh  - 手动备份"
    echo "• /opt/bitwarden/restore.sh - 恢复备份"
    echo ""
    
    echo "📅 自动备份:"
    echo "• 每天凌晨2点自动执行"
    echo "• 备份到Cloudflare Worker (R2存储)"
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
    echo "3. 建议立即测试备份功能: bw-manage → 测试Worker连接"
    echo "4. 如果使用非标准端口，请确保防火墙已开放相应端口"
    if [ "$IP_VERSION" = "ipv6" ]; then
        echo "5. IPv6用户请确保域名正确解析到IPv6地址"
        echo "6. 如果使用Cloudflare，请关闭代理（灰色云）"
    fi
    echo "7. Worker部署指南: /opt/bitwarden/scripts/deploy_worker.md"
    echo ""
    
    echo "运行 'bw-manage' 开始管理您的Bitwarden服务"
}

# 主安装流程
main_install() {
    clear
    echo "========================================"
    echo "    Bitwarden一键安装脚本"
    echo "      Worker备份版 (IPv6兼容)"
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
    
    # 创建Worker备份脚本
    create_worker_backup_script
    
    # 创建Worker部署指南
    create_worker_guide
    
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
    create_worker_backup_script
    create_worker_guide
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
        echo "      Worker备份版 (IPv6兼容)"
        echo "========================================"
        echo ""
        echo "请选择模式:"
        echo "1) 全新安装"
        echo "2) 恢复安装"
        echo "3) IPv6快速修复"
        echo "4) 退出"
        echo ""
        
        read -p "请选择 (1-4): " mode
        
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
                ipv6_quick_fix
                break
                ;;
            4)
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

# IPv6快速修复功能
ipv6_quick_fix() {
    echo "=== IPv6快速修复 ==="
    echo ""
    
    # 检查是否在bitwarden目录
    if [[ ! -f "/opt/bitwarden/docker-compose.yml" ]]; then
        echo "未找到Bitwarden安装目录"
        echo "请先运行全新安装"
        exit 1
    fi
    
    cd /opt/bitwarden
    
    # 检查当前配置
    if [[ -f "config.env" ]]; then
        source config.env 2>/dev/null || true
    fi
    
    echo "当前配置:"
    echo "• 域名: ${DOMAIN:-未设置}"
    echo "• IP版本: ${IP_VERSION:-ipv4}"
    echo "• HTTP端口: ${HTTP_PORT:-80}"
    echo "• HTTPS端口: ${HTTPS_PORT:-443}"
    echo ""
    
    read -p "是否将IP版本改为IPv6？(y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "取消修复"
        return
    fi
    
    # 备份原配置
    BACKUP_DIR="backup_ipv6_fix_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp config/Caddyfile "$BACKUP_DIR/" 2>/dev/null || true
    cp config.env "$BACKUP_DIR/" 2>/dev/null || true
    
    # 更新配置
    sed -i 's/IP_VERSION=".*"/IP_VERSION="ipv6"/' config.env 2>/dev/null || \
        echo 'IP_VERSION="ipv6"' >> config.env
    
    # 停止服务
    echo "停止服务..."
    docker-compose down 2>/dev/null || true
    
    # 创建IPv6优化的Caddyfile
    echo "创建IPv6优化配置..."
    cat > config/Caddyfile << IPV6_FIX_EOF
{
    email ${EMAIL:-admin@example.com}
    admin off
}

# HTTP自动重定向到HTTPS（IPv6兼容）
${DOMAIN:-bitwarden.example.com}:${HTTP_PORT:-80} {
    bind [::]:${HTTP_PORT:-80}
    redir https://{host}{uri} permanent
}

# HTTPS主站点（IPv6兼容）
${DOMAIN:-bitwarden.example.com}:${HTTPS_PORT:-443} {
    bind [::]:${HTTPS_PORT:-443}
    encode gzip
    
    # IPv6优化配置
    reverse_proxy vaultwarden:80 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
        header_up X-Forwarded-Proto {scheme}
    }
    
    # WebSocket支持
    handle_path /notifications/hub {
        reverse_proxy vaultwarden:3012 {
            header_up Host {host}
            header_up X-Real-IP {remote}
            header_up X-Forwarded-For {remote}
            header_up X-Forwarded-Proto {scheme}
            header_up Upgrade {http.upgrade}
            header_up Connection {http.request.header.Connection}
        }
    }
    
    handle_path /notifications/hub/negotiate {
        reverse_proxy vaultwarden:80 {
            header_up Host {host}
            header_up X-Real-IP {remote}
            header_up X-Forwarded-For {remote}
            header_up X-Forwarded-Proto {scheme}
        }
    }
    
    # 安全头
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        -Server
    }
}
IPV6_FIX_EOF
    
    # 启动服务
    echo "启动服务..."
    docker-compose up -d
    
    echo ""
    echo "✅ IPv6修复完成！"
    echo ""
    echo "配置已备份到: $BACKUP_DIR"
    echo "IP版本已改为: ipv6"
    echo ""
    echo "测试命令:"
    echo "1. 检查服务状态: docker-compose ps"
    echo "2. 查看Caddy日志: docker-compose logs caddy --tail=20"
    echo "3. 测试IPv6访问: curl -6 -k -I https://${DOMAIN:-你的域名}:${HTTPS_PORT:-443}"
    echo ""
    echo "如果仍有问题，请运行: bw-manage 然后选择'IPv6诊断'"
}

# 直接运行安装
if [[ "$1" == "--install" ]]; then
    main_install
elif [[ "$1" == "--restore" ]]; then
    restore_mode
elif [[ "$1" == "--fix-ipv6" ]]; then
    ipv6_quick_fix
else
    main_menu
fi
