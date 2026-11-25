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

parse_bytes() {
  local s mult=1
  s="$(printf '%s' "$1" | tr -d ' \t\r\n')"
  [ -z "$s" ] && { echo 0; return 0; }
  case "$s" in
    *K|*k) mult=1024; s="${s%?}" ;;
    *M|*m) mult=1048576; s="${s%?}" ;;
    *G|*g) mult=1073741824; s="${s%?}" ;;
    *T|*t) mult=1099511627776; s="${s%?}" ;;
  esac
  [[ "$s" =~ ^[0-9]+$ ]] || return 1
  echo $(( s * mult ))
}

fmt_bytes() {
  local b=$1
  if [ "$b" -lt 1024 ]; then printf '%s B' "$b"; return 0; fi
  awk -v b="$b" 'BEGIN {
    if (b < 1048576) printf "%.2f KB", b/1024;
    else if (b < 1073741824) printf "%.2f MB", b/1048576;
    else if (b < 1099511627776) printf "%.2f GB", b/1073741824;
    else printf "%.2f TB", b/1099511627776;
  }'
}

norm_tq_mode() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    out|outbound|出站) echo out ;;
    in|inbound|入站) echo in ;;
    total|总计|"") echo total ;;
    max|最大值) echo max ;;
    *) return 1 ;;
  esac
}

norm_tq_period() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    monthly|month|月|"") echo monthly ;;
    quarterly|quarter|季) echo quarterly ;;
    yearly|year|年) echo yearly ;;
    *) return 1 ;;
  esac
}

norm_tq_limit() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    block|阻断|"") echo block ;;
    throttle|tc|限速|tc限速) echo throttle ;;
    *) return 1 ;;
  esac
}

tq_mode_label() {
  case "$1" in out) echo 出站;; in) echo 入站;; max) echo 最大值;; *) echo 总计;; esac
}

tq_period_label() {
  case "$1" in quarterly) echo 季;; yearly) echo 年;; *) echo 月;; esac
}

