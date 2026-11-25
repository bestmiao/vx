#!/usr/bin/env bash
set -euo pipefail

die()  { printf '错误：%s\n' "$*" >&2; exit 1; }
warn() { printf '警告：%s\n' "$*" >&2; }
info() { printf '[*] %s\n' "$*"; }

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

is_port()   { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
is_domain() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; }
is_path()   { [[ "$1" =~ ^/[A-Za-z0-9._~/-]*$ ]] && [[ "$1" != *'..'* ]]; }
is_uuid()   { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
is_b64key() { [[ "$1" =~ ^[A-Za-z0-9+/=_-]{40,}$ ]]; }
gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi
  local hex
  hex="$(openssl rand -hex 16)"
  printf '%s-%s-4%s-8%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:17:3}" "${hex:20:12}"
}

ask() {
  local prompt="$1" default="$2" ans=""
  read -rp "$prompt" ans || true
  printf '%s' "${ans:-$default}"
}

region_to_sni() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    hk|hongkong|香港) echo "www.apple.com" ;;
    jp|japan|日本) echo "www.amazon.co.jp" ;;
    sg|singapore|新加坡) echo "www.amazon.sg" ;;
    us|usa|america|美国) echo "www.microsoft.com" ;;
    *) echo "www.microsoft.com" ;;
  esac
}
region_label() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    hk|hongkong|香港) echo "香港" ;;
    jp|japan|日本) echo "日本" ;;
    sg|singapore|新加坡) echo "新加坡" ;;
    us|usa|america|美国) echo "美国" ;;
    custom|自定义) echo "自定义" ;;
    *) echo "$1" ;;
  esac
}

ask_region() {
  local choice=""
  REGION="${REGION:-}"
  if [ -z "$REGION" ]; then
    echo "地区："
    echo "  1) 香港"
    echo "  2) 日本"
    echo "  3) 新加坡"
    echo "  4) 美国"
    echo "  5) 自定义"
    choice="$(ask "选择 [1-5，默认 4]: " "4")"
    case "$choice" in
      1) REGION="hk" ;;
      2) REGION="jp" ;;
      3) REGION="sg" ;;
      4) REGION="us" ;;
      5) REGION="custom" ;;
      hk|jp|sg|us|custom) REGION="$choice" ;;
      *) REGION="us" ;;
    esac
  fi
  if [ "$REGION" = "custom" ]; then
    REGION_SNI=""
    while [ -z "$REGION_SNI" ] || ! is_domain "$REGION_SNI"; do
      [ -n "$REGION_SNI" ] && warn "SNI 格式无效：$REGION_SNI"
      REGION_SNI="$(ask "域名: " "")"
    done
  else
    REGION_SNI="$(region_to_sni "$REGION")"
  fi
  REGION_LABEL="$(region_label "$REGION")"
}

check_port_free() {
  local port="$1" what="$2" listeners=""
  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi
  listeners="$(ss -ltnpH "sport = :$port" 2>/dev/null || true)"
  if [ -n "$listeners" ] && ! printf '%s' "$listeners" | grep -qi xray; then
    die "端口 $port 已被占用"
  fi
}

