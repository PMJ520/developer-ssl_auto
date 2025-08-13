#!/bin/bash

echo "===  SSL 自动申请脚本 ==="
echo "=== 本脚本通过 Let's Encrypt申请,会自动安装安装acme.sh ==="

# === 1. 输入域名 ===
read -p "请输入你的域名（如 example.com）: " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo "[×] 域名不能为空"
    exit 1
fi

# === 2. 输入根目录（证书会存储在目录/域名/）===
read -p "请输入证书根目录（如 /etc/ssl）: " ROOT_DIR
if [[ -z "$ROOT_DIR" ]]; then
    echo "[×] 路径不能为空"
    exit 1
fi

OUTPUT_DIR="${ROOT_DIR%/}/$DOMAIN"
mkdir -p "$OUTPUT_DIR"

# === 3. 验证方式 ===
echo "请选择验证方式:"
echo "1) standalone（用于无Web服务场景,自动监听 80 端口）"
echo "2) webroot（用于已有Web服务场景,需已部署网站）"
read -p "输入选项数字（默认 1）: " MODE_CHOICE

if [[ "$MODE_CHOICE" == "2" ]]; then
    MODE="webroot"
    read -p "请输入网站根目录路径（如 /var/www/html）: " WEBROOT
    if [[ -z "$WEBROOT" ]]; then
        echo "[×] webroot 模式必须提供网站路径"
        exit 1
    fi
else
    MODE="standalone"
fi

# === 4. 自动重载 nginx ===
read -p "是否启用续期后自动 reload nginx？(y/N): " NGINX_RELOAD
if [[ "$NGINX_RELOAD" == "y" || "$NGINX_RELOAD" == "Y" ]]; then
    RELOAD="true"
else
    RELOAD="false"
fi

# === 5. 安装 acme.sh（如果未安装）===
if [ ! -e ~/.acme.sh/acme.sh ]; then
    echo "[+] 正在安装 acme.sh ..."
    wget https://raw.githubusercontent.com/PMJ520/developer-ssl_auto/refs/heads/main/acme.sh -O ~/.acme.sh/acme.sh
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# === 6. 检查并释放 80 端口（仅 standalone）===
if [[ "$MODE" == "standalone" ]]; then
    echo "[*] 检查 80 端口占用..."
    PID=$(lsof -ti tcp:80)
    if [[ -n "$PID" ]]; then
        echo "[!] 端口被占用，尝试 kill $PID"
        kill -9 $PID
        sleep 2
    fi
fi

# === 7. 申请证书 ===
echo "[*] 申请证书中..."
if [[ "$MODE" == "webroot" ]]; then
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --webroot "$WEBROOT"
else
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
fi

if [ $? -ne 0 ]; then
    echo "[×] 证书申请失败"
    exit 1
fi

# === 8. 安装证书 ===
KEY_PATH="$OUTPUT_DIR/${DOMAIN}.key"
FULLCHAIN_PATH="$OUTPUT_DIR/${DOMAIN}.fullchain.pem"
CERT_PATH="$OUTPUT_DIR/${DOMAIN}.cert.pem"
CA_PATH="$OUTPUT_DIR/${DOMAIN}.ca.pem"

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file "$KEY_PATH" \
    --fullchain-file "$FULLCHAIN_PATH" \
    --cert-file "$CERT_PATH" \
    --ca-file "$CA_PATH" \
    $( [[ "$RELOAD" == "true" ]] && echo "--reloadcmd \"systemctl reload nginx\"" )

# === 9. 完成输出 ===
echo
echo "✅ 证书申请成功"
echo "→ 私钥:       $KEY_PATH"
echo "→ 证书链:     $FULLCHAIN_PATH"
echo "→ 证书:       $CERT_PATH"
echo "→ CA证书:     $CA_PATH"
[[ "$RELOAD" == "true" ]] && echo "→ 已配置自动 reload nginx"

echo
echo "📅 已自动设置每日自动续期任务"
