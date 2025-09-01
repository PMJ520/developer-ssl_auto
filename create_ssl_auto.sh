#!/usr/bin/env bash
set -euo pipefail

# ============== 样式 ==============
C0="\033[0m"; C1="\033[1;36m"; C2="\033[1;32m"; C3="\033[1;33m"; C4="\033[1;31m"
ok(){ echo -e "${C2}[✓]${C0} $*"; }
info(){ echo -e "${C1}[i]${C0} $*"; }
warn(){ echo -e "${C3}[!]${C0} $*"; }
err(){ echo -e "${C4}[x]${C0} $*"; }

trap 'err "脚本异常中止（行号 $LINENO）"' ERR

echo -e "${C1}=== Let's Encrypt SSL 自动申请脚本（基于 acme.sh） ===${C0}"

# ============== 1. 输入域名 ==============
read -rp "请输入你的域名（如 example.com）: " DOMAIN
[[ -n "${DOMAIN}" ]] || { err "域名不能为空"; exit 1; }

# ============== 2. 输入证书根目录（默认 /etc/ssl） ==============
read -rp "请输入证书根目录（默认 /etc/ssl）: " ROOT_DIR
ROOT_DIR="${ROOT_DIR:-/etc/ssl}"
OUTPUT_DIR="${ROOT_DIR%/}/${DOMAIN}"
info "证书将存放在: ${OUTPUT_DIR}"

# ============== 3. 选择验证方式（webroot 默认路径） ==============
echo "请选择验证方式："
echo "1) standalone（自动监听80端口，需要root）"
echo "2) webroot（已运行的网站根目录验证）"
read -rp "输入选项数字（默认 1）: " MODE_CHOICE
if [[ "${MODE_CHOICE:-1}" == "2" ]]; then
  MODE="webroot"
  read -rp "请输入网站根目录路径（默认 /usr/share/nginx/html）: " WEBROOT
  WEBROOT="${WEBROOT:-/usr/share/nginx/html}"
  [[ -n "${WEBROOT}" ]] || { err "webroot 模式必须提供网站根目录"; exit 1; }
else
  MODE="standalone"
fi

# ============== 4. 是否自动 reload nginx（默认 y） ==============
read -rp "是否启用续期后自动 reload nginx？(Y/n 默认y): " NGINX_RELOAD
if [[ "${NGINX_RELOAD:-Y}" =~ ^[Yy]$ ]]; then
  RELOAD="true"
else
  RELOAD="false"
fi


# ============== 5. 证书类型 ECC / RSA（保持全流程一致） ==============
echo "选择证书类型："
echo "1) ECC（推荐，默认 ec-256）"
echo "2) RSA（默认 2048）"
read -rp "输入选项数字（默认 1）: " CT_CHOICE
if [[ "${CT_CHOICE:-1}" == "2" ]]; then
  CERT_TYPE="rsa"; ACME_FLAG=""; KEYLEN_FLAG="--keylength 2048"
else
  CERT_TYPE="ecc"; ACME_FLAG="--ecc"; KEYLEN_FLAG="--keylength ec-256"
fi
info "使用证书类型：${CERT_TYPE}"

# 若已存在 ECC 证书目录，强制使用 ECC 保持一致（避免 install 空目录）
if [[ -d "$HOME/.acme.sh/${DOMAIN}_ecc" && "${CERT_TYPE}" != "ecc" ]]; then
  warn "检测到已存在 ECC 证书（~/.acme.sh/${DOMAIN}_ecc），自动切换为 ECC 以保持一致。"
  CERT_TYPE="ecc"; ACME_FLAG="--ecc"; KEYLEN_FLAG="--keylength ec-256"
fi

# ============== 6. 安装或准备 acme.sh ==============
ACME_BIN="$HOME/.acme.sh/acme.sh"
if [[ ! -x "$ACME_BIN" ]]; then
  info "安装 acme.sh 到 $HOME/.acme.sh ..."
  mkdir -p "$HOME/.acme.sh"
  # 你的仓库脚本；如需官方安装器可改为：curl https://get.acme.sh | sh
  wget -q https://raw.githubusercontent.com/PMJ520/developer-ssl_auto/refs/heads/main/acme.sh -O "$ACME_BIN"
  chmod +x "$ACME_BIN"
  ok "acme.sh 安装完成：$ACME_BIN"