tq_limit_label() {
  case "$1" in throttle) echo 限速;; *) echo 阻断;; esac
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
  cur_priv=""; cur_pub=""; cur_sid=""
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

  local cur_mode_label="Reality"
  [ "$cur_mode" = "tls" ] && cur_mode_label="TLS"
  echo ""
  echo "模式：$cur_mode_label"
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

  local env_tq_mode="${TQ_MODE:-}" env_tq_period="${TQ_PERIOD:-}" env_tq_start="${TQ_START:-}"
  local env_tq_limit="${TQ_LIMIT:-}" env_tq_quota="${TQ_QUOTA:-}" env_tq_rate="${TQ_RATE:-}"
  local cur_tq_mode cur_tq_period cur_tq_start cur_tq_limit cur_tq_quota cur_tq_rate
  cur_tq_mode=total; cur_tq_period=monthly; cur_tq_start=1; cur_tq_limit=block; cur_tq_quota=0; cur_tq_rate=128000
  if [ -f "$TQ_CONF" ]; then
    TQ_MODE=""; TQ_PERIOD=""; TQ_START=""; TQ_LIMIT=""; TQ_QUOTA=""; TQ_RATE=""
    . "$TQ_CONF"
    cur_tq_mode="${TQ_MODE:-total}"; cur_tq_period="${TQ_PERIOD:-monthly}"; cur_tq_start="${TQ_START:-1}"
    cur_tq_limit="${TQ_LIMIT:-block}"; cur_tq_quota="${TQ_QUOTA:-0}"; cur_tq_rate="${TQ_RATE:-128000}"
  fi
  echo "统计：$(tq_mode_label "$cur_tq_mode") / 周期：$(tq_period_label "$cur_tq_period") / 起始日：$cur_tq_start"
  if [ "$cur_tq_quota" = "0" ]; then
    echo "限制：$(tq_limit_label "$cur_tq_limit") / 限额：不限 / 限速：$(fmt_bytes "$cur_tq_rate")/s"
  else
    echo "限制：$(tq_limit_label "$cur_tq_limit") / 限额：$(fmt_bytes "$cur_tq_quota") / 限速：$(fmt_bytes "$cur_tq_rate")/s"
  fi

  local new_tq_mode new_tq_period new_tq_start new_tq_limit new_tq_quota new_tq_rate
  new_tq_mode="$env_tq_mode"
  if [ -z "$new_tq_mode" ]; then
    new_tq_mode="$(ask "统计 [out/in/total/max，回车保持]: " "")"
    [ -z "$new_tq_mode" ] && new_tq_mode="$cur_tq_mode"
  fi
  new_tq_mode="$(norm_tq_mode "$new_tq_mode")" || die "统计模式无效：$new_tq_mode"
  new_tq_period="$env_tq_period"
  if [ -z "$new_tq_period" ]; then
    new_tq_period="$(ask "周期 [monthly/quarterly/yearly，回车保持]: " "")"
    [ -z "$new_tq_period" ] && new_tq_period="$cur_tq_period"
  fi
  new_tq_period="$(norm_tq_period "$new_tq_period")" || die "统计周期无效：$new_tq_period"
  new_tq_start="$env_tq_start"
  if [ -z "$new_tq_start" ]; then
    new_tq_start="$(ask "起始日 [1-28，回车保持]: " "")"
    [ -z "$new_tq_start" ] && new_tq_start="$cur_tq_start"
  fi
  [[ "$new_tq_start" =~ ^[0-9]+$ ]] && [ "$new_tq_start" -ge 1 ] && [ "$new_tq_start" -le 28 ] || die "起始日无效：$new_tq_start，应为 1-28"
  new_tq_limit="$env_tq_limit"
  if [ -z "$new_tq_limit" ]; then
    new_tq_limit="$(ask "限制 [block/throttle，回车保持]: " "")"
    [ -z "$new_tq_limit" ] && new_tq_limit="$cur_tq_limit"
  fi
  new_tq_limit="$(norm_tq_limit "$new_tq_limit")" || die "限制模式无效：$new_tq_limit"
  new_tq_quota="$env_tq_quota"
  if [ -z "$new_tq_quota" ]; then
    new_tq_quota="$(ask "限额 [如 500G，0=不限，回车保持]: " "")"
    [ -z "$new_tq_quota" ] && new_tq_quota="$cur_tq_quota"
  fi
  new_tq_quota="$(parse_bytes "$new_tq_quota")" || die "限额无效：$new_tq_quota"
  new_tq_rate="$env_tq_rate"
  if [ -z "$new_tq_rate" ]; then
    new_tq_rate="$(ask "限速 [如 125K，回车保持]: " "")"
    [ -z "$new_tq_rate" ] && new_tq_rate="$cur_tq_rate"
  fi
  new_tq_rate="$(parse_bytes "$new_tq_rate")" || die "限速值无效：$new_tq_rate"
  if [ "$new_tq_limit" = "throttle" ] && [ "$new_tq_rate" -le 0 ]; then die "限速模式下限速值必须大于 0"; fi

  local old_tq_sig new_tq_sig
  old_tq_sig="$cur_tq_mode|$cur_tq_period|$cur_tq_start"
  new_tq_sig="$new_tq_mode|$new_tq_period|$new_tq_start"
  TQ_MODE="$new_tq_mode"; TQ_PERIOD="$new_tq_period"; TQ_START="$new_tq_start"
  TQ_LIMIT="$new_tq_limit"; TQ_QUOTA="$new_tq_quota"; TQ_RATE="$new_tq_rate"; TQ_PORT="$new_port"
  write_tq_conf
  if [ "$old_tq_sig" != "$new_tq_sig" ]; then
    if [ -f "$TQ_STATE" ]; then
      local tq_enf
      tq_enf="$(jq -r '.enforced // ""' "$TQ_STATE" 2>/dev/null || echo "")"
      [ "$tq_enf" = "block" ] && systemctl start xray 2>/dev/null || true
      if [ "$tq_enf" = "throttle" ]; then [ -x "$TQ_WATCH" ] && "$TQ_WATCH" clear 2>/dev/null || true; fi
      rm -f "$TQ_STATE"
    fi
  fi
  if [ "$cur_port" != "$new_port" ]; then
    iptables -D INPUT -p tcp --dport "$cur_port" 2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport "$cur_port" 2>/dev/null || true
  fi
  install_traffic_watch

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
  OUT_TQ_MODE="$new_tq_mode"; OUT_TQ_PERIOD="$new_tq_period"; OUT_TQ_START="$new_tq_start"
  OUT_TQ_LIMIT="$new_tq_limit"; OUT_TQ_QUOTA="$new_tq_quota"; OUT_TQ_RATE="$new_tq_rate"
  OUT_B_ADDR="$b_addr"
  OUT_ADDR="$b_addr"
  write_outputs
  [ -x "$TQ_WATCH" ] && "$TQ_WATCH" run 2>/dev/null || true
  echo ""
  cat "$info_file"
}

