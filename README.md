# 🚀 Bitwarden一键部署脚本（Worker备份版）

## 📖 简介

这是一个全功能的Bitwarden/Vaultwarden一键部署脚本，支持IPv6、Cloudflare Worker备份、自动SSL证书和多种通知方式。

## ✨ 核心特性

### 🔒 安全备份
- **双Worker备份**：支持同时备份到两个不同的Cloudflare Worker账号
- **自动备份**：每天凌晨2点自动执行备份
- **本地保留**：本地保留7天备份文件
- **加密支持**：可选备份文件加密

### 🌐 网络支持
- **IPv6原生支持**：完整的IPv6配置优化
- **自动SSL**：使用Caddy自动申请Let's Encrypt证书
- **WebSocket支持**：实时同步通知
- **多端口配置**：灵活配置HTTP/HTTPS端口

### 🔔 通知系统
- **Telegram通知**：备份成功/失败通知
- **邮件通知**：支持SMTP邮件通知
- **双通知模式**：可同时启用两种通知方式

### 🛠️ 管理功能
- **Web管理面板**：通过`bw-manage`命令管理
- **一键恢复**：支持从备份快速恢复
- **健康检查**：服务状态监控
- **日志查看**：实时查看服务日志

## 📋 系统要求

- **操作系统**：Ubuntu 20.04+ / Debian 10+
- **内存**：1GB+ RAM
- **存储**：10GB+ 可用空间
- **网络**：公网IP（IPv4/IPv6均可）
- **域名**：需要有效的域名
- **Cloudflare账户**：用于Worker和R2存储

## 🚀 快速开始

### 1. 下载脚本
```bash
wget -O setup.sh https://raw.githubusercontent.com/your-repo/bitwarden-worker-backup/main/setup.sh
chmod +x setup.sh
```

### 2. 运行安装
```bash
./setup.sh
```

### 3. 选择安装模式
```
请选择模式:
1) 全新安装
2) 恢复安装
3) IPv6快速修复
4) 退出
```

## 🔧 配置说明

### 必需配置
- **域名**：用于SSL证书和访问
- **邮箱**：用于SSL证书申请
- **Worker配置**：至少一个Cloudflare Worker

### 可选配置
- **端口配置**：自定义HTTP/HTTPS端口
- **通知方式**：Telegram/邮件通知
- **第二个Worker**：备份到另一个账号
- **IP版本**：IPv4或IPv6优先

## 📁 目录结构
```
/opt/bitwarden/
├── data/                    # 数据库和附件
├── backups/                 # 本地备份文件
├── config/                  # 配置文件
│   ├── config.env          # 主配置文件
│   ├── Caddyfile           # 反向代理配置
│   └── vaultwarden.env     # Vaultwarden环境变量
├── scripts/                 # 脚本目录
│   ├── backup_to_workers.sh # Worker备份脚本
│   └── deploy_worker.md    # Worker部署指南
├── docker-compose.yml      # Docker编排文件
├── backup.sh               # 主备份脚本
├── restore.sh              # 恢复脚本
└── manage.sh               # 管理脚本
```

## 🔄 备份系统

### Worker部署步骤