fi

"$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null
ok "默认 CA 设置为 Let's Encrypt"

# ============== 7. standalone 模式需要 root（占80端口） ==============
if [[ "$MODE" == "standalone" && "$EUID" -ne 0 ]]; then
  err "standalone 模式需要 root（要绑定 80 端口）。请用 sudo 重新运行，或改用 webroot 模式。"
  exit 1
fi

# ============== 8. 申请证书（issue） ==============
info "开始申请证书：$DOMAIN（模式：$MODE，类型：$CERT_TYPE）"
if [[ "$MODE" == "webroot" ]]; then
  "$ACME_BIN" --issue -d "$DOMAIN" --webroot "$WEBROOT" $ACME_FLAG $KEYLEN_FLAG
else
  if command -v lsof >/dev/null 2>&1; then
    if lsof -ti tcp:80 >/dev/null 2>&1; then
      warn "检测到 80 端口被占用，请确认不会影响验证（acme.sh 会临时监听）。"
    fi
  fi
  "$ACME_BIN" --issue -d "$DOMAIN" --standalone $ACME_FLAG $KEYLEN_FLAG
fi
ok "证书申请完成"

# ============== 9. 安装证书（install-cert） ==============
KEY_PATH="$OUTPUT_DIR/${DOMAIN}.key"
FULLCHAIN_PATH="$OUTPUT_DIR/${DOMAIN}.fullchain.pem"
CERT_PATH="$OUTPUT_DIR/${DOMAIN}.cert.pem"
CA_PATH="$OUTPUT_DIR/${DOMAIN}.ca.pem"

# 创建/授权输出目录
if [[ ! -d "$OUTPUT_DIR" ]]; then
  if mkdir -p "$OUTPUT_DIR" 2>/dev/null; then :; else
    warn "$OUTPUT_DIR 无法直接创建，尝试使用 sudo ..."
    sudo mkdir -p "$OUTPUT_DIR"
    sudo chown -R "$(id -u):$(id -g)" "$OUTPUT_DIR"
  fi
fi
if [[ ! -w "$OUTPUT_DIR" ]]; then
  warn "$OUTPUT_DIR 无写权限，尝试用 sudo 授权给当前用户 ..."
  sudo chown -R "$(id -u):$(id -g)" "$OUTPUT_DIR"
fi

# 构造 reload 命令，注意正确传参避免 Unknown parameter
if [[ "${RELOAD}" == "true" ]]; then
  RELOAD_CMD="systemctl reload nginx"   # 或者 "sudo systemctl reload nginx"
else
  RELOAD_CMD=""
fi

info "安装证书到 $OUTPUT_DIR ..."
# shellcheck disable=SC2086
$ACME_BIN --install-cert -d "$DOMAIN" $ACME_FLAG \
  --key-file       "$KEY_PATH" \
  --fullchain-file "$FULLCHAIN_PATH" \
  --cert-file      "$CERT_PATH" \
  --ca-file        "$CA_PATH" \
  ${RELOAD_CMD:+--reloadcmd "$RELOAD_CMD"}

ok "证书安装完成"
echo "----------------------------------------"
echo "私钥:        $KEY_PATH"
echo "证书链:      $FULLCHAIN_PATH"
echo "证书:        $CERT_PATH"
echo "CA 证书:     $CA_PATH"
[[ "$RELOAD_CMD" ]] && echo "续期后将自动执行: $RELOAD_CMD"
echo "----------------------------------------"

# ============== 10. Nginx 提示 ==============
echo
info "Nginx 配置示例："
cat <<EOF
ssl_certificate     $FULLCHAIN_PATH;
ssl_certificate_key $KEY_PATH;
EOF

echo
ok "完成！acme.sh 会在后台通过 cron 自动续期。需要改为 RSA 时，下次运行选择 2 或导出 CERT_TYPE=rsa。"