modify_node() {
  local config_file="/usr/local/etc/xray/config.json"
  local info_file="$INFO_FILE"
  [ -f "$config_file" ] || die "没有找到配置 $config_file"
  command -v jq >/dev/null 2>&1 || die "需要 jq"

  local cur_port cur_uuid cur_path cur_mode cur_sni cur_priv cur_pub cur_sid cur_cert cur_key
  local cur_split new_split split_ans
  cur_port="$(jq -r '.inbounds[0].port' "$config_file")"
  cur_uuid="$(jq -r '.inbounds[0].settings.clients[0].id' "$config_file")"
  cur_path="$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$config_file")"
  cur_mode="reality"
  if jq -e '.inbounds[0].streamSettings.security == "tls"' "$config_file" >/dev/null 2>&1; then cur_mode="tls"; fi
  if [ "$cur_mode" = "reality" ]; then
    cur_sni="$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$config_file")"
    cur_priv="$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$config_file")"
    cur_sid="$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$config_file")"
    cur_pub="$(grep -iE '^(PublicKey|公钥)' "$info_file" 2>/dev/null | awk -F'：' '{print $NF}' || true)"
  else
    cur_sni="$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$config_file")"
    cur_cert="$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$config_file")"
    cur_key="$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].keyFile' "$config_file")"
    cur_sni="$(grep -i '^SNI' "$info_file" 2>/dev/null | awk -F'：' '{print $NF}' || true)"
  fi
  cur_split=0
  if grep -q '^分流：开' "$info_file" 2>/dev/null; then cur_split=1; fi

  local cur_mode_num=1
  [ "$cur_mode" = "tls" ] && cur_mode_num=2
  echo ""
  echo "模式：$cur_mode_num"
  echo "端口：$cur_port"
  echo "UUID：$cur_uuid"
  echo "路径：$cur_path"
  echo "SNI：$cur_sni"
  if [ "$cur_split" = "1" ]; then echo "分流：开"; else echo "分流：关"; fi
  echo "空输入=保持原值"
  echo ""

  local new_port new_uuid new_path new_sni new_region
  new_port="${PORT:-}"
  if [ -z "$new_port" ]; then
    new_port="$(ask "新端口 [$cur_port]: " "$cur_port")"
  fi
  is_port "$new_port" || die "端口无效：$new_port"
  check_port_free "$new_port" "Xray"
  new_uuid="${UUID:-}"
  if [ -z "$new_uuid" ]; then
    new_uuid="$(ask "新 UUID [$cur_uuid]: " "$cur_uuid")"
  fi
  is_uuid "$new_uuid" || die "UUID 格式无效：$new_uuid"
  new_path="${XHTTP_PATH:-}"
  if [ -z "$new_path" ]; then
    new_path="$(ask "新路径 [$cur_path]: " "$cur_path")"
  fi
  is_path "$new_path" || die "路径无效：$new_path"

  new_sni="${REALITY_TARGET:-}"
  if [ "$cur_mode" = "reality" ]; then
    if [ -n "$new_sni" ]; then
      is_domain "$new_sni" || die "SNI 格式无效：$new_sni"
      REGION_LABEL="自定义"
    elif [ -n "${REGION:-}" ]; then
      ask_region
      new_sni="$REGION_SNI"
    else
      echo "  1) 香港  2) 日本  3) 新加坡  4) 美国  5) 自定义"
      local sel
      sel="$(ask "SNI [回车保持 $cur_sni]: " "")"
      if [ -n "$sel" ]; then
        REGION="$sel"; ask_region; new_sni="$REGION_SNI"
      else
        new_sni="$cur_sni"; REGION_LABEL=""
      fi
    fi
  else
    new_sni="$cur_sni"
  fi

  new_split="$cur_split"
  if [ -n "${SPLIT:-}" ]; then
    case "$SPLIT" in 1|[Yy]*) new_split=1 ;; *) new_split=0 ;; esac
  else
    split_ans="$(ask "分流 [1 开 / 0 关，当前 $cur_split，回车保持]: " "")"
    case "$split_ans" in
      1|[Yy]*|开) new_split=1 ;;
      0|[Nn]*|关) new_split=0 ;;
      "") ;;
      *) die "分流无效：$split_ans" ;;
    esac
  fi

  cp "$config_file" "$config_file.bak.$(date +%Y%m%d%H%M%S)"
  if [ "$cur_mode" = "reality" ]; then
    jq --argjson port "$new_port" --arg uuid "$new_uuid" --arg path "$new_path" \
       --arg target "$new_sni" --arg priv "$cur_priv" --arg sid "$cur_sid" \
      '.inbounds[0].port = $port
       | .inbounds[0].settings.clients[0].id = $uuid
       | .inbounds[0].streamSettings.xhttpSettings.path = $path
       | .inbounds[0].streamSettings.realitySettings.target = ($target + ":443")
       | .inbounds[0].streamSettings.realitySettings.serverNames = [$target]' \
      "$config_file" > "$config_file.tmp"
  else
    jq --argjson port "$new_port" --arg uuid "$new_uuid" --arg path "$new_path" \
      '.inbounds[0].port = $port
       | .inbounds[0].settings.clients[0].id = $uuid
       | .inbounds[0].streamSettings.xhttpSettings.path = $path' \
      "$config_file" > "$config_file.tmp"
  fi
  jq -e . "$config_file.tmp" >/dev/null || die "修改后的配置不是合法 JSON"
  mv "$config_file.tmp" "$config_file"
  xray run -test -config "$config_file" || die "配置校验失败"
  systemctl restart xray
  sleep 2

  local b_addr
  if [ "$cur_mode" = "reality" ]; then
    b_addr="$(grep '^落地地址：' "$info_file" 2>/dev/null | awk -F'：' '{print $NF}' || true)"
    [ -z "$b_addr" ] && b_addr="$(grep -i '^地址' "$info_file" 2>/dev/null | awk -F'：' '{print $NF}' || true)"
    if [ -z "$b_addr" ]; then
      b_addr="$(curl -4s --max-time 8 https://api.ipify.org || echo "")"
    fi
    [ -n "$b_addr" ] || die "无法获取公网 IP（可用 PUBLIC_IP 指定）"
  else
    b_addr="$new_sni"
  fi
  OUT_MODE="$cur_mode"
  OUT_PORT="$new_port"
  OUT_UUID="$new_uuid"
  OUT_PATH="$new_path"
  OUT_SNI="$new_sni"
  OUT_PUB="$cur_pub"
  OUT_SID="$cur_sid"
  OUT_PRIV="$cur_priv"
  OUT_REGION_LABEL="${REGION_LABEL:-}"
  OUT_BBR="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
  OUT_SPLIT="$new_split"
  OUT_B_ADDR="$b_addr"
  OUT_ADDR="$b_addr"
  write_outputs
  echo ""
  cat "$info_file"
}