#### 步骤1：准备Cloudflare账户
1. 访问 [Cloudflare Dashboard](https://dash.cloudflare.com)
2. 确保账户已激活（免费账户即可）
3. 准备一个域名（可以不是你要部署Bitwarden的域名）

#### 步骤2：创建R2存储桶
1. 左侧菜单点击 **"R2"**
2. 点击 **"Create bucket"**
3. 输入Bucket名称：`bitwarden-backups`
4. 选择区域（建议选择离你近的区域）
5. 点击 **"Create bucket"**

#### 步骤3：创建Worker
1. 左侧菜单点击 **"Workers & Pages"**
2. 点击 **"Create application"**
3. 选择 **"Create Worker"**
4. 输入Worker名称：`bitwarden-backup-worker`
5. 点击 **"Create Worker"**

#### 步骤4：配置Worker代码
1. 删除默认代码
2. 复制以下代码粘贴到编辑器中：

```javascript
// Bitwarden备份上传Worker
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    
    // CORS头
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    };
    
    // 处理OPTIONS请求
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders });
    }
    
    // 健康检查不需要认证
    if (path === '/health' && request.method === 'GET') {
      return new Response(JSON.stringify({
        status: 'ok',
        service: 'Bitwarden Backup Worker',
        timestamp: new Date().toISOString(),
      }), {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    
    // 其他端点需要认证
    const authHeader = request.headers.get('Authorization');
    const API_TOKEN = env.API_TOKEN || 'bitwarden-backup-secret';
    
    if (!authHeader || authHeader !== `Bearer ${API_TOKEN}`) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }
    
    // 直接上传端点
    if (path === '/upload' && request.method === 'PUT') {
      try {
        const filename = url.searchParams.get('filename') || `backup_${Date.now()}.tar.gz`;
        
        // 保存到R2
        await env.BITWARDEN_BUCKET.put(filename, request.body, {
          httpMetadata: { contentType: 'application/octet-stream' },
        });
        
        return new Response(JSON.stringify({
          success: true,
          filename: filename,
          message: 'File uploaded successfully',
          size: request.headers.get('Content-Length'),
          uploaded: new Date().toISOString()
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
        
      } catch (error) {
        return new Response(JSON.stringify({ 
          error: error.message
        }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }
    
    // 列出文件
    if (path === '/list' && request.method === 'GET') {
      try {
        const list = await env.BITWARDEN_BUCKET.list();
        
        return new Response(JSON.stringify({
          success: true,
          files: list.objects.map(obj => ({
            key: obj.key,
            size: obj.size,
            uploaded: obj.uploaded,
          })),
          count: list.objects.length
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
        
      } catch (error) {
        return new Response(JSON.stringify({ 
          error: error.message
        }), {
          status: 500,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        });
      }
    }
    
    // 默认响应
    return new Response(JSON.stringify({
      message: 'Bitwarden Backup Worker',
      endpoints: {
        healthCheck: 'GET /health (无需认证)',
        upload: 'PUT /upload?filename=xxx (需要认证)',
        list: 'GET /list (需要认证)',
      },
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  },
};
```

#### 步骤5：配置Worker环境变量
1. 点击 **"Settings"** 标签
2. 点击 **"Variables"**
3. 添加环境变量：
   - **Variable name**: `API_TOKEN`
   - **Value**: 生成一个强密码（如：`bw-backup-$(openssl rand -hex 16)`）
   - 点击 **"Add variable"**

#### 步骤6：绑定R2存储桶
1. 在 **"Resources"** 部分
2. 找到 **"R2 Buckets"**
3. 点击 **"Add binding"**
4. 配置：
   - **Variable name**: `BITWARDEN_BUCKET`
   - **R2 Bucket**: 选择刚才创建的 `bitwarden-backups`
   - 点击 **"Save"**

#### 步骤7：保存并部署
1. 点击右上角 **"Save and deploy"**
2. 等待部署完成
3. 记下Worker URL（格式：`https://bitwarden-backup-worker.你的用户名.workers.dev`）

#### 步骤8：测试Worker
```bash
# 测试健康检查（无需认证）
curl https://bitwarden-backup-worker.你的用户名.workers.dev/health

# 测试上传（需要认证）
curl -X PUT \
  -H "Authorization: Bearer 你的API_TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @test.txt \
  "https://bitwarden-backup-worker.你的用户名.workers.dev/upload?filename=test.txt"
```

### 备份流程
1. **数据库备份**：导出SQLite数据库
2. **附件备份**：打包附件文件
3. **创建备份包**：压缩为tar.gz文件
4. **上传到Worker**：使用预签名URL上传到R2
5. **清理旧备份**：删除超过7天的本地备份

## 📊 管理命令

### 主管理命令
```bash
bw-manage
```

### 常用操作
```bash
# 手动备份
/opt/bitwarden/backup.sh

# 恢复备份
/opt/bitwarden/restore.sh

# 测试Worker连接
/opt/bitwarden/scripts/backup_to_workers.sh test

# 列出备份
/opt/bitwarden/scripts/backup_to_workers.sh list
```

## 🌐 访问地址

安装完成后，通过以下地址访问：
- **主地址**：`https://你的域名`
- **管理面板**：运行 `bw-manage`
- **备份状态**：查看 `/var/log/bitwarden_backup.log`

## 🔧 故障排除

### 常见问题

#### 1. Worker创建失败
```bash
# 检查Cloudflare账户状态
# 确保有足够的免费额度
# 检查R2存储桶是否创建成功
```

#### 2. Worker上传失败
```bash
# 测试Worker连接
/opt/bitwarden/scripts/backup_to_workers.sh test

# 检查API Token是否正确
# 检查R2绑定是否正确
```

#### 3. IPv6无法访问
```bash
# 运行IPv6诊断
bw-manage
# 选择"IPv6诊断"
```

#### 4. SSL证书问题
```bash
# 查看Caddy日志
docker-compose logs caddy
```

#### 5. 备份失败
```bash
# 测试Worker连接
/opt/bitwarden/scripts/backup_to_workers.sh test

# 查看备份日志
tail -f /var/log/bitwarden_backup.log
```

#### 6. 服务无法启动
```bash
# 查看服务状态
docker-compose ps

# 查看详细日志
docker-compose logs
```

### 日志位置
- **服务日志**：`docker-compose logs`
- **备份日志**：`/var/log/bitwarden_backup.log`
- **访问日志**：`/opt/bitwarden/caddy_data/access.log`

## 🔐 安全建议

1. **定期更新**：定期运行 `bw-manage` → "更新服务"
2. **监控备份**：确保备份正常执行
3. **强密码**：使用强管理令牌
4. **防火墙**：仅开放必要端口
5. **定期恢复测试**：测试备份文件可恢复性
6. **Worker安全**：
   - 定期更换API Token
   - 限制Worker访问IP（可选）
   - 监控R2存储使用量

## 📞 支持

### 文档
- **详细文档**：查看脚本内的注释
- **Worker指南**：`/opt/bitwarden/scripts/deploy_worker.md`
- **配置说明**：`/opt/bitwarden/config.env`

### 问题反馈
1. 查看日志文件
2. 运行诊断命令
3. 检查网络连接
4. 验证域名解析
5. 检查Worker配置

## 📄 许可证

MIT License

## 🙏 致谢

- [Vaultwarden](https://github.com/dani-garcia/vaultwarden) - Bitwarden兼容服务器
- [Caddy](https://caddyserver.com/) - 自动HTTPS反向代理
- [Cloudflare Workers](https://workers.cloudflare.com/) - 无服务器计算平台
- [Cloudflare R2](https://www.cloudflare.com/products/r2/) - 对象存储服务

## 🔄 更新日志

### v2.0.0 (2024)
- ✅ 新增Worker备份系统
- ✅ 支持双Worker备份
- ✅ 增强IPv6支持
- ✅ 改进管理面板
- ✅ 添加Worker部署指南
- ✅ 详细Worker创建步骤

### v1.0.0 (2023)
- ✅ 基础安装功能
- ✅ R2直接备份
- ✅ 基础通知系统
- ✅ IPv4/IPv6支持

---

## 🎯 快速检查清单

### 安装前准备
- [ ] Cloudflare账户已激活
- [ ] 域名已准备
- [ ] 服务器有公网IP
- [ ] 防火墙已开放端口

### Worker配置
- [ ] R2存储桶已创建
- [ ] Worker已部署
- [ ] API Token已生成
- [ ] Worker URL已记录

### 安装后验证
- [ ] 服务正常启动
- [ ] SSL证书已签发
- [ ] 可以访问Web界面
- [ ] 备份测试成功

**提示**：安装前请确保已准备好域名和Cloudflare Worker配置。如需帮助，请查看详细的Worker部署指南。