show_info() {
  if [ -f "$INFO_FILE" ]; then
    cat "$INFO_FILE"
  else
    die "没有找到信息文件"
  fi
  echo ""
  traffic_status
}

write_tq_conf() {
  mkdir -p "$(dirname "$TQ_CONF")"
  {
    echo "TQ_MODE=$TQ_MODE"
    echo "TQ_PERIOD=$TQ_PERIOD"
    echo "TQ_START=$TQ_START"
    echo "TQ_LIMIT=$TQ_LIMIT"
    echo "TQ_QUOTA=$TQ_QUOTA"
    echo "TQ_RATE=$TQ_RATE"
    echo "TQ_PORT=$TQ_PORT"
  } > "$TQ_CONF.tmp"
  mv "$TQ_CONF.tmp" "$TQ_CONF"
  chmod 600 "$TQ_CONF"
}

traffic_status() {
  if [ -x "$TQ_WATCH" ]; then
    "$TQ_WATCH" status
  else
    echo "流量：无数据"
  fi
}

INFO_FILE="/root/install-info.txt"
SPLIT_A_FILE="/root/split-a.json"
SPLIT_B_FILE="/root/split-b.json"
TQ_CONF="/usr/local/etc/xray/traffic.conf"
TQ_STATE="/usr/local/etc/xray/traffic.json"
TQ_WATCH="/usr/local/bin/traffic-watch"