show_info() {
  if [ -f "$INFO_FILE" ]; then
    cat "$INFO_FILE"
  else
    die "没有找到信息文件"
  fi
}

INFO_FILE="/root/install-info.txt"
SPLIT_A_FILE="/root/split-a.json"
SPLIT_B_FILE="/root/split-b.json"

write_outputs() {
  local mode_num encoded_path base_link
  if [ "$OUT_MODE" = "reality" ]; then mode_num=1; else mode_num=2; fi
  encoded_path="$(printf '%s' "$OUT_PATH" | sed 's|/|%2F|g')"
  base_link="vless://$OUT_UUID@$OUT_ADDR:$OUT_PORT?encryption=none&security=$OUT_MODE&sni=$OUT_SNI&fp=chrome"
  if [ "$OUT_MODE" = "reality" ]; then
    base_link="$base_link&pbk=$OUT_PUB&sid=$OUT_SID"
  fi
  if [ "$OUT_SPLIT" = "1" ]; then
    OUT_LINK="$base_link&type=xhttp&path=$encoded_path&mode=stream-up#$OUT_SNI"
  else
    OUT_LINK="$base_link&type=xhttp&path=$encoded_path&mode=auto#$OUT_SNI"
  fi
  {
    echo "地址：$OUT_ADDR"
    echo "端口：$OUT_PORT"
    echo "UUID：$OUT_UUID"
    echo "路径：$OUT_PATH"
    echo "模式：$mode_num"
    echo "SNI：$OUT_SNI"
    if [ "$OUT_MODE" = "reality" ]; then
      echo "公钥：$OUT_PUB"
      echo "短 ID：$OUT_SID"
      echo "私钥（仅服务端）：$OUT_PRIV"
    fi
    [ -n "${OUT_REGION_LABEL:-}" ] && echo "地区：$OUT_REGION_LABEL"
    if [ "$OUT_SPLIT" = "1" ]; then echo "分流：开"; else echo "分流：关"; fi
    if [ "$OUT_SPLIT" = "1" ]; then
      echo "分离配置 A：$SPLIT_A_FILE"
      echo "分离配置 B：$SPLIT_B_FILE"
    fi
    [ -n "${OUT_BBR:-}" ] && echo "BBR：$OUT_BBR"
    if [ "$OUT_SPLIT" = "1" ]; then
      echo "注意："
      echo "单机分离：上传、下载同一地址，防关联弱于双机；速度为本地速度，无跨地区延迟。"
      echo "手机扫链接只能导入上传腿，分流配置需手动导入。"
    fi
    echo "链接："
    echo "$OUT_LINK"
  } > "$INFO_FILE"
  chmod 600 "$INFO_FILE"
  if [ "$OUT_SPLIT" != "1" ]; then
    rm -f "$SPLIT_A_FILE" "$SPLIT_B_FILE"
    return 0
  fi
  if [ "$OUT_MODE" = "reality" ]; then
    jq -n \
      --arg addr "$OUT_ADDR" --argjson port "$OUT_PORT" \
      --arg uuid "$OUT_UUID" --arg path "$OUT_PATH" \
      --arg sni "$OUT_SNI" --arg pub "$OUT_PUB" --arg sid "$OUT_SID" \
      --arg baddr "$OUT_B_ADDR" --argjson bport "$OUT_PORT" \
      '{
        outbounds: [{
          protocol: "vless",
          settings: {vnext: [{address: $addr, port: $port, users: [{id: $uuid, encryption: "none"}]}]},
          streamSettings: {
            network: "xhttp",
            security: "reality",
            realitySettings: {serverName: $sni, publicKey: $pub, shortId: $sid, fingerprint: "chrome"},
            xhttpSettings: {path: $path, mode: "stream-up",
              extra: {downloadSettings: {address: $baddr, port: $bport, network: "xhttp",
                security: "reality",
                realitySettings: {serverName: $sni, publicKey: $pub, shortId: $sid},
                xhttpSettings: {path: $path}}}}
          }
        }]
      }' > "$SPLIT_A_FILE.tmp"
  else
    jq -n \
      --arg addr "$OUT_ADDR" --argjson port "$OUT_PORT" \
      --arg uuid "$OUT_UUID" --arg path "$OUT_PATH" \
      --arg sni "$OUT_SNI" \
      --arg baddr "$OUT_B_ADDR" --argjson bport "$OUT_PORT" \
      '{
        outbounds: [{
          protocol: "vless",
          settings: {vnext: [{address: $addr, port: $port, users: [{id: $uuid, encryption: "none"}]}]},
          streamSettings: {
            network: "xhttp",
            security: "tls",
            tlsSettings: {serverName: $sni},
            xhttpSettings: {path: $path, mode: "stream-up",
              extra: {downloadSettings: {address: $baddr, port: $bport, network: "xhttp",
                security: "tls",
                tlsSettings: {serverName: $sni},
                xhttpSettings: {path: $path}}}}
          }
        }]
      }' > "$SPLIT_A_FILE.tmp"
  fi
  jq -e . "$SPLIT_A_FILE.tmp" >/dev/null || die "分离配置 A 不是合法 JSON"
  mv "$SPLIT_A_FILE.tmp" "$SPLIT_A_FILE"
  if [ "$OUT_MODE" = "reality" ]; then
    jq -n \
      --arg server "$OUT_ADDR" --argjson server_port "$OUT_PORT" \
      --arg uuid "$OUT_UUID" --arg sni "$OUT_SNI" --arg pub "$OUT_PUB" --arg sid "$OUT_SID" \
      --arg path "$OUT_PATH" --arg dserver "$OUT_B_ADDR" --argjson dport "$OUT_PORT" \
      '{
        type: "vless",
        server: $server,
        server_port: $server_port,
        uuid: $uuid,
        tls: {enabled: true, server_name: $sni,
          reality: {enabled: true, public_key: $pub, short_id: $sid}},
        transport: {type: "xhttp", path: $path, mode: "stream-up",
          download_settings: {server: $dserver, server_port: $dport,
            tls: {enabled: true, server_name: $sni,
              reality: {enabled: true, public_key: $pub, short_id: $sid}},
            path: $path}}
      }' > "$SPLIT_B_FILE.tmp"
  else
    jq -n \
      --arg server "$OUT_ADDR" --argjson server_port "$OUT_PORT" \
      --arg uuid "$OUT_UUID" --arg sni "$OUT_SNI" \
      --arg path "$OUT_PATH" --arg dserver "$OUT_B_ADDR" --argjson dport "$OUT_PORT" \
      '{
        type: "vless",
        server: $server,
        server_port: $server_port,
        uuid: $uuid,
        tls: {enabled: true, server_name: $sni},
        transport: {type: "xhttp", path: $path, mode: "stream-up",
          download_settings: {server: $dserver, server_port: $dport,
            tls: {enabled: true, server_name: $sni},
            path: $path}}
      }' > "$SPLIT_B_FILE.tmp"
  fi
  jq -e . "$SPLIT_B_FILE.tmp" >/dev/null || die "分离配置 B 不是合法 JSON"
  mv "$SPLIT_B_FILE.tmp" "$SPLIT_B_FILE"
  chmod 600 "$SPLIT_A_FILE" "$SPLIT_B_FILE"
}

enable_bbr() {
  info "BBR..."
  if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    modprobe tcp_bbr 2>/dev/null || true
  fi
  if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    warn "内核不支持 BBR，跳过。"
    return 0
  fi
  cat > /etc/sysctl.d/99-bbr.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
  sysctl -p /etc/sysctl.d/99-bbr.conf || warn "sysctl 加载失败"
  if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
    info "BBR 已开启"
  else
    warn "BBR 未生效"
  fi
}

if [ "$(id -u)" -ne 0 ]; then
  die "需要 root"
fi
if [ "$#" -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  echo "用法：sudo ./install.sh"
  echo "环境变量：SPLIT MODE REGION REALITY_TARGET PORT XHTTP_PATH UUID ENABLE_BBR ACTION PUBLIC_IP"
  exit 0
fi

if [ -f /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "仅支持 Debian/Ubuntu，当前：${ID:-未知}" ;;
  esac
else
  die "无法识别系统"
fi
for cmd in curl jq openssl; do
  command -v "$cmd" >/dev/null 2>&1 || warn "$cmd 未安装，稍后安装"
done

ACTION="${ACTION:-}"
if [ -f /usr/local/etc/xray/config.json ] && command -v xray >/dev/null 2>&1; then
  if [ -z "$ACTION" ]; then
    echo ""
    echo "  1) 修改配置"
    echo "  2) 查看信息"
    echo "  3) 重新安装"
    ACTION="$(ask "请选择 [1/2/3，默认 1]: " "1")"
    case "$ACTION" in
      1|modify) ACTION="modify" ;;
      2|show) ACTION="show" ;;
      3|install) ACTION="install" ;;
      *) ACTION="modify" ;;
    esac
  fi
  case "$ACTION" in
    modify) modify_node; exit 0 ;;
    show) show_info; exit 0 ;;
    install) info "重新安装" ;;
    *) die "ACTION 无效：$ACTION" ;;
  esac