write_outputs() {
  local mode_label encoded_path base_link
  if [ "$OUT_MODE" = "reality" ]; then mode_label="Reality"; else mode_label="TLS"; fi
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
    echo "模式：$mode_label"
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
    echo "统计：$(tq_mode_label "${OUT_TQ_MODE:-total}")"
    echo "周期：$(tq_period_label "${OUT_TQ_PERIOD:-monthly}")"
    echo "起始日：${OUT_TQ_START:-1}"
    echo "限制：$(tq_limit_label "${OUT_TQ_LIMIT:-block}")"
    if [ "${OUT_TQ_QUOTA:-0}" = "0" ]; then echo "限额：不限"; else echo "限额：$(fmt_bytes "${OUT_TQ_QUOTA}")"; fi
    echo "限速：$(fmt_bytes "${OUT_TQ_RATE:-128000}")/s"
    echo "流量文件：$TQ_STATE"
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

install_traffic_watch() {
  mkdir -p /usr/local/bin /etc/systemd/system
  cat > "$TQ_WATCH" <<'WATCHEOF'
#!/usr/bin/env bash
TQ_CONF="${TQ_CONF:-/usr/local/etc/xray/traffic.conf}"
TQ_STATE="${TQ_STATE:-/usr/local/etc/xray/traffic.json}"
TQ_MODE=total
TQ_PERIOD=monthly
TQ_START=1
TQ_LIMIT=block
TQ_QUOTA=0
TQ_RATE=128000
TQ_PORT=443
IN=0
OUT=0
LAST_IN=0
LAST_OUT=0
P_START=0
P_END=0
S_MODE=""
S_PERIOD=""
S_START=0
S_PORT=0
ENFORCED=""
CUR_IN=0
CUR_OUT=0
COUNTED=0
NOW=0
IFACE=""
fmt_bytes() {
  local b=$1
  if [ "$b" -lt 1024 ]; then printf '%s B' "$b"; return 0; fi
  awk -v b="$b" 'BEGIN {
    if (b < 1048576) printf "%.2f KB", b/1024;
    else if (b < 1073741824) printf "%.2f MB", b/1048576;
    else if (b < 1099511627776) printf "%.2f GB", b/1073741824;
    else printf "%.2f TB", b/1099511627776;
  }'
}
dim() {
  date -d "$1-$2-01 +1 month -1 day" +%d
}
anchor_epoch() {
  local y=$1 m=$2 d=$3 last
  last=$(dim "$y" "$m")
  [ "$d" -gt "$last" ] && d=$last
  date -d "$y-$m-01 +$((d - 1)) days" +%s
}
add_months() {
  local total=$(( $1 * 12 + $2 - 1 + $3 ))
  printf '%s %s' "$(( total / 12 ))" "$(( total % 12 + 1 ))"
}
period_bounds() {
  local now=$1 period=$2 d=$3 y m s e qm
  y=$(date -d "@$now" +%Y)
  m=$(date -d "@$now" +%m); m=$((10#$m))
  case "$period" in
    quarterly)
      qm=$(( (m - 1) / 3 * 3 + 1 ))
      s=$(anchor_epoch "$y" "$qm" "$d")
      if [ "$s" -gt "$now" ]; then
        read -r y qm <<< "$(add_months "$y" "$qm" -3)"
        s=$(anchor_epoch "$y" "$qm" "$d")
      fi
      read -r y qm <<< "$(add_months "$y" "$qm" 3)"
      e=$(anchor_epoch "$y" "$qm" "$d")
      ;;
    yearly)
      s=$(anchor_epoch "$y" 1 "$d")
      if [ "$s" -gt "$now" ]; then s=$(anchor_epoch "$((y - 1))" 1 "$d"); fi
      e=$(anchor_epoch "$(( $(date -d "@$s" +%Y) + 1 ))" 1 "$d")
      ;;
    *)
      s=$(anchor_epoch "$y" "$m" "$d")
      if [ "$s" -gt "$now" ]; then
        read -r y m <<< "$(add_months "$y" "$m" -1)"
        s=$(anchor_epoch "$y" "$m" "$d")
      fi
      read -r y m <<< "$(add_months "$y" "$m" 1)"
      e=$(anchor_epoch "$y" "$m" "$d")
      ;;
  esac
  printf '%s %s' "$s" "$e"
}
load_conf() {
  TQ_MODE=total; TQ_PERIOD=monthly; TQ_START=1; TQ_LIMIT=block; TQ_QUOTA=0; TQ_RATE=128000; TQ_PORT=443
  if [ -f "$TQ_CONF" ]; then
    . "$TQ_CONF"
  fi
  case "$TQ_MODE" in out|in|total|max) ;; *) TQ_MODE=total ;; esac
  case "$TQ_PERIOD" in monthly|quarterly|yearly) ;; *) TQ_PERIOD=monthly ;; esac
  case "$TQ_LIMIT" in block|throttle) ;; *) TQ_LIMIT=block ;; esac
  [[ "$TQ_START" =~ ^[0-9]+$ ]] && [ "$TQ_START" -ge 1 ] && [ "$TQ_START" -le 28 ] || TQ_START=1
  [[ "$TQ_QUOTA" =~ ^[0-9]+$ ]] || TQ_QUOTA=0
  [[ "$TQ_RATE" =~ ^[0-9]+$ ]] || TQ_RATE=128000
  [[ "$TQ_PORT" =~ ^[0-9]+$ ]] || TQ_PORT=443
}
load_state() {
  IN=0; OUT=0; LAST_IN=0; LAST_OUT=0; P_START=0; P_END=0
  S_MODE=""; S_PERIOD=""; S_START=0; S_PORT=0; ENFORCED=""
  [ -f "$TQ_STATE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  IN=$(jq -r '.in // 0' "$TQ_STATE" 2>/dev/null || echo 0)
  OUT=$(jq -r '.out // 0' "$TQ_STATE" 2>/dev/null || echo 0)
  LAST_IN=$(jq -r '.last_in // 0' "$TQ_STATE" 2>/dev/null || echo 0)
  LAST_OUT=$(jq -r '.last_out // 0' "$TQ_STATE" 2>/dev/null || echo 0)
  P_START=$(jq -r '.period_start // 0' "$TQ_STATE" 2>/dev/null || echo 0)
  P_END=$(jq -r '.period_end // 0' "$TQ_STATE" 2>/dev/null || echo 0)
  S_MODE=$(jq -r '.mode // ""' "$TQ_STATE" 2>/dev/null || echo "")
  S_PERIOD=$(jq -r '.period // ""' "$TQ_STATE" 2>/dev/null || echo "")
  S_START=$(jq -r '.start_day // 0' "$TQ_STATE" 2>/dev/null || echo 0)
  S_PORT=$(jq -r '.port // 0' "$TQ_STATE" 2>/dev/null || echo 0)
  ENFORCED=$(jq -r '.enforced // ""' "$TQ_STATE" 2>/dev/null || echo "")
  [[ "$IN" =~ ^[0-9]+$ ]] || IN=0
  [[ "$OUT" =~ ^[0-9]+$ ]] || OUT=0
  [[ "$LAST_IN" =~ ^[0-9]+$ ]] || LAST_IN=0
  [[ "$LAST_OUT" =~ ^[0-9]+$ ]] || LAST_OUT=0
  [[ "$P_START" =~ ^[0-9]+$ ]] || P_START=0
  [[ "$P_END" =~ ^[0-9]+$ ]] || P_END=0
}
save_state() {
  command -v jq >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$TQ_STATE")" 2>/dev/null || true
  jq -n \
    --argjson in "$IN" --argjson out "$OUT" \
    --argjson last_in "$LAST_IN" --argjson last_out "$LAST_OUT" \
    --argjson period_start "$P_START" --argjson period_end "$P_END" \
    --arg mode "$TQ_MODE" --arg period "$TQ_PERIOD" --argjson start_day "$TQ_START" \
    --argjson port "$TQ_PORT" --arg enforced "$ENFORCED" \
    '{in: $in, out: $out, last_in: $last_in, last_out: $last_out,
      period_start: $period_start, period_end: $period_end,
      mode: $mode, period: $period, start_day: $start_day,
      port: $port, enforced: $enforced}' > "$TQ_STATE.tmp" 2>/dev/null || return 0
  mv "$TQ_STATE.tmp" "$TQ_STATE" 2>/dev/null || true
  chmod 600 "$TQ_STATE" 2>/dev/null || true
}
ensure_rules() {
  command -v iptables >/dev/null 2>&1 || return 0
  iptables -C INPUT -p tcp --dport "$TQ_PORT" 2>/dev/null || iptables -A INPUT -p tcp --dport "$TQ_PORT" 2>/dev/null || true
  iptables -C OUTPUT -p tcp --sport "$TQ_PORT" 2>/dev/null || iptables -A OUTPUT -p tcp --sport "$TQ_PORT" 2>/dev/null || true
}
read_counters() {
  local v
  CUR_IN=0; CUR_OUT=0
  command -v iptables >/dev/null 2>&1 || return 0
  v=$(iptables -L INPUT -v -n -x 2>/dev/null | awk -v p="$TQ_PORT" '$0 ~ "dpt:"p"( |$)" {s += $2} END {print s+0}')
  [[ "$v" =~ ^[0-9]+$ ]] && CUR_IN=$v
  v=$(iptables -L OUTPUT -v -n -x 2>/dev/null | awk -v p="$TQ_PORT" '$0 ~ "spt:"p"( |$)" {s += $2} END {print s+0}')
  [[ "$v" =~ ^[0-9]+$ ]] && CUR_OUT=$v
}
detect_if() {
  IFACE=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i == "dev") {print $(i+1); exit}}')
  [ -z "$IFACE" ] && IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  [ -z "$IFACE" ] && IFACE="eth0"
}
tc_present() {
  detect_if
  command -v tc >/dev/null 2>&1 || return 1
  tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "htb 1:"
}
tc_apply() {
  command -v tc >/dev/null 2>&1 || return 0
  detect_if
  local kbit=$(( TQ_RATE * 8 / 1024 ))
  [ "$kbit" -lt 8 ] && kbit=8
  tc qdisc replace dev "$IFACE" root handle 1: htb default 30 2>/dev/null || return 0
  tc class replace dev "$IFACE" parent 1: classid 1:1 htb rate 10000mbit 2>/dev/null || true
  tc class replace dev "$IFACE" parent 1:1 classid 1:10 htb rate "${kbit}kbit" ceil "${kbit}kbit" 2>/dev/null || true
  tc class replace dev "$IFACE" parent 1:1 classid 1:30 htb rate 10000mbit ceil 10000mbit 2>/dev/null || true
  tc qdisc replace dev "$IFACE" parent 1:10 handle 10: fq 2>/dev/null || true
  tc qdisc replace dev "$IFACE" parent 1:30 handle 30: fq 2>/dev/null || true
  tc filter replace dev "$IFACE" parent 1: protocol ip prio 1 u32 match ip sport "$TQ_PORT" 0xffff flowid 1:10 2>/dev/null || true
  tc qdisc replace dev "$IFACE" handle ffff: ingress 2>/dev/null || true
  tc filter replace dev "$IFACE" parent ffff: protocol ip prio 1 u32 match ip dport "$TQ_PORT" 0xffff police rate "${kbit}kbit" burst 64kbit drop 2>/dev/null || true
}
tc_clear() {
  command -v tc >/dev/null 2>&1 || return 0
  detect_if
  tc qdisc del dev "$IFACE" root 2>/dev/null || true
  tc qdisc del dev "$IFACE" handle ffff: ingress 2>/dev/null || true
}
counted_now() {
  case "$TQ_MODE" in
    out) COUNTED=$OUT ;;
    in) COUNTED=$IN ;;
    max) [ "$IN" -gt "$OUT" ] && COUNTED=$IN || COUNTED=$OUT ;;
    *) COUNTED=$(( IN + OUT )) ;;
  esac
}
run_watch() {
  load_conf
  NOW=$(date +%s)
  ensure_rules
  read_counters
  load_state
  if [ "$S_MODE|$S_PERIOD|$S_START" != "$TQ_MODE|$TQ_PERIOD|$TQ_START" ] || [ "$P_END" -le "$NOW" ] || [ "$P_START" -eq 0 ]; then
    if [ "$ENFORCED" = "block" ]; then systemctl start xray 2>/dev/null || true; fi
    if [ "$ENFORCED" = "throttle" ]; then tc_clear; fi
    IN=0; OUT=0; ENFORCED=""
    read -r P_START P_END <<< "$(period_bounds "$NOW" "$TQ_PERIOD" "$TQ_START")"
    LAST_IN=$CUR_IN; LAST_OUT=$CUR_OUT; S_PORT=$TQ_PORT
  fi
  if [ "$S_PORT" != "$TQ_PORT" ]; then
    LAST_IN=$CUR_IN; LAST_OUT=$CUR_OUT; S_PORT=$TQ_PORT
  fi
  if [ "$CUR_IN" -ge "$LAST_IN" ]; then IN=$(( IN + CUR_IN - LAST_IN )); else IN=$(( IN + CUR_IN )); fi
  if [ "$CUR_OUT" -ge "$LAST_OUT" ]; then OUT=$(( OUT + CUR_OUT - LAST_OUT )); else OUT=$(( OUT + CUR_OUT )); fi
  LAST_IN=$CUR_IN; LAST_OUT=$CUR_OUT
  S_MODE=$TQ_MODE; S_PERIOD=$TQ_PERIOD; S_START=$TQ_START
  counted_now
  if [ "$TQ_QUOTA" -gt 0 ] && [ "$COUNTED" -ge "$TQ_QUOTA" ]; then
    if [ "$TQ_LIMIT" = "throttle" ]; then
      if [ "$ENFORCED" != "throttle" ] || ! tc_present; then tc_apply; fi
      ENFORCED="throttle"
    else
      if systemctl is-active --quiet xray 2>/dev/null; then systemctl stop xray 2>/dev/null || true; fi
      ENFORCED="block"
    fi
  else
    if [ "$ENFORCED" = "block" ]; then systemctl start xray 2>/dev/null || true; fi
    if [ "$ENFORCED" = "throttle" ]; then tc_clear; fi
    ENFORCED=""
  fi
  save_state
}
mode_label() {
  case "$1" in out) echo 出站;; in) echo 入站;; max) echo 最大值;; *) echo 总计;; esac
}
period_label() {
  case "$1" in quarterly) echo 季;; yearly) echo 年;; *) echo 月;; esac
}
period_desc() {
  case "$1" in
    quarterly) printf '1/4/7/10 月 %s 日起' "$2" ;;
    yearly) printf '每年 1 月 %s 日起' "$2" ;;
    *) printf '每月 %s 日起' "$2" ;;
  esac
}
limit_label() {
  case "$1" in throttle) echo 限速;; *) echo 阻断;; esac
}
show_status() {
  load_conf
  NOW=$(date +%s)
  load_state
  local din dout dcounted dstart dend rem
  if [ "$P_END" -le "$NOW" ] || [ "$P_START" -eq 0 ] || [ "$S_MODE|$S_PERIOD|$S_START" != "$TQ_MODE|$TQ_PERIOD|$TQ_START" ]; then
    din=0; dout=0; dcounted=0
    read -r dstart dend <<< "$(period_bounds "$NOW" "$TQ_PERIOD" "$TQ_START")"
  else
    din=$IN; dout=$OUT
    case "$TQ_MODE" in
      out) dcounted=$OUT ;;
      in) dcounted=$IN ;;
      max) [ "$IN" -gt "$OUT" ] && dcounted=$IN || dcounted=$OUT ;;
      *) dcounted=$(( IN + OUT )) ;;
    esac
    dstart=$P_START; dend=$P_END
  fi
  echo "统计：$(mode_label "$TQ_MODE")"
  echo "周期：$(period_label "$TQ_PERIOD")（$(period_desc "$TQ_PERIOD" "$TQ_START")）"
  echo "本周期：$(date -d "@$dstart" +%Y-%m-%d) 至 $(date -d "@$dend" +%Y-%m-%d)"
  echo "已用：$(fmt_bytes "$dcounted")（入站 $(fmt_bytes "$din") / 出站 $(fmt_bytes "$dout")）"
  if [ "$TQ_QUOTA" -gt 0 ]; then
    echo "限额：$(fmt_bytes "$TQ_QUOTA")"
    rem=$(( TQ_QUOTA - dcounted ))
    [ "$rem" -lt 0 ] && rem=0
    echo "剩余：$(fmt_bytes "$rem")"
  else
    echo "限额：不限"
    echo "剩余：不限"
  fi
  if [ "$TQ_LIMIT" = "throttle" ]; then
    echo "限制：限速（超限后降到 $(fmt_bytes "$TQ_RATE")/s）"
  else
    echo "限制：阻断"
  fi
  if [ "$TQ_QUOTA" -gt 0 ] && [ "$dcounted" -ge "$TQ_QUOTA" ]; then
    if [ "$TQ_LIMIT" = "throttle" ]; then
      echo "状态：已超限（限速 $(fmt_bytes "$TQ_RATE")/s）"
    else
      echo "状态：已超限（阻断）"
    fi
  else
    echo "状态：正常"
  fi
}
if [ "$0" = "${BASH_SOURCE[0]}" ]; then
  case "${1:-run}" in
    run) run_watch ;;
    status) show_status ;;
    clear) tc_clear ;;
    *) run_watch ;;
  esac