fi

MODE="${MODE:-}"
DOMAIN="${DOMAIN:-}"
REGION="${REGION:-}"
REGION_SNI=""
REGION_LABEL=""
REALITY_TARGET="${REALITY_TARGET:-}"
PORT="${PORT:-}"
XHTTP_PATH="${XHTTP_PATH:-}"
UUID="${UUID:-}"
ENABLE_BBR="${ENABLE_BBR:-}"
PUBLIC_IP="${PUBLIC_IP:-}"

if [ -z "$MODE" ]; then
  echo "方式："
  echo "  1"
  echo "  2"
  MODE="$(ask "选择 [1/2，默认 1]: " "1")"
fi
MODE="$(printf '%s' "$MODE" | tr '[:upper:]' '[:lower:]')"
case "$MODE" in
  1|reality) MODE="reality" ;;
  2|tls)     MODE="tls" ;;
  *) die "模式无效：$MODE" ;;
esac

if [ "$MODE" = "tls" ]; then
  while [ -z "$DOMAIN" ] || ! is_domain "$DOMAIN"; do
    [ -n "$DOMAIN" ] && warn "域名格式无效：$DOMAIN"
    DOMAIN="$(ask "域名: " "")"
  done
else
  if [ -n "$REALITY_TARGET" ]; then
    is_domain "$REALITY_TARGET" || die "目标站格式无效：$REALITY_TARGET"
    REGION_LABEL="自定义"
  else
    ask_region
    REALITY_TARGET="$REGION_SNI"
  fi
fi

while [ -z "$PORT" ] || ! is_port "$PORT"; do
  [ -n "$PORT" ] && warn "端口无效：$PORT"
  PORT="$(ask "端口 [默认 443]: " "443")"
done
check_port_free "$PORT" "Xray"

while [ -z "$XHTTP_PATH" ] || ! is_path "$XHTTP_PATH"; do
  [ -n "$XHTTP_PATH" ] && warn "路径无效：$XHTTP_PATH"
  XHTTP_PATH="$(ask "路径 [默认 /api]: " "/api")"
done

if [ -n "$UUID" ] && ! is_uuid "$UUID"; then
  die "UUID 格式无效：$UUID"
fi
UUID="${UUID:-$(gen_uuid)}"