fi
WATCHEOF
  chmod 700 "$TQ_WATCH"
  cat > /etc/systemd/system/traffic-watch.service <<'SVCEOF'
[Unit]
Description=traffic
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/traffic-watch
[Install]
WantedBy=multi-user.target
SVCEOF
  cat > /etc/systemd/system/traffic-watch.timer <<'TMREOF'
[Unit]
Description=traffic
[Timer]
OnBootSec=60
OnUnitActiveSec=60
Persistent=true
[Install]
WantedBy=timers.target
TMREOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now traffic-watch.timer 2>/dev/null || true
}

if [ "$(id -u)" -ne 0 ]; then
  die "需要 root"
fi
if [ "$#" -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  echo "用法：sudo ./install.sh"
  echo "环境变量：SPLIT MODE REGION REALITY_TARGET PORT XHTTP_PATH UUID ENABLE_BBR ACTION PUBLIC_IP TQ_MODE TQ_PERIOD TQ_START TQ_LIMIT TQ_QUOTA TQ_RATE"
  exit 0
fi
if [ "$#" -gt 0 ] && [ "$1" = "--show-traffic" ]; then traffic_status; exit 0; fi

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
    traffic) traffic_status; exit 0 ;;
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
  echo "  1) Reality"
  echo "  2) TLS"
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

TQ_MODE="${TQ_MODE:-}"
TQ_PERIOD="${TQ_PERIOD:-}"
TQ_START="${TQ_START:-}"
TQ_LIMIT="${TQ_LIMIT:-}"
TQ_QUOTA="${TQ_QUOTA:-}"
TQ_RATE="${TQ_RATE:-}"
if [ -z "$TQ_QUOTA" ]; then
  TQ_QUOTA_ANS="$(ask "限额 [0=不限，如 500G，默认 0]: " "0")"
  TQ_QUOTA="$TQ_QUOTA_ANS"
fi
TQ_QUOTA="$(parse_bytes "$TQ_QUOTA")" || die "限额无效：$TQ_QUOTA"
if [ "$TQ_QUOTA" -gt 0 ] && [ -z "$TQ_LIMIT" ]; then
  TQ_LIMIT_ANS="$(ask "限制 [1 阻断 / 2 限速，默认 1]: " "1")"
  case "$TQ_LIMIT_ANS" in 2|throttle|限速) TQ_LIMIT=throttle ;; *) TQ_LIMIT=block ;; esac
fi
TQ_MODE="$(norm_tq_mode "${TQ_MODE:-total}")" || die "统计模式无效：$TQ_MODE"
TQ_PERIOD="$(norm_tq_period "${TQ_PERIOD:-monthly}")" || die "统计周期无效：$TQ_PERIOD"
[ -z "$TQ_START" ] && TQ_START=1
[[ "$TQ_START" =~ ^[0-9]+$ ]] && [ "$TQ_START" -ge 1 ] && [ "$TQ_START" -le 28 ] || die "起始日无效：$TQ_START，应为 1-28"
TQ_LIMIT="$(norm_tq_limit "${TQ_LIMIT:-block}")" || die "限制模式无效：$TQ_LIMIT"
TQ_RATE="$(parse_bytes "${TQ_RATE:-125K}")" || die "限速值无效：$TQ_RATE"
if [ "$TQ_LIMIT" = "throttle" ] && [ "$TQ_RATE" -le 0 ]; then die "限速模式下限速值必须大于 0"; fi