if [ -z "$ENABLE_BBR" ]; then
  ENABLE_BBR="$(ask "BBR [Y/n]: " "Y")"
fi
case "$ENABLE_BBR" in
  1|[Yy]*|[Yy][Ee][Ss]) ENABLE_BBR=1 ;;
  *) ENABLE_BBR=0 ;;
esac

SPLIT="${SPLIT:-}"
if [ -z "$SPLIT" ]; then
  SPLIT_ANS="$(ask "分流 [y/N]: " "N")"
  case "$SPLIT_ANS" in 1|[Yy]*) SPLIT=1 ;; *) SPLIT=0 ;; esac
else
  case "$SPLIT" in 1|[Yy]*) SPLIT=1 ;; *) SPLIT=0 ;; esac
fi

if [ "$MODE" = "reality" ]; then MODE_NUM=1; else MODE_NUM=2; fi
echo ""
echo "模式：$MODE_NUM"
if [ "$MODE" = "tls" ]; then echo "域名：$DOMAIN"; else echo "地区：${REGION_LABEL:-}"; echo "SNI：$REALITY_TARGET"; fi
echo "端口：$PORT"
echo "路径：$XHTTP_PATH"
echo "UUID：$UUID"
if [ "$SPLIT" = "1" ]; then echo "分流：开"; else echo "分流：关"; fi
echo "BBR：$([ "$ENABLE_BBR" = "1" ] && echo 开启 || echo 不开启)"
echo ""

if [ "$ENABLE_BBR" = "1" ]; then
  enable_bbr
else
  info "跳过。"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget socat unzip jq ca-certificates gnupg openssl iproute2

if ! command -v xray >/dev/null 2>&1; then
  info "安装中..."
  curl -fsSL -o "$TMPDIR_WORK/install-release.sh" \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh
  test -s "$TMPDIR_WORK/install-release.sh" || die "下载失败"
  if [ -n "${XRAY_VERSION:-}" ]; then
    bash "$TMPDIR_WORK/install-release.sh" install --version "$XRAY_VERSION"
  else
    bash "$TMPDIR_WORK/install-release.sh" install
  fi
  command -v xray >/dev/null 2>&1 || die "安装失败，未找到 xray"
else
  info "已安装：$(xray version 2>/dev/null | head -n 1 || echo 未知版本)"
fi

CERT_FILE=""
KEY_FILE=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""

if [ "$MODE" = "reality" ]; then
  info "生成密钥..."
  KEY_OUTPUT=""
  if ! KEY_OUTPUT="$(xray x25519 2>&1)"; then
    die "生成密钥失败"
  fi
  PRIVATE_KEY="$(printf '%s' "$KEY_OUTPUT" | grep -i private | awk '{print $NF}')"
  PUBLIC_KEY="$(printf '%s' "$KEY_OUTPUT" | grep -i public | awk '{print $NF}')"
  if ! is_b64key "${PRIVATE_KEY:-}" || ! is_b64key "${PUBLIC_KEY:-}"; then
    die "生成密钥失败，输出无法解析"
  fi
  SHORT_ID="$(openssl rand -hex 8)"

  info "检查目标站：$REALITY_TARGET"
  if ! xray tls ping "$REALITY_TARGET:443"; then
    warn "目标站 $REALITY_TARGET 检查失败，继续安装"
  fi
else
  info "申请证书：$DOMAIN"
  systemctl stop nginx 2>/dev/null || true
  systemctl stop xray 2>/dev/null || true
  check_port_free 80 "证书申请"

  if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
    curl -fsSL -o "$TMPDIR_WORK/get.acme.sh" https://get.acme.sh
    test -s "$TMPDIR_WORK/get.acme.sh" || die "下载失败"
    if [ -n "${ACME_EMAIL:-}" ]; then
      sh "$TMPDIR_WORK/get.acme.sh" "email=$ACME_EMAIL"
    else
      sh "$TMPDIR_WORK/get.acme.sh"
    fi
  fi
  . "$HOME/.acme.sh/acme.sh.env" 2>/dev/null || true

  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
  "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" --standalone -k ec-256 --force

  CERT_FILE="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
  KEY_FILE="$HOME/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key"
  [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] || die "证书申请失败"

  "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --key-file /usr/local/etc/xray/privkey.pem \
    --fullchain-file /usr/local/etc/xray/fullchain.pem \
    --reloadcmd "systemctl restart xray" || true
  CERT_FILE="/usr/local/etc/xray/fullchain.pem"
  KEY_FILE="/usr/local/etc/xray/privkey.pem"
fi

CONFIG_FILE="/usr/local/etc/xray/config.json"
mkdir -p /usr/local/etc/xray
if [ -f "$CONFIG_FILE" ]; then
  cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
  info "旧配置已备份"
fi

jq -n \
  --argjson port "$PORT" \
  --arg uuid "$UUID" \
  --arg path "$XHTTP_PATH" \
  --arg mode "$MODE" \
  --arg target "$REALITY_TARGET" \
  --arg priv "$PRIVATE_KEY" \
  --arg sid "$SHORT_ID" \
  --arg cert "$CERT_FILE" \
  --arg key "$KEY_FILE" \
  '{
    log: {loglevel: "warning"},
    inbounds: [{
      listen: "0.0.0.0",
      port: $port,
      protocol: "vless",
      settings: {clients: [{id: $uuid, email: "user"}], decryption: "none"},
      streamSettings: (
        {network: "xhttp", xhttpSettings: {path: $path, mode: "auto"}} +
        (if $mode == "reality" then
          {security: "reality",
           realitySettings: {show: false, target: ($target + ":443"), xver: 0,
             serverNames: [$target], privateKey: $priv, shortIds: [$sid], maxTimeDiff: 60000}}
        else
          {security: "tls",
           tlsSettings: {certificates: [{certificateFile: $cert, keyFile: $key}]}}
        end)
      ),
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
    }],
    outbounds: [
      {protocol: "freedom", tag: "direct"},
      {protocol: "blackhole", tag: "blocked"}
    ]
  }' > "$CONFIG_FILE.tmp"
jq -e . "$CONFIG_FILE.tmp" >/dev/null || die "配置不是合法 JSON"
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

if id xray >/dev/null 2>&1; then
  chgrp xray "$CONFIG_FILE" 2>/dev/null || true
  chmod 640 "$CONFIG_FILE" 2>/dev/null || true
  if [ "$MODE" = "tls" ]; then
    chgrp xray "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
    chmod 640 "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
  fi
fi

info "校验中..."
xray run -test -config "$CONFIG_FILE"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" || warn "放行 $PORT/tcp 失败"
  [ "$MODE" = "tls" ] && ufw allow 80/tcp || true
fi

systemctl enable xray
systemctl restart xray
sleep 2
systemctl status xray --no-pager -l | head -n 20 || true

if [ -z "$PUBLIC_IP" ]; then
  PUBLIC_IP="$(curl -4s --max-time 8 https://api.ipify.org \
    || curl -4s --max-time 8 https://ifconfig.me \
    || curl -4s --max-time 8 https://icanhazip.com \
    || echo "")"
  PUBLIC_IP="$(printf '%s' "$PUBLIC_IP" | tr -d ' \r\n')"
fi
if [ "$MODE" = "reality" ] && [ -z "$PUBLIC_IP" ]; then
  die "无法获取公网 IP（可用 PUBLIC_IP 指定）"
fi

BBR_STATUS="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
OUT_MODE="$MODE"
OUT_PORT="$PORT"
OUT_UUID="$UUID"
OUT_PATH="$XHTTP_PATH"
OUT_BBR="$BBR_STATUS"
OUT_SPLIT="$SPLIT"
OUT_REGION_LABEL="${REGION_LABEL:-}"
if [ "$MODE" = "reality" ]; then
  OUT_SNI="$REALITY_TARGET"
  OUT_PUB="$PUBLIC_KEY"
  OUT_SID="$SHORT_ID"
  OUT_PRIV="$PRIVATE_KEY"
  OUT_B_ADDR="$PUBLIC_IP"
else
  OUT_SNI="$DOMAIN"
  OUT_PUB=""
  OUT_SID=""
  OUT_PRIV=""
  OUT_B_ADDR="$DOMAIN"
fi
OUT_ADDR="$OUT_B_ADDR"
write_outputs

echo ""
cat "$INFO_FILE"
echo "配置：$CONFIG_FILE"
echo "日志：journalctl -u xray -f"
echo "保存到：$INFO_FILE"
if [ "$MODE" = "reality" ]; then echo "私钥只在服务端，不要发给别人。"; fi