if [ "$MODE" = "reality" ]; then MODE_LABEL="Reality"; else MODE_LABEL="TLS"; fi
echo ""
echo "模式：$MODE_LABEL"
if [ "$MODE" = "tls" ]; then echo "域名：$DOMAIN"; else echo "地区：${REGION_LABEL:-}"; echo "SNI：$REALITY_TARGET"; fi
echo "端口：$PORT"
echo "路径：$XHTTP_PATH"
echo "UUID：$UUID"
if [ "$SPLIT" = "1" ]; then echo "分流：开"; else echo "分流：关"; fi
if [ "$TQ_QUOTA" = "0" ]; then echo "限额：不限"; else echo "限额：$(fmt_bytes "$TQ_QUOTA") / 限制：$(tq_limit_label "$TQ_LIMIT")"; fi
echo "BBR：$([ "$ENABLE_BBR" = "1" ] && echo 开启 || echo 不开启)"
echo ""

if [ "$ENABLE_BBR" = "1" ]; then
  enable_bbr
else
  info "跳过。"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget socat unzip jq ca-certificates gnupg openssl iproute2 iptables

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
OUT_TQ_MODE="$TQ_MODE"; OUT_TQ_PERIOD="$TQ_PERIOD"; OUT_TQ_START="$TQ_START"
OUT_TQ_LIMIT="$TQ_LIMIT"; OUT_TQ_QUOTA="$TQ_QUOTA"; OUT_TQ_RATE="$TQ_RATE"
TQ_PORT="$PORT"
write_tq_conf
install_traffic_watch
write_outputs
"$TQ_WATCH" run 2>/dev/null || true

echo ""
cat "$INFO_FILE"
echo "配置：$CONFIG_FILE"
echo "日志：journalctl -u xray -f"
echo "保存到：$INFO_FILE"
if [ "$MODE" = "reality" ]; then echo "私钥只在服务端，不要发给别人。"; fi
