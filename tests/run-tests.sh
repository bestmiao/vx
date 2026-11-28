#!/usr/bin/env bash
T=/tmp/vx-traffic-test
export TZ=UTC
export TQ_TEST_ROOT="$T/run"
export TQ_SYSFS_ROOT="$T/run/sysfs"
export TQ_IFACE=eth0
export PATH="$T/bin:$PATH"
export HOME="$T/home"
export LC_ALL=C
export VX_BIN="$T/vxbin/vx"
export VX_BACKUP="$T/vxbin/vx-install.sh"
mkdir -p "$T/vxbin"
SYSFS="$T/run/sysfs"
nic_set() {
  mkdir -p "$SYSFS/eth0/statistics"
  printf '%s' "$1" > "$SYSFS/eth0/statistics/rx_bytes"
  printf '%s' "$2" > "$SYSFS/eth0/statistics/tx_bytes"
}

PASS=0
FAIL=0
SCRIPT=/home/hatch/workspace/vx/install.sh
WATCH=/usr/local/bin/traffic-watch
CONF=/usr/local/etc/xray/traffic.conf
STATE=/usr/local/etc/xray/traffic.json

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}
check_out() {
  local name="$1" file="$2" pat="$3"
  if grep -qF "$pat" "$file" 2>/dev/null; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}
check_eq() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (got=$got want=$want)"; fi
}
check_nofile() {
  local name="$1" file="$2"
  if [ ! -e "$file" ]; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name ($file exists)"; fi
}
no_comments() { [ -z "$(grep '^#' "$SCRIPT" | grep -v '^#!')" ]; }
no_relay() { ! grep -qi "中转\|RELAY\|relay" "$SCRIPT"; }

setup_run() {
  rm -rf "$T/run" "$T/home/.acme.sh"
  mkdir -p "$T/run" "$T/home"
  echo 1 > "$T/run/xray.active"
  echo 0 > "$T/run/tc.root"
  echo 0 > "$T/run/tc.ingress"
  : > "$T/run/log"
  : > "$T/run/ipt.rules"
  : > "$T/run/ipt.counters"
  mkdir -p "$T/run/sysfs/eth0/statistics"
  echo 0 > "$T/run/sysfs/eth0/statistics/rx_bytes"
  echo 0 > "$T/run/sysfs/eth0/statistics/tx_bytes"
}

clean_sys() {
  rm -rf /usr/local/etc/xray /root/install-info.txt /root/split-a.json /root/split-b.json
  rm -f /usr/local/bin/traffic-watch /etc/systemd/system/traffic-watch.service /etc/systemd/system/traffic-watch.timer
  rm -f /usr/local/bin/vx /usr/local/bin/vx-install.sh
}

write_conf() {
  mkdir -p "$(dirname "$CONF")"
  cat > "$CONF" <<EOF
TQ_MODE=$1
TQ_PERIOD=$2
TQ_START=$3
TQ_LIMIT=$4
TQ_QUOTA=$5
TQ_RATE=$6
TQ_PORT=$7
TQ_PRESET=custom
EOF
}

watch() { "$WATCH" "$@"; }
state_get() { jq -r "$1 // empty" "$STATE" 2>/dev/null || true; }
geodata_on() { mkdir -p /usr/local/share/xray; printf 'GEOSITE' > /usr/local/share/xray/geosite.dat; }

echo "=== T0: script hygiene ==="
check "T0a no descriptive comments" no_comments
check "T0b no relay references" no_relay
check "T0c README unchanged" test -f /home/hatch/workspace/vx/README.md

echo "=== T1: basic install ==="
setup_run; clean_sys; geodata_on
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install1.out" 2>&1
check_eq "T1a install exit 0" "$?" "0"
check "T1b config valid json" jq -e . /usr/local/etc/xray/config.json
check_eq "T1c config port 443" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "443"
check_eq "T1d config path /api" "$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' /usr/local/etc/xray/config.json)" "/api"
check_eq "T1e server mode auto" "$(jq -r '.inbounds[0].streamSettings.xhttpSettings.mode' /usr/local/etc/xray/config.json)" "auto"
check_eq "T1f security reality" "$(jq -r '.inbounds[0].streamSettings.security' /usr/local/etc/xray/config.json)" "reality"
check_nofile "T1g SPLIT=0 no split-a" /root/split-a.json
check "T1h info exists" test -f /root/install-info.txt
check_out "T1i info mode Reality" /root/install-info.txt "模式：Reality"
check_out "T1j info link mode auto" /root/install-info.txt "mode=auto"
check "T1k watcher installed" test -x "$WATCH"
check "T1l traffic.conf exists" test -f "$CONF"
check_eq "T1m xray active" "$(cat "$T/run/xray.active")" "1"

echo "=== T1b: install with quota (SPLIT=1) ==="
setup_run; clean_sys; geodata_on
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=1 TQ_QUOTA=100G \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install1b.out" 2>&1
check_eq "T1b1 install exit 0" "$?" "0"
check "T1b2 split-a exists" test -f /root/split-a.json
check "T1b3 split-b exists" test -f /root/split-b.json
check_eq "T1b4 split-a mode stream-up" "$(jq -r '.outbounds[0].streamSettings.xhttpSettings.mode' /root/split-a.json)" "stream-up"
check_out "T1b5 info link stream-up" /root/install-info.txt "mode=stream-up"
check_eq "T1b6 conf quota 100G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "107374182400"
check_out "T1b7 info quota 100 GB" /root/install-info.txt "限额：100.00 GB"

echo "=== T6: edit preserves TQ_* ==="
setup_run
write_conf total monthly 1 block 0 128000 443
rm -f "$STATE"
watch run
nic_set 1500000 3000000
watch run
printf '\n\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit6a.out" 2>&1
check_eq "T6a1 edit exit 0" "$?" "0"
check_eq "T6a2 edit keeps in" "$(state_get '.in')" "1500000"
check_eq "T6a3 edit keeps out" "$(state_get '.out')" "3000000"
check_eq "T6a4 conf mode total" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "total"
check_eq "T6a5 conf quota 0" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "0"
if grep -q "统计 \[出站" "$T/run/edit6a.out"; then FAIL=$((FAIL+1)); echo "FAIL: T6a6 no 统计 prompt"; else PASS=$((PASS+1)); echo "PASS: T6a6 no 统计 prompt"; fi
if grep -q "限额 \[" "$T/run/edit6a.out"; then FAIL=$((FAIL+1)); echo "FAIL: T6a7 no 限额 prompt"; else PASS=$((PASS+1)); echo "PASS: T6a7 no 限额 prompt"; fi
if grep -q "分流 \[1 开" "$T/run/edit6a.out"; then FAIL=$((FAIL+1)); echo "FAIL: T6a8 no 分流 prompt"; else PASS=$((PASS+1)); echo "PASS: T6a8 no 分流 prompt"; fi
if grep -q "新路径 \[" "$T/run/edit6a.out"; then FAIL=$((FAIL+1)); echo "FAIL: T6a9 no 路径 prompt"; else PASS=$((PASS+1)); echo "PASS: T6a9 no 路径 prompt"; fi
if grep -q "新 UUID \[" "$T/run/edit6a.out"; then FAIL=$((FAIL+1)); echo "FAIL: T6a10 no UUID prompt"; else PASS=$((PASS+1)); echo "PASS: T6a10 no UUID prompt"; fi
check_eq "T6a11 port kept 443" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "443"
printf '8443\n\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit6b.out" 2>&1
check_eq "T6b1 edit port exit 0" "$?" "0"
check_eq "T6b2 config port 8443" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "8443"
check_eq "T6b3 conf TQ_PORT 8443" "$(grep '^TQ_PORT=' "$CONF" | cut -d= -f2)" "8443"
check_eq "T6b4 conf mode still total" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "total"
check_eq "T6b5 conf quota still 0" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "0"
check_eq "T6b6 counters kept in" "$(state_get '.in')" "1500000"
check_eq "T6b7 counters kept out" "$(state_get '.out')" "3000000"
check_out "T6b8 info port 8443" /root/install-info.txt "端口：8443"
printf '\n\n' | env ACTION=edit TQ_QUOTA=600G bash "$SCRIPT" > "$T/run/edit6c.out" 2>&1
check_eq "T6c1 edit exit 0" "$?" "0"
check_eq "T6c2 edit ignores TQ_QUOTA env" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "0"

echo "=== T9: watcher enforcement ==="
setup_run
write_conf total monthly 1 block 1000000 128000 443
rm -f "$STATE"
watch run
check_eq "T9a1 baseline in 0" "$(state_get '.in')" "0"
nic_set 600000 600000
watch run
check_eq "T9a2 counted in 600000" "$(state_get '.in')" "600000"
check_eq "T9a3 counted out 600000" "$(state_get '.out')" "600000"
check_eq "T9a4 over quota enforced block" "$(state_get '.enforced')" "block"
check_eq "T9a5 xray stopped" "$(cat "$T/run/xray.active")" "0"
write_conf total monthly 1 block 0 128000 443
watch run
check_eq "T9a6 quota 0 recovers xray" "$(cat "$T/run/xray.active")" "1"
check_eq "T9a7 enforced cleared" "$(state_get '.enforced')" ""
check_eq "T9a8 counters kept in" "$(state_get '.in')" "600000"
setup_run
write_conf total monthly 1 throttle 1000000 125000 443
rm -f "$STATE"
watch run
nic_set 600000 600000
watch run
check_eq "T9b1 throttle enforced" "$(state_get '.enforced')" "throttle"
check_eq "T9b2 tc root present" "$(cat "$T/run/tc.root")" "1"
write_conf total monthly 1 throttle 0 125000 443
watch run
check_eq "T9b3 throttle cleared" "$(state_get '.enforced')" ""
check_eq "T9b4 tc root cleared" "$(cat "$T/run/tc.root")" "0"
setup_run
write_conf max monthly 1 block 1500000 128000 443
rm -f "$STATE"
watch run
nic_set 1400000 100000
watch run
check_eq "T9c1 max 1400000 < quota, no block" "$(state_get '.enforced')" ""
check_eq "T9c2 xray still active" "$(cat "$T/run/xray.active")" "1"
nic_set 1400000 200000
watch run
check_eq "T9c3 max still 1400000 < quota" "$(state_get '.enforced')" ""
nic_set 1600000 200000
watch run
check_eq "T9c4 max 1600000 >= quota, block" "$(state_get '.enforced')" "block"
setup_run
write_conf total monthly 1 block 0 128000 443
rm -f "$STATE"
watch run
nic_set 500000 500000
watch run
check_eq "T9d1 setup in 500000" "$(state_get '.in')" "500000"
write_conf out monthly 1 block 0 128000 443
watch run
check_eq "T9d2 signature change resets in" "$(state_get '.in')" "0"
check_eq "T9d3 signature change resets out" "$(state_get '.out')" "0"

echo "=== T11: bare quota = G, SPLIT default Y, no MODE question ==="
setup_run; clean_sys
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=180 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install11a.out" 2>&1
check_eq "T11a1 bare 180 -> 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_out "T11a2 info quota 180 GB" /root/install-info.txt "限额：180.00 GB"
setup_run; clean_sys
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=1T \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install11b.out" 2>&1
check_eq "T11b bare 1T" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "1099511627776"
setup_run; clean_sys
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=500M TQ_LIMIT=throttle TQ_RATE=250000 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install11c.out" 2>&1
check_eq "T11c 500M quota" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "524288000"
check_eq "T11d bare rate stays bytes" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "250000"
setup_run; clean_sys
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=180 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install11e.out" 2>&1
check_eq "T11e env 180 -> 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
setup_run; clean_sys
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install11f.out" 2>&1
check "T11f default SPLIT -> on, split-a exists" test -f /root/split-a.json
check_out "T11g empty SPLIT link stream-up" /root/install-info.txt "mode=stream-up"
setup_run; clean_sys
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install11h.out" 2>&1
check_nofile "T11h env SPLIT=0 -> off, no split-a" /root/split-a.json
setup_run; clean_sys
env ACTION=install REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install11i.out" 2>&1
check_eq "T11i no MODE -> exit 0" "$?" "0"
check_eq "T11j no MODE -> reality" "$(jq -r '.inbounds[0].streamSettings.security' /usr/local/etc/xray/config.json)" "reality"
check_out "T11k info mode Reality" /root/install-info.txt "模式：Reality"
if grep -q "方式：" "$T/run/install11i.out"; then FAIL=$((FAIL+1)); echo "FAIL: T11l no mode question"; else PASS=$((PASS+1)); echo "PASS: T11l no mode question"; fi
if grep -q "选择 \[1/2" "$T/run/install11i.out"; then FAIL=$((FAIL+1)); echo "FAIL: T11m no 1/2 prompt"; else PASS=$((PASS+1)); echo "PASS: T11m no 1/2 prompt"; fi
setup_run
write_conf total monthly 1 block 536870912000 128000 443
rm -f "$STATE"
watch run
printf '\n\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit11n.out" 2>&1
check_eq "T11n edit keep quota 500G bytes" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "536870912000"
printf '\n\n' | env ACTION=edit TQ_QUOTA=180 bash "$SCRIPT" > "$T/run/edit11o.out" 2>&1
check_eq "T11o edit ignores TQ_QUOTA env" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "536870912000"

echo "=== T12: SNI pools + Chinese prompts ==="
pool_hk="www.hkust.edu.hk www.gov.hk www.hko.gov.hk www.hkpl.gov.hk"
pool_jp="www.yahoo.co.jp www.rakuten.co.jp www.osaka-u.ac.jp www.kyushu-u.ac.jp"
pool_sg="www.shopee.sg www.lazada.sg www.mti.gov.sg www.acm.org.sg"
pool_us="www.whitney.org www.okstate.edu www.oregonstate.edu www.ufl.edu"
check_eq "T12e0 no big-tech/banned SNI" "$(grep -E 'apple|google|cloudflare|wikipedia|microsoft|amazon|bing\.com|mozilla|yahoo\.com' "$SCRIPT" | grep -vc 'geosite:')" "0"
in_pool() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
info_sni() { grep '^SNI：' /root/install-info.txt | awk -F'：' '{print $NF}'; }
for r in hk jp sg us; do
  setup_run; clean_sys
  env ACTION=install MODE=reality REGION=$r PORT=443 XHTTP_PATH=/api \
    UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
    PUBLIC_IP=198.51.100.20 \
    bash "$SCRIPT" < /dev/null > "$T/run/install12-$r.out" 2>&1
  sni="$(info_sni)"
  vn="pool_$r"; pool="${!vn}"
  check "T12a-$r SNI $sni in pool" in_pool "$sni" "$pool"
done
seen=""
for i in $(seq 1 10); do
  setup_run; clean_sys
  env ACTION=install MODE=reality REGION=us PORT=443 XHTTP_PATH=/api \
    UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
    PUBLIC_IP=198.51.100.20 \
    bash "$SCRIPT" < /dev/null > "$T/run/install12-rand$i.out" 2>&1
  seen="$seen $(info_sni)"
done
distinct=$(printf '%s\n' $seen | sort -u | wc -l)
if [ "$distinct" -ge 2 ]; then PASS=$((PASS+1)); echo "PASS: T12a-rand us 10 installs $distinct distinct SNI"; else FAIL=$((FAIL+1)); echo "FAIL: T12a-rand us 10 installs only $distinct distinct SNI"; fi
setup_run; clean_sys
env ACTION=install MODE=reality REALITY_TARGET=sni.example.com PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install12b1.out" 2>&1
check_out "T12b1 custom SNI via env" /root/install-info.txt "SNI：sni.example.com"
setup_run; clean_sys
printf '5\nsni.example.com\n\n\n\n\n\n' | env ACTION=install MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" > "$T/run/install12b2.out" 2>&1
check_out "T12b2 custom SNI interactive" /root/install-info.txt "SNI：sni.example.com"
setup_run; clean_sys
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install12c.out" 2>&1
sni0="$(info_sni)"
check "T12c0 setup SNI in hk pool" in_pool "$sni0" "$pool_hk"
setup_run
printf '\n\n' | env ACTION=edit REGION=hk bash "$SCRIPT" > "$T/run/edit12c1.out" 2>&1
check_eq "T12c1 edit same region keeps SNI" "$(info_sni)" "$sni0"
setup_run
printf '\n\n' | env ACTION=edit REGION=jp bash "$SCRIPT" > "$T/run/edit12c2.out" 2>&1
sni1="$(info_sni)"
check "T12c2 edit region jp SNI in jp pool" in_pool "$sni1" "$pool_jp"
setup_run
printf '\n1\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit12c3.out" 2>&1
sni2="$(info_sni)"
check "T12c3 edit interactive pick 1 SNI in hk pool" in_pool "$sni2" "$pool_hk"
setup_run
printf '\n\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit12c4.out" 2>&1
check_eq "T12c4 edit interactive Enter keeps SNI" "$(info_sni)" "$sni2"
check_eq "T12d1 no Description=traffic" "$(grep -c 'Description=traffic' "$SCRIPT")" "0"
check_eq "T12d2 no out/in/total/max prompt" "$(grep -c 'out/in/total/max' "$SCRIPT")" "0"
check_eq "T12d3 no monthly/quarterly/yearly prompt" "$(grep -c 'monthly/quarterly/yearly' "$SCRIPT")" "0"
check_eq "T12d4 no block/throttle prompt" "$(grep -c 'block/throttle' "$SCRIPT")" "0"
check_eq "T12d5 no 统计 prompt" "$(grep -c '统计 \[出站' "$SCRIPT")" "0"
check_eq "T12d6 no 周期 prompt" "$(grep -c '周期 \[月' "$SCRIPT")" "0"
check_eq "T12d7 no 限制 prompt" "$(grep -c '限制 \[阻断' "$SCRIPT")" "0"
if grep -qwE 'monthly|quarterly|yearly|block|throttle' "$T/run/install12-hk.out" "$T/run/edit12c1.out" /root/install-info.txt 2>/dev/null || grep -qF 'out/in/total/max' "$T/run/install12-hk.out" "$T/run/edit12c1.out" /root/install-info.txt 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL: T12d8 no English prompt words in output"; else PASS=$((PASS+1)); echo "PASS: T12d8 no English prompt words in output"; fi

echo "=== T13: whole-VPS NIC counting ==="
setup_run
write_conf total monthly 1 block 0 128000 443
rm -f "$STATE"
watch run
nic_set 1000000 2000000
watch run
check_eq "T13a1 in 1000000" "$(state_get '.in')" "1000000"
check_eq "T13a2 out 2000000" "$(state_get '.out')" "2000000"
check_eq "T13a3 scope host" "$(state_get '.scope')" "host"
nic_set 500000 1000000
watch run
check_eq "T13b1 reboot no negative in" "$(state_get '.in')" "1000000"
check_eq "T13b2 reboot no negative out" "$(state_get '.out')" "2000000"
check_eq "T13b3 re-baselined last_in" "$(state_get '.last_in')" "500000"
check_eq "T13b4 re-baselined last_out" "$(state_get '.last_out')" "1000000"
nic_set 600000 1200000
watch run
check_eq "T13b5 after reboot delta in" "$(state_get '.in')" "1100000"
check_eq "T13b6 after reboot delta out" "$(state_get '.out')" "2200000"
setup_run
iptables -A INPUT -p tcp --dport 443
iptables -A OUTPUT -p tcp --sport 443
jq -n '{in: 5000000, out: 6000000, last_in: 600000, last_out: 1200000, period_start: 1, period_end: 9999999999, mode: "total", period: "monthly", start_day: 1, port: 443, enforced: ""}' > "$STATE"
watch run
check_eq "T13c1 scope switch resets in" "$(state_get '.in')" "0"
check_eq "T13c2 scope switch resets out" "$(state_get '.out')" "0"
check_eq "T13c3 scope now host" "$(state_get '.scope')" "host"
if grep -q "dport 443" "$T/run/ipt.rules" 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL: T13c4 old INPUT rule deleted"; else PASS=$((PASS+1)); echo "PASS: T13c4 old INPUT rule deleted"; fi
if grep -q "sport 443" "$T/run/ipt.rules" 2>/dev/null; then FAIL=$((FAIL+1)); echo "FAIL: T13c5 old OUTPUT rule deleted"; else PASS=$((PASS+1)); echo "PASS: T13c5 old OUTPUT rule deleted"; fi
setup_run
write_conf total monthly 1 block 0 128000 443
rm -f "$STATE"
watch run
rm -rf "$T/run/sysfs/eth0"
watch run
check_eq "T13d1 unreadable sysfs keeps in 0" "$(state_get '.in')" "0"

echo "=== T14: traffic presets (GCP/CDT) ==="
geodata_on() { mkdir -p /usr/local/share/xray; printf 'GEOSITE' > /usr/local/share/xray/geosite.dat; }
geodata_on

echo "--- T14a: add then preset GCP (REGION=hk -> override us) ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add14a.out" 2>&1
check_eq "T14a0 add exit 0" "$?" "0"
check_eq "T14a0b add preset custom" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "custom"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T14a0c add no routing"; else PASS=$((PASS+1)); echo "PASS: T14a0c add no routing"; fi
setup_run
env ACTION=preset TQ_PRESET=gcp bash "$SCRIPT" < /dev/null > "$T/run/preset14a.out" 2>&1
check_eq "T14a1 preset exit 0" "$?" "0"
check_eq "T14a2 conf preset gcp" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_eq "T14a3 conf quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T14a4 conf mode total" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "total"
check_eq "T14a5 conf period monthly" "$(grep '^TQ_PERIOD=' "$CONF" | cut -d= -f2)" "monthly"
check_eq "T14a6 conf start 1" "$(grep '^TQ_START=' "$CONF" | cut -d= -f2)" "1"
check_eq "T14a7 conf limit block" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "block"
check_eq "T14a7b conf rate 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
check_eq "T14a8 routing geosite google" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
check_eq "T14a9 routing domain list is only google" "$(jq -r '.routing.rules[0].domain | join(",")' /usr/local/etc/xray/config.json)" "geosite:google"
if jq -r '.routing' /usr/local/etc/xray/config.json | grep -qi github; then FAIL=$((FAIL+1)); echo "FAIL: T14a9b no github in routing"; else PASS=$((PASS+1)); echo "PASS: T14a9b no github in routing"; fi
check_eq "T14a10 routing allow direct" "$(jq -r '.routing.rules[0].outboundTag' /usr/local/etc/xray/config.json)" "direct"
check_eq "T14a11 routing catch-all blocked" "$(jq -r '.routing.rules[1].outboundTag' /usr/local/etc/xray/config.json)" "blocked"
check_eq "T14a12 blocked outbound blackhole" "$(jq -r '.outbounds[] | select(.tag=="blocked") | .protocol' /usr/local/etc/xray/config.json)" "blackhole"
check_eq "T14a13 direct outbound freedom" "$(jq -r '.outbounds[] | select(.tag=="direct") | .protocol' /usr/local/etc/xray/config.json)" "freedom"
check_eq "T14a14 sniffing enabled" "$(jq -r '.inbounds[0].sniffing.enabled' /usr/local/etc/xray/config.json)" "true"
check_eq "T14a15 sniffing destOverride" "$(jq -r '.inbounds[0].sniffing.destOverride | join(",")' /usr/local/etc/xray/config.json)" "http,tls,quic"
check "T14a16 config valid json" jq -e . /usr/local/etc/xray/config.json
check_out "T14a17 info preset GCP" /root/install-info.txt "套餐：GCP"
check_out "T14a17b info rate unlimited" /root/install-info.txt "限速：不限速"
check_out "T14a18 info whitelist" /root/install-info.txt "白名单：仅谷歌系"
check_out "T14a19 info region 美国" /root/install-info.txt "地区：美国"
check "T14a20 info SNI in us pool" in_pool "$(info_sni)" "$pool_us"
check_out "T14a21 show-traffic preset" <(bash "$SCRIPT" --show-traffic 2>&1) "套餐：GCP"
check_out "T14a22 show-traffic whitelist" <(bash "$SCRIPT" --show-traffic 2>&1) "白名单：仅谷歌系"
check "T14a23 geosite.dat present" test -s /usr/local/share/xray/geosite.dat

echo "--- T14b: add then preset CDT (REGION=us -> override hk) ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=us PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add14b.out" 2>&1
check_eq "T14b0 add exit 0" "$?" "0"
setup_run
env ACTION=preset TQ_PRESET=cdt bash "$SCRIPT" < /dev/null > "$T/run/preset14b.out" 2>&1
check_eq "T14b1 preset exit 0" "$?" "0"
check_eq "T14b2 conf preset cdt" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "cdt"
check_eq "T14b3 conf quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T14b4 conf mode max" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "max"
check_eq "T14b5 conf period monthly" "$(grep '^TQ_PERIOD=' "$CONF" | cut -d= -f2)" "monthly"
check_eq "T14b6 conf start 1" "$(grep '^TQ_START=' "$CONF" | cut -d= -f2)" "1"
check_eq "T14b7 conf limit block" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "block"
check_eq "T14b7b conf rate 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
if grep -q geosite /usr/local/etc/xray/config.json; then FAIL=$((FAIL+1)); echo "FAIL: T14b8 config no geosite"; else PASS=$((PASS+1)); echo "PASS: T14b8 config no geosite"; fi
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T14b9 config no routing"; else PASS=$((PASS+1)); echo "PASS: T14b9 config no routing"; fi
check "T14b10 config valid json" jq -e . /usr/local/etc/xray/config.json
check_out "T14b11 info preset CDT" /root/install-info.txt "套餐：阿里云CDT"
check_out "T14b11b info rate unlimited" /root/install-info.txt "限速：不限速"
check_out "T14b12 info region 香港" /root/install-info.txt "地区：香港"
check "T14b13 info SNI in hk pool" in_pool "$(info_sni)" "$pool_hk"
if grep -q "白名单" /root/install-info.txt; then FAIL=$((FAIL+1)); echo "FAIL: T14b14 no whitelist line"; else PASS=$((PASS+1)); echo "PASS: T14b14 no whitelist line"; fi
check_out "T14b15 show-traffic preset CDT" <(bash "$SCRIPT" --show-traffic 2>&1) "套餐：阿里云CDT"

echo "--- T14c: preset GCP -> CDT ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add14c0.out" 2>&1
check_eq "T14c0a setup add exit 0" "$?" "0"
setup_run
env ACTION=preset TQ_PRESET=gcp bash "$SCRIPT" < /dev/null > "$T/run/preset14c0.out" 2>&1
check_eq "T14c0b setup preset gcp exit 0" "$?" "0"
check "T14c0 setup GCP SNI in us pool" in_pool "$(info_sni)" "$pool_us"
setup_run
env ACTION=preset TQ_PRESET=cdt bash "$SCRIPT" < /dev/null > "$T/run/preset14c1.out" 2>&1
check_eq "T14c1 preset exit 0" "$?" "0"
check_eq "T14c2 conf preset cdt" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "cdt"
check_eq "T14c3 conf mode max" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "max"
check_eq "T14c4 conf quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T14c4b conf rate 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
if grep -q geosite /usr/local/etc/xray/config.json; then FAIL=$((FAIL+1)); echo "FAIL: T14c5 config no geosite"; else PASS=$((PASS+1)); echo "PASS: T14c5 config no geosite"; fi
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T14c6 config no routing"; else PASS=$((PASS+1)); echo "PASS: T14c6 config no routing"; fi
check_out "T14c7 info preset CDT" /root/install-info.txt "套餐：阿里云CDT"
check_out "T14c7b info rate unlimited" /root/install-info.txt "限速：不限速"
check_out "T14c8 info region 香港" /root/install-info.txt "地区：香港"
check "T14c9 info SNI in hk pool" in_pool "$(info_sni)" "$pool_hk"
if grep -q "白名单" /root/install-info.txt; then FAIL=$((FAIL+1)); echo "FAIL: T14c10 no whitelist line"; else PASS=$((PASS+1)); echo "PASS: T14c10 no whitelist line"; fi

echo "--- T14d: preset CDT -> GCP -> custom ---"
setup_run
env ACTION=preset TQ_PRESET=gcp bash "$SCRIPT" < /dev/null > "$T/run/preset14d1.out" 2>&1
check_eq "T14d1 preset exit 0" "$?" "0"
check_eq "T14d2 conf preset gcp" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_eq "T14d3 routing geosite google" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
check_eq "T14d4 routing catch-all blocked" "$(jq -r '.routing.rules[1].outboundTag' /usr/local/etc/xray/config.json)" "blocked"
check_eq "T14d5 sniffing enabled" "$(jq -r '.inbounds[0].sniffing.enabled' /usr/local/etc/xray/config.json)" "true"
check_out "T14d6 info preset GCP" /root/install-info.txt "套餐：GCP"
check_out "T14d7 info whitelist" /root/install-info.txt "白名单：仅谷歌系"
check_out "T14d8 info region 美国" /root/install-info.txt "地区：美国"
check "T14d9 info SNI in us pool" in_pool "$(info_sni)" "$pool_us"
setup_run
env ACTION=preset TQ_PRESET=custom bash "$SCRIPT" < /dev/null > "$T/run/preset14d2.out" 2>&1
check_eq "T14d10 preset exit 0" "$?" "0"
check_eq "T14d11 conf preset custom" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "custom"
if grep -q geosite /usr/local/etc/xray/config.json; then FAIL=$((FAIL+1)); echo "FAIL: T14d12 config no geosite"; else PASS=$((PASS+1)); echo "PASS: T14d12 config no geosite"; fi
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T14d13 config no routing"; else PASS=$((PASS+1)); echo "PASS: T14d13 config no routing"; fi
check_out "T14d14 info preset 自定义" /root/install-info.txt "套餐：自定义"
if grep -q "白名单" /root/install-info.txt; then FAIL=$((FAIL+1)); echo "FAIL: T14d15 no whitelist line"; else PASS=$((PASS+1)); echo "PASS: T14d15 no whitelist line"; fi
check_out "T14d16 custom keeps region 美国" /root/install-info.txt "地区：美国"

echo "--- T14e: interactive preset Enter keeps preset + whitelist ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add14e.out" 2>&1
check_eq "T14e0 setup add exit 0" "$?" "0"
setup_run
env ACTION=preset TQ_PRESET=gcp bash "$SCRIPT" < /dev/null > "$T/run/preset14e0.out" 2>&1
check_eq "T14e0b setup preset gcp exit 0" "$?" "0"
sni_e0="$(info_sni)"
setup_run
printf '\n' | env ACTION=preset bash "$SCRIPT" > "$T/run/preset14e1.out" 2>&1
check_eq "T14e1 preset Enter exit 0" "$?" "0"
check_eq "T14e2 conf preset still gcp" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_eq "T14e3 routing geosite still" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
check_eq "T14e4 SNI kept" "$(info_sni)" "$sni_e0"
check_out "T14e5 info preset GCP" /root/install-info.txt "套餐：GCP"
check_out "T14e6 info whitelist" /root/install-info.txt "白名单：仅谷歌系"
check_out "T14e7 show-traffic preset" <(bash "$SCRIPT" --show-traffic 2>&1) "套餐：GCP"

echo "--- T14f: geosite.dat missing fails closed ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add14f0.out" 2>&1
check_eq "T14f0 setup add exit 0" "$?" "0"
setup_run
env ACTION=preset TQ_PRESET=gcp bash "$SCRIPT" < /dev/null > "$T/run/preset14f0b.out" 2>&1
check_eq "T14f0b setup preset gcp exit 0" "$?" "0"
rm -f /usr/local/share/xray/geosite.dat
setup_run
env ACTION=preset TQ_PRESET=gcp bash "$SCRIPT" < /dev/null > "$T/run/preset14f1.out" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then PASS=$((PASS+1)); echo "PASS: T14f1 preset no geosite fails"; else FAIL=$((FAIL+1)); echo "FAIL: T14f1 preset no geosite must fail (rc=$RC)"; fi
check_eq "T14f2 config untouched, routing still there" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
check_eq "T14f2b conf preset still gcp" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
geodata_on
setup_run; clean_sys
rm -f /usr/local/share/xray/geosite.dat
env ACTION=add MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add14f3.out" 2>&1
check_eq "T14f3 add without geosite exit 0" "$?" "0"
setup_run
env ACTION=preset TQ_PRESET=gcp bash "$SCRIPT" < /dev/null > "$T/run/preset14f4.out" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then PASS=$((PASS+1)); echo "PASS: T14f4 preset no geosite fails"; else FAIL=$((FAIL+1)); echo "FAIL: T14f4 preset no geosite must fail (rc=$RC)"; fi
check_eq "T14f5 conf preset still custom" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "custom"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T14f6 config no routing"; else PASS=$((PASS+1)); echo "PASS: T14f6 config no routing"; fi
geodata_on

echo "--- T14g: interactive preset 1 = GCP ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add14g.out" 2>&1
check_eq "T14g0 setup add exit 0" "$?" "0"
setup_run
printf '1\n' | env ACTION=preset bash "$SCRIPT" > "$T/run/preset14g.out" 2>&1
check_eq "T14g1 preset exit 0" "$?" "0"
check_eq "T14g2 conf preset gcp" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_eq "T14g3 conf quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T14g3b conf rate 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
check_eq "T14g4 routing geosite google" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
check_out "T14g5 info region 美国" /root/install-info.txt "地区：美国"
check "T14g6 info SNI in us pool" in_pool "$(info_sni)" "$pool_us"

echo "--- T14h: interactive preset 2 = CDT ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=us PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add14h.out" 2>&1
check_eq "T14h0 setup add exit 0" "$?" "0"
setup_run
printf '2\n' | env ACTION=preset bash "$SCRIPT" > "$T/run/preset14h.out" 2>&1
check_eq "T14h1 preset exit 0" "$?" "0"
check_eq "T14h2 conf preset cdt" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "cdt"
check_eq "T14h3 conf mode max" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "max"
check_eq "T14h3b conf rate 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
check_out "T14h4 info region 香港" /root/install-info.txt "地区：香港"
check_out "T14h4b info rate unlimited" /root/install-info.txt "限速：不限速"
check "T14h5 info SNI in hk pool" in_pool "$(info_sni)" "$pool_hk"

echo "--- T14i: bad preset fails ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add14i.out" 2>&1
check_eq "T14i0 setup add exit 0" "$?" "0"
setup_run
printf '9\n' | env ACTION=preset bash "$SCRIPT" > "$T/run/preset14i1.out" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then PASS=$((PASS+1)); echo "PASS: T14i1 bad preset 9 fails"; else FAIL=$((FAIL+1)); echo "FAIL: T14i1 bad preset 9 must fail (rc=$RC)"; fi
check_eq "T14i1b conf preset still custom" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "custom"
setup_run
env ACTION=preset TQ_PRESET=bogus bash "$SCRIPT" < /dev/null > "$T/run/preset14i2.out" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then PASS=$((PASS+1)); echo "PASS: T14i2 bad TQ_PRESET fails"; else FAIL=$((FAIL+1)); echo "FAIL: T14i2 bad TQ_PRESET must fail (rc=$RC)"; fi
check_eq "T14i2b conf preset still custom" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "custom"

echo "--- T14k: default add is custom ---"
setup_run; clean_sys; geodata_on
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install14k.out" 2>&1
check_eq "T14k1 install exit 0" "$?" "0"
check_out "T14k2 info preset 自定义" /root/install-info.txt "套餐：自定义"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T14k3 config no routing"; else PASS=$((PASS+1)); echo "PASS: T14k3 config no routing"; fi
check_out "T14k4 show-traffic preset 自定义" <(bash "$SCRIPT" --show-traffic 2>&1) "套餐：自定义"
check_eq "T14k5 conf preset custom" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "custom"

echo "=== T15: new 5-item menu ==="
# T14k leaves a node installed; menu shows when a node exists.
echo "--- T15a: main menu 6 items, Enter defaults to view ---"
setup_run
printf '\n6\n' | env bash "$SCRIPT" > "$T/run/menu15a.out" 2>&1
check_eq "T15a1 menu Enter exit 0" "$?" "0"
check_out "T15a2 menu item 1 添加节点" "$T/run/menu15a.out" "1) 添加节点"
check_out "T15a3 menu item 2 查看节点" "$T/run/menu15a.out" "2) 查看节点"
check_out "T15a4 menu item 3 编辑节点" "$T/run/menu15a.out" "3) 编辑节点"
check_out "T15a5 menu item 4 删除节点" "$T/run/menu15a.out" "4) 删除节点"
check_out "T15a6 menu item 5 载入预设" "$T/run/menu15a.out" "5) 载入预设"
check_out "T15a6b menu item 6 退出脚本" "$T/run/menu15a.out" "6) 退出脚本"
check_out "T15a7 menu default 2" "$SCRIPT" "请选择 [1-6，默认 2]"
if grep -q "修改配置" "$T/run/menu15a.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15a8 no old 修改配置"; else PASS=$((PASS+1)); echo "PASS: T15a8 no old 修改配置"; fi
if grep -q "重新安装" "$T/run/menu15a.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15a9 no old 重新安装"; else PASS=$((PASS+1)); echo "PASS: T15a9 no old 重新安装"; fi
check_out "T15a10 Enter shows node info" "$T/run/menu15a.out" "地址："
printf '2\n' | env bash "$SCRIPT" > "$T/run/menu15a2.out" 2>&1
check_eq "T15a11 menu 2 exit 0" "$?" "0"
check_out "T15a12 menu 2 shows node info" "$T/run/menu15a2.out" "地址："
setup_run
printf '1\n' | env MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" > "$T/run/menu15a3.out" 2>&1
check_eq "T15a13 menu 1 (add) exit 0" "$?" "0"

echo "--- T15b: add asks no path/split/BBR/traffic, defaults /api on on count-only ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=hk PORT=443 \
  UUID=11111111-2222-3333-4444-555555555555 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add15b.out" 2>&1
check_eq "T15b0 add exit 0" "$?" "0"
if grep -q "路径 \[" "$T/run/add15b.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15b1 no path prompt"; else PASS=$((PASS+1)); echo "PASS: T15b1 no path prompt"; fi
if grep -q "分流 \[" "$T/run/add15b.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15b2 no split prompt"; else PASS=$((PASS+1)); echo "PASS: T15b2 no split prompt"; fi
if grep -q "BBR \[" "$T/run/add15b.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15b3 no BBR prompt"; else PASS=$((PASS+1)); echo "PASS: T15b3 no BBR prompt"; fi
if grep -q "套餐 \[" "$T/run/add15b.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15b4 no preset prompt"; else PASS=$((PASS+1)); echo "PASS: T15b4 no preset prompt"; fi
if grep -q "限额 \[" "$T/run/add15b.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15b5 no quota prompt"; else PASS=$((PASS+1)); echo "PASS: T15b5 no quota prompt"; fi
if grep -q "统计 \[" "$T/run/add15b.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15b6 no mode prompt"; else PASS=$((PASS+1)); echo "PASS: T15b6 no mode prompt"; fi
check_eq "T15b7 default path /api" "$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' /usr/local/etc/xray/config.json)" "/api"
check "T15b8 split default on (split-a exists)" test -f /root/split-a.json
check_out "T15b9 BBR default on" "$T/run/add15b.out" "BBR：开启"
check_eq "T15b10 default quota 0 count-only" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "0"
check_eq "T15b11 default mode total" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "total"
check_eq "T15b12 default period monthly" "$(grep '^TQ_PERIOD=' "$CONF" | cut -d= -f2)" "monthly"
check_eq "T15b13 default start 1" "$(grep '^TQ_START=' "$CONF" | cut -d= -f2)" "1"
check_eq "T15b14 default limit block" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "block"
check_eq "T15b15 default rate 125K" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "128000"
check_eq "T15b16 default preset custom" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "custom"
check_eq "T15b17 split-a mode stream-up" "$(jq -r '.outbounds[0].streamSettings.xhttpSettings.mode' /root/split-a.json)" "stream-up"

echo "--- T15c: edit asks no traffic/path/split/BBR, TQ_* kept ---"
setup_run
printf '\n\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit15c.out" 2>&1
check_eq "T15c0 edit exit 0" "$?" "0"
if grep -q "统计 \[出站" "$T/run/edit15c.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15c1 no 统计 prompt"; else PASS=$((PASS+1)); echo "PASS: T15c1 no 统计 prompt"; fi
if grep -q "限额 \[" "$T/run/edit15c.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15c2 no 限额 prompt"; else PASS=$((PASS+1)); echo "PASS: T15c2 no 限额 prompt"; fi
if grep -q "限制 \[" "$T/run/edit15c.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15c3 no 限制 prompt"; else PASS=$((PASS+1)); echo "PASS: T15c3 no 限制 prompt"; fi
if grep -q "新路径 \[" "$T/run/edit15c.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15c4 no 路径 prompt"; else PASS=$((PASS+1)); echo "PASS: T15c4 no 路径 prompt"; fi
if grep -q "分流 \[1 开" "$T/run/edit15c.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15c5 no 分流 prompt"; else PASS=$((PASS+1)); echo "PASS: T15c5 no 分流 prompt"; fi
if grep -q "BBR \[1 开" "$T/run/edit15c.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15c6 no BBR prompt"; else PASS=$((PASS+1)); echo "PASS: T15c6 no BBR prompt"; fi
check_eq "T15c7 conf quota kept 0" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "0"
check_eq "T15c8 conf mode kept total" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "total"
check_eq "T15c9 conf rate kept 128000" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "128000"
check_eq "T15c10 path kept /api" "$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' /usr/local/etc/xray/config.json)" "/api"
check "T15c11 split-a kept" test -f /root/split-a.json

echo "--- T15d: preset submenu lists both, GCP and CDT apply ---"
setup_run
printf '\n' | env ACTION=preset bash "$SCRIPT" > "$T/run/preset15d0.out" 2>&1
check_eq "T15d0 preset menu exit 0" "$?" "0"
check_out "T15d1 submenu current preset" "$T/run/preset15d0.out" "当前套餐：自定义"
check_out "T15d2 submenu GCP line" "$T/run/preset15d0.out" "GCP：180G / 总计 / 月 / 1日 / 阻断"
if grep '^  1)' "$T/run/preset15d0.out" | grep -q "限速"; then FAIL=$((FAIL+1)); echo "FAIL: T15d2b submenu GCP no rate"; else PASS=$((PASS+1)); echo "PASS: T15d2b submenu GCP no rate"; fi
check_out "T15d3 submenu GCP whitelist" "$T/run/preset15d0.out" "白名单仅谷歌系"
check_out "T15d4 submenu CDT line" "$T/run/preset15d0.out" "阿里云CDT：180G / 最大值 / 月 / 1日 / 阻断"
if grep '^  2)' "$T/run/preset15d0.out" | grep -q "限速"; then FAIL=$((FAIL+1)); echo "FAIL: T15d4b submenu CDT no rate"; else PASS=$((PASS+1)); echo "PASS: T15d4b submenu CDT no rate"; fi
check_out "T15d5 submenu CDT no whitelist" "$T/run/preset15d0.out" "无白名单"
check_out "T15d6 submenu return 0" "$SCRIPT" "0 返回"
setup_run
printf '1\n' | env ACTION=preset bash "$SCRIPT" > "$T/run/preset15d1.out" 2>&1
check_eq "T15d7 preset GCP exit 0" "$?" "0"
check_eq "T15d8 GCP quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T15d9 GCP mode total" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "total"
check_eq "T15d10 GCP period monthly" "$(grep '^TQ_PERIOD=' "$CONF" | cut -d= -f2)" "monthly"
check_eq "T15d11 GCP start 1" "$(grep '^TQ_START=' "$CONF" | cut -d= -f2)" "1"
check_eq "T15d12 GCP limit block" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "block"
check_eq "T15d12b GCP rate 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
check_out "T15d13 GCP region 美国" /root/install-info.txt "地区：美国"
check "T15d14 GCP SNI in us pool" in_pool "$(info_sni)" "$pool_us"
check_eq "T15d15 GCP routing domain list is only google" "$(jq -r '.routing.rules[0].domain | join(",")' /usr/local/etc/xray/config.json)" "geosite:google"
check_out "T15d16 GCP info whitelist" /root/install-info.txt "白名单：仅谷歌系"
check_out "T15d16b GCP info rate unlimited" /root/install-info.txt "限速：不限速"
setup_run
printf '2\n' | env ACTION=preset bash "$SCRIPT" > "$T/run/preset15d2.out" 2>&1
check_eq "T15d17 preset CDT exit 0" "$?" "0"
check_eq "T15d18 CDT quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T15d19 CDT mode max" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "max"
check_eq "T15d20 CDT period monthly" "$(grep '^TQ_PERIOD=' "$CONF" | cut -d= -f2)" "monthly"
check_eq "T15d21 CDT start 1" "$(grep '^TQ_START=' "$CONF" | cut -d= -f2)" "1"
check_eq "T15d22 CDT limit block" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "block"
check_eq "T15d22b CDT rate 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
check_out "T15d22c CDT info rate unlimited" /root/install-info.txt "限速：不限速"
check_out "T15d23 CDT region 香港" /root/install-info.txt "地区：香港"
check "T15d24 CDT SNI in hk pool" in_pool "$(info_sni)" "$pool_hk"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T15d25 CDT no routing"; else PASS=$((PASS+1)); echo "PASS: T15d25 CDT no routing"; fi
if grep -q "白名单" /root/install-info.txt; then FAIL=$((FAIL+1)); echo "FAIL: T15d26 CDT no whitelist line"; else PASS=$((PASS+1)); echo "PASS: T15d26 CDT no whitelist line"; fi

echo "--- T15e: delete default N keeps node, confirm Y deletes cleanly ---"
setup_run
printf '\n' | env ACTION=delete bash "$SCRIPT" > "$T/run/delete15e0.out" 2>&1
check_eq "T15e1 delete default N exit 0" "$?" "0"
check "T15e2 node kept after N" test -f /usr/local/etc/xray/config.json
check "T15e3 traffic.conf kept after N" test -f "$CONF"
check "T15e4 info kept after N" test -f /root/install-info.txt
setup_run
printf 'Y\n' | env ACTION=delete bash "$SCRIPT" > "$T/run/delete15e1.out" 2>&1
check_eq "T15e5 delete Y exit 0" "$?" "0"
check "T15e6 config.json gone" test ! -f /usr/local/etc/xray/config.json
check "T15e7 traffic.conf gone" test ! -f "$CONF"
check "T15e8 traffic.json gone" test ! -f "$STATE"
check "T15e9 traffic-watch gone" test ! -f "$TQ_WATCH"
check "T15e10 traffic-watch.service gone" test ! -f /etc/systemd/system/traffic-watch.service
check "T15e11 traffic-watch.timer gone" test ! -f /etc/systemd/system/traffic-watch.timer
check "T15e12 info gone" test ! -f /root/install-info.txt
check "T15e13 split-a gone" test ! -f /root/split-a.json
check "T15e14 split-b gone" test ! -f /root/split-b.json
check "T15e15 xray binary kept" test -x "$(command -v xray)"
check_out "T15e16 delete reports deleted" "$T/run/delete15e1.out" "已删除"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add15e.out" 2>&1
check_eq "T15e17 re-add after delete exit 0" "$?" "0"

echo "--- T15f: ACTION aliases ---"
setup_run
env ACTION=show bash "$SCRIPT" < /dev/null > "$T/run/alias15f1.out" 2>&1
check_eq "T15f1 show alias exit 0" "$?" "0"
check_out "T15f2 show alias shows info" "$T/run/alias15f1.out" "地址："
setup_run
env ACTION=modify bash "$SCRIPT" < /dev/null > "$T/run/alias15f2.out" 2>&1
check_eq "T15f3 modify alias exit 0" "$?" "0"
setup_run
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/alias15f3.out" 2>&1
check_eq "T15f4 install alias exit 0" "$?" "0"
setup_run
env ACTION=traffic bash "$SCRIPT" < /dev/null > "$T/run/alias15f4.out" 2>&1
check_eq "T15f5 traffic alias exit 0" "$?" "0"
check_out "T15f6 traffic alias shows traffic" "$T/run/alias15f4.out" "统计："
setup_run
printf '9\n' | env bash "$SCRIPT" > "$T/run/alias15f5.out" 2>&1
check_eq "T15f7 bad menu choice defaults view" "$?" "0"
check_out "T15f8 bad menu choice shows info" "$T/run/alias15f5.out" "地址："

echo "--- T15g: add respects TQ_PRESET env ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 TQ_PRESET=gcp \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add15g.out" 2>&1
check_eq "T15g1 add exit 0" "$?" "0"
check_eq "T15g2 add preset gcp" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_eq "T15g3 add routing geosite" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"

echo "--- T15h: --help lists new actions ---"
setup_run
bash "$SCRIPT" --help > "$T/run/help15h.out" 2>&1
check_out "T15h1 help lists add view edit delete preset" "$T/run/help15h.out" "动作：add view edit delete preset"

echo "--- T15i: no-node menu shows, region only in add, delete lists node first ---"
setup_run; clean_sys
env bash "$SCRIPT" < /dev/null > "$T/run/menu15i0.out" 2>&1
check_eq "T15i1 no-node menu Enter EOF exit 0" "$?" "0"
check_out "T15i2 no-node menu shows 1 添加节点" "$T/run/menu15i0.out" "1) 添加节点"
check_out "T15i3 no-node menu shows 5 载入预设" "$T/run/menu15i0.out" "5) 载入预设"
check_out "T15i3b no-node menu shows 6 退出脚本" "$T/run/menu15i0.out" "6) 退出脚本"
if grep -q "没有节点，请先选 1 添加节点" "$T/run/menu15i0.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15i4 no-node Enter EOF no msg"; else PASS=$((PASS+1)); echo "PASS: T15i4 no-node Enter EOF no msg"; fi
if grep -q "  1) 香港" "$T/run/menu15i0.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15i5 no-node menu no region prompt"; else PASS=$((PASS+1)); echo "PASS: T15i5 no-node menu no region prompt"; fi
setup_run; clean_sys
printf '2\n' | env bash "$SCRIPT" > "$T/run/menu15i2.out" 2>&1
check_eq "T15i6 no-node menu 2 returns to menu, EOF exit 0" "$?" "0"
check_out "T15i7 no-node menu 2 msg" "$T/run/menu15i2.out" "没有节点，请先选 1 添加节点"
check_eq "T15i7b no-node menu 2 shown twice" "$(grep -c '6) 退出脚本' "$T/run/menu15i2.out")" "2"
setup_run; clean_sys
printf '3\n' | env bash "$SCRIPT" > "$T/run/menu15i3.out" 2>&1
check_eq "T15i8 no-node menu 3 returns to menu, EOF exit 0" "$?" "0"
check_out "T15i9 no-node menu 3 msg" "$T/run/menu15i3.out" "没有节点，请先选 1 添加节点"
setup_run; clean_sys
printf '4\n' | env bash "$SCRIPT" > "$T/run/menu15i4.out" 2>&1
check_eq "T15i10 no-node menu 4 returns to menu, EOF exit 0" "$?" "0"
check_out "T15i11 no-node menu 4 msg" "$T/run/menu15i4.out" "没有节点，请先选 1 添加节点"
setup_run; clean_sys
printf '5\n' | env bash "$SCRIPT" > "$T/run/menu15i5.out" 2>&1
check_eq "T15i12 no-node menu 5 exit 0" "$?" "0"
check_out "T15i13 no-node menu 5 shows preset submenu" "$T/run/menu15i5.out" "当前套餐：无"
if grep -q "没有节点，请先选 1 添加节点" "$T/run/menu15i5.out"; then FAIL=$((FAIL+1)); echo "FAIL: T15i13b no-node menu 5 no no-node msg"; else PASS=$((PASS+1)); echo "PASS: T15i13b no-node menu 5 no no-node msg"; fi
check_nofile "T15i13c no-node menu 5 EOF no node created" /usr/local/etc/xray/config.json
setup_run; clean_sys; geodata_on
printf '1\n\n4\n' | env MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" > "$T/run/menu15i1.out" 2>&1
check_eq "T15i14 no-node menu 1 add exit 0" "$?" "0"
check_out "T15i15 no-node menu 1 shows region" "$T/run/menu15i1.out" "  1) 香港"
check_out "T15i16 no-node menu 1 region US" /root/install-info.txt "地区：美国"
setup_run
printf '\n' | env ACTION=delete bash "$SCRIPT" > "$T/run/delete15i.out" 2>&1
check_eq "T15i17 delete N exit 0" "$?" "0"
check_out "T15i18 delete lists 节点 1" "$T/run/delete15i.out" "节点 1："
check_out "T15i19 delete shows address" "$T/run/delete15i.out" "地址：198.51.100.20"
check_out "T15i20 delete shows region" "$T/run/delete15i.out" "地区：美国"
check_out "T15i21 delete shows SNI" "$T/run/delete15i.out" "SNI："
check_out "T15i22 delete shows preset" "$T/run/delete15i.out" "套餐："
check_out "T15i23 delete asks confirm, default N cancels" "$T/run/delete15i.out" "已取消"
if [ "$(grep -n '节点 1：' "$T/run/delete15i.out" | cut -d: -f1 | head -1)" -lt "$(grep -n '已取消' "$T/run/delete15i.out" | cut -d: -f1 | head -1)" ]; then PASS=$((PASS+1)); echo "PASS: T15i24 delete lists node before confirm"; else FAIL=$((FAIL+1)); echo "FAIL: T15i24 delete lists node before confirm"; fi
check "T15i25 node kept after N" test -f /usr/local/etc/xray/config.json

echo "--- T15j: no-node preset creates node (GCP/CDT) ---"
echo "--- T15j1: ACTION=preset TQ_PRESET=gcp, no node -> creates GCP node ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=gcp MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset15j1.out" 2>&1
check_eq "T15j1 preset gcp create exit 0" "$?" "0"
check "T15j2 preset gcp node created" test -f /usr/local/etc/xray/config.json
check_eq "T15j3 preset gcp conf preset" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_eq "T15j4 preset gcp quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T15j5 preset gcp mode total" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "total"
check_eq "T15j6 preset gcp limit block" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "block"
check_eq "T15j7 preset gcp rate 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
check_eq "T15j8 preset gcp routing geosite" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
check_out "T15j9 preset gcp info preset" /root/install-info.txt "套餐：GCP"
check_out "T15j10 preset gcp info whitelist" /root/install-info.txt "白名单：仅谷歌系"
check_out "T15j11 preset gcp info region" /root/install-info.txt "地区：美国"
check "T15j12 preset gcp SNI in us pool" in_pool "$(info_sni)" "$pool_us"
check_out "T15j13 preset gcp info rate unlimited" /root/install-info.txt "限速：不限速"
check_eq "T15j14 preset gcp port 443" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "443"

echo "--- T15j2: ACTION=preset TQ_PRESET=cdt, no node -> creates CDT node ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=cdt MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset15j2.out" 2>&1
check_eq "T15j15 preset cdt create exit 0" "$?" "0"
check "T15j16 preset cdt node created" test -f /usr/local/etc/xray/config.json
check_eq "T15j17 preset cdt conf preset" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "cdt"
check_eq "T15j18 preset cdt quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T15j19 preset cdt mode max" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "max"
check_eq "T15j20 preset cdt limit block" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "block"
check_eq "T15j21 preset cdt rate 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T15j22 preset cdt no routing"; else PASS=$((PASS+1)); echo "PASS: T15j22 preset cdt no routing"; fi
check_out "T15j23 preset cdt info preset" /root/install-info.txt "套餐：阿里云CDT"
check_out "T15j24 preset cdt info region" /root/install-info.txt "地区：香港"
check "T15j25 preset cdt SNI in hk pool" in_pool "$(info_sni)" "$pool_hk"
if grep -q "白名单" /root/install-info.txt; then FAIL=$((FAIL+1)); echo "FAIL: T15j26 preset cdt no whitelist line"; else PASS=$((PASS+1)); echo "PASS: T15j26 preset cdt no whitelist line"; fi
check_out "T15j27 preset cdt info rate unlimited" /root/install-info.txt "限速：不限速"

echo "--- T15j3: interactive menu 5 -> 1 (GCP) -> port Enter creates node ---"
setup_run; clean_sys; geodata_on
printf '5\n1\n\n' | env MODE=reality XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" > "$T/run/preset15j3.out" 2>&1
check_eq "T15j28 interactive menu5 preset1 exit 0" "$?" "0"
check "T15j29 interactive menu5 preset1 node created" test -f /usr/local/etc/xray/config.json
check_out "T15j30 interactive preset submenu no current" "$T/run/preset15j3.out" "当前套餐：无"
check_out "T15j31 interactive preset submenu GCP line" "$T/run/preset15j3.out" "GCP：180G / 总计 / 月 / 1日 / 阻断"
check_eq "T15j32 interactive preset gcp conf preset" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_out "T15j33 interactive preset gcp info region" /root/install-info.txt "地区：美国"
check_eq "T15j34 interactive preset gcp port default 443" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "443"

echo "--- T15j4: interactive menu 5 -> 0 returns, nothing created ---"
setup_run; clean_sys
printf '5\n0\n' | env bash "$SCRIPT" > "$T/run/preset15j4.out" 2>&1
check_eq "T15j35 menu5 preset0 exit 0" "$?" "0"
check_nofile "T15j36 menu5 preset0 no node created" /usr/local/etc/xray/config.json
check_out "T15j37 menu5 preset0 shows submenu" "$T/run/preset15j4.out" "当前套餐：无"

echo "--- T15k: edit preset nodes (GCP/CDT) ---"
echo "--- T15k1: GCP node, edit port-only keeps preset/whitelist/traffic ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=gcp MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset15k1a.out" 2>&1
check_eq "T15k1 preset gcp create exit 0" "$?" "0"
printf '8443\n\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit15k1.out" 2>&1
check_eq "T15k2 edit port-only exit 0" "$?" "0"
check_out "T15k3 edit shows preset GCP" "$T/run/edit15k1.out" "套餐：GCP"
if [ "$(grep -n '套餐：GCP' "$T/run/edit15k1.out" | cut -d: -f1 | head -1)" -lt "$(grep -n '空输入=保持原值' "$T/run/edit15k1.out" | cut -d: -f1 | head -1)" ]; then PASS=$((PASS+1)); echo "PASS: T15k3b edit header shows preset before prompts"; else FAIL=$((FAIL+1)); echo "FAIL: T15k3b edit header shows preset before prompts"; fi
check_eq "T15k4 port-only preset stays gcp" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_eq "T15k5 port-only port 8443" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "8443"
check_eq "T15k6 port-only whitelist kept" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
check_eq "T15k7 port-only quota kept 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T15k8 port-only mode kept total" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "total"
check_eq "T15k9 port-only limit kept block" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "block"
check_eq "T15k10 port-only rate kept 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
check_out "T15k11 port-only info preset GCP" /root/install-info.txt "套餐：GCP"
check_out "T15k12 port-only info whitelist" /root/install-info.txt "白名单：仅谷歌系"

echo "--- T15k2: GCP node, edit region to HK -> preset custom, whitelist removed, traffic kept ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=gcp MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset15k2a.out" 2>&1
check_eq "T15k13 preset gcp create exit 0" "$?" "0"
printf '\n1\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit15k2.out" 2>&1
check_eq "T15k14 edit region exit 0" "$?" "0"
check_out "T15k15 edit shows preset GCP before change" "$T/run/edit15k2.out" "套餐：GCP"
check_eq "T15k16 region change preset custom" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "custom"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T15k17 region change whitelist removed"; else PASS=$((PASS+1)); echo "PASS: T15k17 region change whitelist removed"; fi
check_eq "T15k18 region change quota kept 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T15k19 region change mode kept total" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "total"
check_eq "T15k20 region change limit kept block" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "block"
check_eq "T15k21 region change rate kept 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
check_eq "T15k22 region change port kept 443" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "443"
check_out "T15k23 region change info region HK" /root/install-info.txt "地区：香港"
check "T15k24 region change SNI in hk pool" in_pool "$(info_sni)" "$pool_hk"
check_out "T15k25 region change info preset custom" /root/install-info.txt "套餐：自定义"
if grep -q "白名单" /root/install-info.txt; then FAIL=$((FAIL+1)); echo "FAIL: T15k26 region change info no whitelist"; else PASS=$((PASS+1)); echo "PASS: T15k26 region change info no whitelist"; fi

echo "--- T15k3: CDT node, edit port-only keeps preset ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=cdt MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset15k3a.out" 2>&1
check_eq "T15k27 preset cdt create exit 0" "$?" "0"
printf '8443\n\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit15k3.out" 2>&1
check_eq "T15k28 cdt edit port-only exit 0" "$?" "0"
check_out "T15k29 cdt edit shows preset CDT" "$T/run/edit15k3.out" "套餐：阿里云CDT"
check_eq "T15k30 cdt port-only preset stays cdt" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "cdt"
check_eq "T15k31 cdt port-only port 8443" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "8443"
check_eq "T15k32 cdt port-only mode kept max" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "max"
check_eq "T15k33 cdt port-only quota kept 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_out "T15k34 cdt port-only info preset CDT" /root/install-info.txt "套餐：阿里云CDT"

echo "--- T15k4: CDT node, edit region to US -> preset custom ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=cdt MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset15k4a.out" 2>&1
check_eq "T15k35 preset cdt create exit 0" "$?" "0"
printf '\n4\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit15k4.out" 2>&1
check_eq "T15k36 cdt edit region exit 0" "$?" "0"
check_eq "T15k37 cdt region change preset custom" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "custom"
check_eq "T15k38 cdt region change quota kept 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T15k39 cdt region change mode kept max" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "max"
check_eq "T15k40 cdt region change limit kept block" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "block"
check_eq "T15k41 cdt region change rate kept 0" "$(grep '^TQ_RATE=' "$CONF" | cut -d= -f2)" "0"
check_out "T15k42 cdt region change info region US" /root/install-info.txt "地区：美国"
check "T15k43 cdt region change SNI in us pool" in_pool "$(info_sni)" "$pool_us"
check_out "T15k44 cdt region change info preset custom" /root/install-info.txt "套餐：自定义"

echo "--- T15k5: custom node edit unchanged, shows preset 自定义 ---"
setup_run; clean_sys; geodata_on
env ACTION=add MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add15k5a.out" 2>&1
check_eq "T15k45 custom add exit 0" "$?" "0"
printf '\n\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit15k5.out" 2>&1
check_eq "T15k46 custom edit exit 0" "$?" "0"
check_out "T15k47 custom edit shows preset 自定义" "$T/run/edit15k5.out" "套餐：自定义"
check_eq "T15k48 custom edit preset stays custom" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "custom"
check_eq "T15k49 custom edit quota kept 0" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "0"

echo "--- T15l: menu loop, exit 6, preset 0 returns to menu, vx shortcut ---"
echo "--- T15l1: interactive 2 (no node) -> menu again -> 6 exits ---"
setup_run; clean_sys
printf '2\n6\n' | env bash "$SCRIPT" > "$T/run/menu15l1.out" 2>&1
check_eq "T15l1 menu loop 2 then 6 exit 0" "$?" "0"
check_eq "T15l2 menu shown twice" "$(grep -c '6) 退出脚本' "$T/run/menu15l1.out")" "2"
check_eq "T15l3 no-node msg once" "$(grep -c '没有节点，请先选 1 添加节点' "$T/run/menu15l1.out")" "1"
check_out "T15l4 menu has 6 退出脚本" "$T/run/menu15l1.out" "6) 退出脚本"

echo "--- T15l2: interactive 6 exits at once ---"
setup_run; clean_sys
printf '6\n' | env bash "$SCRIPT" > "$T/run/menu15l2.out" 2>&1
check_eq "T15l5 menu 6 exit 0" "$?" "0"
check_eq "T15l6 menu shown once on 6" "$(grep -c '6) 退出脚本' "$T/run/menu15l2.out")" "1"

echo "--- T15l3: preset submenu 0 returns to main menu ---"
setup_run; clean_sys; geodata_on
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" > "$T/run/install15l.out" 2>&1
printf '5\n0\n6\n' | env bash "$SCRIPT" > "$T/run/menu15l3.out" 2>&1
check_eq "T15l7 preset 0 then 6 exit 0" "$?" "0"
check_eq "T15l8 menu shown twice after preset 0" "$(grep -c '6) 退出脚本' "$T/run/menu15l3.out")" "2"
check_out "T15l9 preset submenu shown" "$T/run/menu15l3.out" "当前套餐："
check "T15l10 node kept after preset 0" test -f /usr/local/etc/xray/config.json

echo "--- T15l4: ACTION= mode unchanged ---"
setup_run; clean_sys
env ACTION=view bash "$SCRIPT" > "$T/run/action15l.out" 2>&1
check_eq "T15l11 ACTION=view no node exit 1" "$?" "1"
setup_run; clean_sys
env ACTION=preset bash "$SCRIPT" < /dev/null > "$T/run/action15l2.out" 2>&1
check_eq "T15l12 ACTION=preset no node EOF exit 1" "$?" "1"
check_nofile "T15l13 ACTION=preset EOF no node created" /usr/local/etc/xray/config.json

echo "--- T15l5: vx shortcut written on every run ---"
setup_run; clean_sys
env ACTION=view bash "$SCRIPT" > "$T/run/vx15l.out" 2>&1
check "T15l14 vx wrapper exists" test -f "$VX_BIN"
check "T15l15 vx wrapper executable" test -x "$VX_BIN"
check_out "T15l16 vx wrapper has raw URL" "$VX_BIN" "raw.githubusercontent.com/bestmiao/vx/main/install.sh"
check_out "T15l17 vx wrapper has backup path" "$VX_BIN" "$VX_BACKUP"
check "T15l18 vx backup exists" test -f "$VX_BACKUP"
check_nofile "T15l19 real /usr/local/bin/vx not created" /usr/local/bin/vx
check_nofile "T15l20 real vx backup not created" /usr/local/bin/vx-install.sh

echo "--- T15l6: vx wrapper download / fallback / no-backup ---"
mkdir -p "$T/fake-curl-ok" "$T/fake-curl-bad"
printf '#!/usr/bin/env bash\necho "LATEST-RAN args:$*"\n' > "$T/fake-latest.sh"
cat > "$T/fake-curl-ok/curl" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$a"; prev=""; continue; fi
  case "$a" in -o) prev="-o" ;; esac
done
cp "$FAKE_LATEST" "$out"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/fake-curl-bad/curl"
chmod +x "$T/fake-curl-ok/curl" "$T/fake-curl-bad/curl" "$T/fake-latest.sh"
FAKE_LATEST="$T/fake-latest.sh" PATH="$T/fake-curl-ok:/usr/bin:/bin" "$VX_BIN" --show-traffic > "$T/run/vx15l-ok.out" 2>&1
check_eq "T15l21 vx curl-ok exit 0" "$?" "0"
check_out "T15l22 vx curl-ok runs latest with args" "$T/run/vx15l-ok.out" "LATEST-RAN args:--show-traffic"
check_out "T15l23 vx curl-ok updates backup" "$VX_BACKUP" "LATEST-RAN"
printf '#!/usr/bin/env bash\necho "BACKUP-RAN args:$*"\n' > "$VX_BACKUP"
PATH="$T/fake-curl-bad:/usr/bin:/bin" "$VX_BIN" hello > "$T/run/vx15l-bad.out" 2>&1
check_eq "T15l24 vx curl-bad backup exit 0" "$?" "0"
check_out "T15l25 vx curl-bad fallback msg" "$T/run/vx15l-bad.out" "拉取最新脚本失败，使用本地备份"
check_out "T15l26 vx curl-bad runs backup" "$T/run/vx15l-bad.out" "BACKUP-RAN args:hello"
rm -f "$VX_BACKUP"
PATH="$T/fake-curl-bad:/usr/bin:/bin" "$VX_BIN" > "$T/run/vx15l-nobak.out" 2>&1
check_eq "T15l27 vx curl-bad no backup exit 1" "$?" "1"
check_out "T15l28 vx curl-bad no backup err" "$T/run/vx15l-nobak.out" "拉取最新脚本失败，且没有本地备份"

echo "=== T16: review fixes (issues 1-8) ==="
echo "--- T16a: refresh_outputs derives pubkey when info file missing ---"
setup_run; clean_sys; geodata_on
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install16a.out" 2>&1
check_eq "T16a1 install exit 0" "$?" "0"
rm -f /root/install-info.txt
printf '\n\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit16a.out" 2>&1
check_eq "T16a2 edit exit 0" "$?" "0"
check "T16a3 info regenerated" test -f /root/install-info.txt
check_out "T16a4 pubkey derived (stub B key)" /root/install-info.txt "公钥：BBBBBBBBBBBB"
check_out "T16a5 link pbk non-empty" /root/install-info.txt "pbk=BBBBBBBBBBBB"

echo "--- T16b: non-interactive preset with no node and no TQ_PRESET fails ---"
setup_run; clean_sys
env ACTION=preset bash "$SCRIPT" < /dev/null > "$T/run/preset16b.out" 2>&1
check_eq "T16b1 preset no-node no-preset exit 1" "$?" "1"
check_out "T16b2 preset error mentions TQ_PRESET" "$T/run/preset16b.out" "TQ_PRESET"
check_nofile "T16b3 no config created" /usr/local/etc/xray/config.json

echo "--- T16c: decimal quota ---"
setup_run; clean_sys; geodata_on
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=1.5G \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install16c.out" 2>&1
check_eq "T16c1 install 1.5G exit 0" "$?" "0"
check_eq "T16c2 conf quota 1.5G bytes" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "1610612736"
check_out "T16c3 info quota 1.50 GB" /root/install-info.txt "限额：1.50 GB"

echo "--- T16d: delete_node removes TLS certs and acme data ---"
setup_run; clean_sys; geodata_on
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install16d.out" 2>&1
check_eq "T16d1 install exit 0" "$?" "0"
_sni16d="$(grep '^SNI：' /root/install-info.txt | awk -F'：' '{print $NF}' | tr -d ' \r\n')"
mkdir -p "$HOME/.acme.sh/${_sni16d}_ecc"
touch /usr/local/etc/xray/privkey.pem /usr/local/etc/xray/fullchain.pem
printf 'Y\n' | env ACTION=delete bash "$SCRIPT" > "$T/run/delete16d.out" 2>&1
check_eq "T16d2 delete exit 0" "$?" "0"
check "T16d3 privkey gone" test ! -f /usr/local/etc/xray/privkey.pem
check "T16d4 fullchain gone" test ! -f /usr/local/etc/xray/fullchain.pem
check "T16d5 acme dir gone" test ! -d "$HOME/.acme.sh/${_sni16d}_ecc"

echo "--- T16e: quota parse error shows original value ---"
setup_run; clean_sys; geodata_on
env ACTION=install MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=abc \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/install16e.out" 2>&1
check_eq "T16e1 invalid quota exit 1" "$?" "1"
check_out "T16e2 error shows original value" "$T/run/install16e.out" "限额无效：abc"

echo "=== T17: ss2022 protocol ==="
SS_PW="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
SS_LINK="ss://MjAyMi1ibGFrZTMtYWVzLTI1Ni1nY206QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQT0@198.51.100.20:8388#ss2022"

echo "--- T17a: ss2022-only add ---"
setup_run; clean_sys; geodata_on
env ACTION=add PROTOCOL=ss2022 SS_PORT=8388 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 TQ_QUOTA=0 \
  bash "$SCRIPT" < /dev/null > "$T/run/add17a.out" 2>&1
check_eq "T17a1 ss add exit 0" "$?" "0"
check "T17a2 config valid json" jq -e . /usr/local/etc/xray/config.json
check_eq "T17a3 inbound protocol shadowsocks" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "shadowsocks"
check_eq "T17a4 inbound port 8388" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "8388"
check_eq "T17a5 method 2022-blake3-aes-256-gcm" "$(jq -r '.inbounds[0].settings.method' /usr/local/etc/xray/config.json)" "2022-blake3-aes-256-gcm"
check_eq "T17a6 password kept" "$(jq -r '.inbounds[0].settings.password' /usr/local/etc/xray/config.json)" "$SS_PW"
check_eq "T17a7 network tcp,udp" "$(jq -r '.inbounds[0].settings.network' /usr/local/etc/xray/config.json)" "tcp,udp"
check_eq "T17a8 single inbound" "$(jq -r '.inbounds | length' /usr/local/etc/xray/config.json)" "1"
check "T17a9 ss info exists" test -f /root/ss2022-info.txt
check_out "T17a10 ss info protocol" /root/ss2022-info.txt "协议：ss2022"
check_out "T17a11 ss info method" /root/ss2022-info.txt "加密方式：2022-blake3-aes-256-gcm"
check_out "T17a12 ss info password" /root/ss2022-info.txt "密码：$SS_PW"
check_out "T17a13 ss info link" /root/ss2022-info.txt "$SS_LINK"
check_nofile "T17a14 no vless info" /root/install-info.txt
check_eq "T17a15 conf TQ_PORT 8388" "$(grep '^TQ_PORT=' "$CONF" | cut -d= -f2)" "8388"
check_eq "T17a16 conf TQ_SS_PORT 8388" "$(grep '^TQ_SS_PORT=' "$CONF" | cut -d= -f2)" "8388"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T17a17 ss no routing"; else PASS=$((PASS+1)); echo "PASS: T17a17 ss no routing"; fi
check_out "T17a18 ss summary shows protocol" "$T/run/add17a.out" "协议：ss2022"

echo "--- T17b: VLESS + ss2022 coexist ---"
setup_run; clean_sys; geodata_on
env ACTION=add PROTOCOL=vless MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add17b0.out" 2>&1
check_eq "T17b0 vless add exit 0" "$?" "0"
setup_run
env ACTION=add PROTOCOL=ss2022 SS_PORT=8388 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 \
  bash "$SCRIPT" < /dev/null > "$T/run/add17b1.out" 2>&1
check_eq "T17b1 ss add exit 0" "$?" "0"
check_eq "T17b2 two inbounds" "$(jq -r '.inbounds | length' /usr/local/etc/xray/config.json)" "2"
check_eq "T17b3 inbound0 vless" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "vless"
check_eq "T17b4 inbound0 port 443" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "443"
check_eq "T17b5 vless uuid kept" "$(jq -r '.inbounds[0].settings.clients[0].id' /usr/local/etc/xray/config.json)" "11111111-2222-3333-4444-555555555555"
check_eq "T17b6 vless reality kept" "$(jq -r '.inbounds[0].streamSettings.security' /usr/local/etc/xray/config.json)" "reality"
check_eq "T17b7 inbound1 shadowsocks" "$(jq -r '.inbounds[1].protocol' /usr/local/etc/xray/config.json)" "shadowsocks"
check_eq "T17b8 inbound1 port 8388" "$(jq -r '.inbounds[1].port' /usr/local/etc/xray/config.json)" "8388"
check "T17b9 vless info exists" test -f /root/install-info.txt
check "T17b10 ss info exists" test -f /root/ss2022-info.txt
check_eq "T17b11 conf TQ_PORT 443" "$(grep '^TQ_PORT=' "$CONF" | cut -d= -f2)" "443"
check_eq "T17b12 conf TQ_SS_PORT 8388" "$(grep '^TQ_SS_PORT=' "$CONF" | cut -d= -f2)" "8388"
setup_run
env ACTION=view bash "$SCRIPT" < /dev/null > "$T/run/view17b.out" 2>&1
check_eq "T17b13 view exit 0" "$?" "0"
check_out "T17b14 view vless link" "$T/run/view17b.out" "vless://"
check_out "T17b15 view ss link" "$T/run/view17b.out" "$SS_LINK"
setup_run
printf '\n' | env ACTION=delete bash "$SCRIPT" > "$T/run/delete17b.out" 2>&1
check_eq "T17b16 delete N exit 0" "$?" "0"
check_out "T17b17 delete lists node 1" "$T/run/delete17b.out" "节点 1："
check_out "T17b18 delete lists node 2" "$T/run/delete17b.out" "节点 2："
check_out "T17b19 delete node2 protocol" "$T/run/delete17b.out" "协议：ss2022"
check_out "T17b20 delete node2 port" "$T/run/delete17b.out" "端口：8388"
check_out "T17b21 delete node1 address" "$T/run/delete17b.out" "地址：198.51.100.20"

echo "--- T17c: ss port conflict with VLESS port fails ---"
setup_run
env ACTION=add PROTOCOL=ss2022 SS_PORT=443 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 \
  bash "$SCRIPT" < /dev/null > "$T/run/add17c.out" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then PASS=$((PASS+1)); echo "PASS: T17c1 conflict port 443 fails"; else FAIL=$((FAIL+1)); echo "FAIL: T17c1 conflict port 443 must fail (rc=$RC)"; fi
check_out "T17c2 conflict error mentions port" "$T/run/add17c.out" "端口 443 已被现有节点占用"
check_eq "T17c3 config still two inbounds" "$(jq -r '.inbounds | length' /usr/local/etc/xray/config.json)" "2"
check_eq "T17c4 ss still 8388" "$(jq -r '.inbounds[1].port' /usr/local/etc/xray/config.json)" "8388"

echo "--- T17d: preset GCP creates ss2022 node, no whitelist ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=gcp PROTOCOL=ss2022 SS_PORT=8388 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset17d.out" 2>&1
check_eq "T17d1 preset gcp ss exit 0" "$?" "0"
check "T17d2 node created" test -f /usr/local/etc/xray/config.json
check_eq "T17d3 inbound shadowsocks" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "shadowsocks"
check_eq "T17d4 conf preset gcp" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_eq "T17d5 conf quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T17d6 conf mode total" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "total"
# GCP 预设的白名单对 ss2022 也生效：路由存在、只放 geosite:google、管住 ss2022 入站
check_eq "T17d7 ss routing geosite google" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
check_eq "T17d7b ss routing inboundTag ss2022" "$(jq -r '.routing.rules[0].inboundTag | join(",")' /usr/local/etc/xray/config.json)" "ss2022"
check_eq "T17d7c ss routing catch-all blocked" "$(jq -r '.routing.rules[1].outboundTag' /usr/local/etc/xray/config.json)" "blocked"
check_eq "T17d7d ss inbound tagged ss2022" "$(jq -r '.inbounds[0].tag' /usr/local/etc/xray/config.json)" "ss2022"
check_eq "T17d7e ss inbound sniffing on" "$(jq -r '.inbounds[0].sniffing.enabled' /usr/local/etc/xray/config.json)" "true"
check_out "T17d8 ss info preset GCP" /root/ss2022-info.txt "套餐：GCP"
check_out "T17d9 ss info quota 180G" /root/ss2022-info.txt "限额：180.00 GB"
check_out "T17d10 ss info whitelist line" /root/ss2022-info.txt "白名单：仅谷歌系"
check_out "T17d11 ss info link" /root/ss2022-info.txt "$SS_LINK"
check_nofile "T17d12 no vless info" /root/install-info.txt

echo "--- T17e: preset CDT creates ss2022 node, no whitelist ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=cdt PROTOCOL=ss2022 SS_PORT=8388 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset17e.out" 2>&1
check_eq "T17e1 preset cdt ss exit 0" "$?" "0"
check_eq "T17e2 inbound shadowsocks" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "shadowsocks"
check_eq "T17e3 conf preset cdt" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "cdt"
check_eq "T17e4 conf quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T17e5 conf mode max" "$(grep '^TQ_MODE=' "$CONF" | cut -d= -f2)" "max"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T17e6 ss no routing"; else PASS=$((PASS+1)); echo "PASS: T17e6 ss no routing"; fi
check_out "T17e7 ss info preset CDT" /root/ss2022-info.txt "套餐：阿里云CDT"
check_out "T17e8 ss info quota 180G" /root/ss2022-info.txt "限额：180.00 GB"

echo "--- T17f: VLESS GCP then add ss2022 keeps preset, whitelist scoped to VLESS ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=gcp PROTOCOL=vless MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset17f0.out" 2>&1
check_eq "T17f0 preset gcp vless exit 0" "$?" "0"
check_eq "T17f1 routing inboundTag vless" "$(jq -r '.routing.rules[0].inboundTag[0]' /usr/local/etc/xray/config.json)" "vless"
check_eq "T17f2 routing catch-all inboundTag vless" "$(jq -r '.routing.rules[1].inboundTag[0]' /usr/local/etc/xray/config.json)" "vless"
check_eq "T17f3 vless inbound tagged" "$(jq -r '.inbounds[0].tag' /usr/local/etc/xray/config.json)" "vless"
check_eq "T17f4 routing still geosite google" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
setup_run
env ACTION=add PROTOCOL=ss2022 SS_PORT=8388 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 \
  bash "$SCRIPT" < /dev/null > "$T/run/add17f1.out" 2>&1
check_eq "T17f5 ss add exit 0" "$?" "0"
check_eq "T17f6 preset still gcp" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_eq "T17f7 quota still 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
# 白名单现在管住两个入站：inboundTag 同时有 vless 和 ss2022（unique 排序后 ss2022 在前）
check_eq "T17f8 routing inboundTag both" "$(jq -r '.routing.rules[0].inboundTag | join(",")' /usr/local/etc/xray/config.json)" "ss2022,vless"
check_eq "T17f8b routing catch-all inboundTag both" "$(jq -r '.routing.rules[1].inboundTag | join(",")' /usr/local/etc/xray/config.json)" "ss2022,vless"
check_eq "T17f9 ss inbound tagged ss2022" "$(jq -r '.inbounds[1].tag' /usr/local/etc/xray/config.json)" "ss2022"
check_eq "T17f9b vless inbound still tagged vless" "$(jq -r '.inbounds[0].tag' /usr/local/etc/xray/config.json)" "vless"
check_eq "T17f9c ss inbound sniffing on" "$(jq -r '.inbounds[1].sniffing.enabled' /usr/local/etc/xray/config.json)" "true"
check_eq "T17f9d routing still geosite google" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
check_out "T17f10 ss info preset GCP" /root/ss2022-info.txt "套餐：GCP"
check_out "T17f11 ss info quota 180G" /root/ss2022-info.txt "限额：180.00 GB"

echo "--- T17g: VLESS add overwrites ss2022 node ---"
setup_run
env ACTION=add PROTOCOL=vless MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add17g.out" 2>&1
check_eq "T17g1 vless add exit 0" "$?" "0"
check_eq "T17g2 single vless inbound" "$(jq -r '.inbounds | length' /usr/local/etc/xray/config.json)" "1"
check_eq "T17g3 inbound vless" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "vless"
check_nofile "T17g4 ss info gone" /root/ss2022-info.txt
check_eq "T17g5 conf TQ_SS_PORT 0" "$(grep '^TQ_SS_PORT=' "$CONF" | cut -d= -f2)" "0"

echo "--- T17h: edit on ss2022-only node refuses safely ---"
setup_run; clean_sys; geodata_on
env ACTION=add PROTOCOL=ss2022 SS_PORT=8388 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 TQ_QUOTA=0 \
  bash "$SCRIPT" < /dev/null > "$T/run/add17h0.out" 2>&1
check_eq "T17h0 ss add exit 0" "$?" "0"
setup_run
printf '\n\n' | env ACTION=edit bash "$SCRIPT" > "$T/run/edit17h.out" 2>&1
check_eq "T17h1 edit exit 0" "$?" "0"
check_out "T17h2 edit refuses ss2022" "$T/run/edit17h.out" "只有 ss2022 节点"
check_eq "T17h3 config still ss 8388" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "8388"
check_eq "T17h4 config still shadowsocks" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "shadowsocks"

echo "--- T17i: preset on ss2022-only node updates traffic only ---"
setup_run
env ACTION=preset TQ_PRESET=gcp bash "$SCRIPT" < /dev/null > "$T/run/preset17i.out" 2>&1
check_eq "T17i1 preset exit 0" "$?" "0"
check_eq "T17i2 conf preset gcp" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "gcp"
check_eq "T17i3 conf quota 180G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "193273528320"
check_eq "T17i4 config still single ss" "$(jq -r '.inbounds | length' /usr/local/etc/xray/config.json)" "1"
check_eq "T17i5 config still shadowsocks" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "shadowsocks"
# 载入 GCP 预设后 ss2022 也要走白名单：路由存在、管住 ss2022、只放 geosite:google
check_eq "T17i6 ss preset routing geosite" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
check_eq "T17i6b ss preset routing inboundTag ss2022" "$(jq -r '.routing.rules[0].inboundTag | join(",")' /usr/local/etc/xray/config.json)" "ss2022"
check_eq "T17i6c ss inbound tagged ss2022" "$(jq -r '.inbounds[0].tag' /usr/local/etc/xray/config.json)" "ss2022"
check_out "T17i7 ss info preset GCP" /root/ss2022-info.txt "套餐：GCP"
check_out "T17i8 ss info quota 180G" /root/ss2022-info.txt "限额：180.00 GB"
check_out "T17i9 ss info whitelist line" /root/ss2022-info.txt "白名单：仅谷歌系"

echo "--- T17j: interactive protocol prompt via menu, default VLESS, pick 2 for ss2022 ---"
setup_run; clean_sys; geodata_on
printf '1\n\n6\n' | env MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_QUOTA=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" > "$T/run/add17j0.out" 2>&1
check_eq "T17j1 menu add Enter protocol exit 0" "$?" "0"
check_out "T17j2 protocol menu shown" "$T/run/add17j0.out" "  2) ss2022"
check_eq "T17j3 Enter defaults vless" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "vless"
setup_run; clean_sys; geodata_on
printf '1\n2\n8388\n6\n' | env PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 TQ_QUOTA=0 SS_PASSWORD="$SS_PW" \
  bash "$SCRIPT" > "$T/run/add17j1.out" 2>&1
check_eq "T17j4 menu add pick 2 exit 0" "$?" "0"
check_eq "T17j5 pick 2 creates ss" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "shadowsocks"
check_eq "T17j6 pick 2 port 8388" "$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)" "8388"
check_out "T17j7 pick 2 link" /root/ss2022-info.txt "$SS_LINK"

echo "--- T17k: tc throttle covers ss2022 port when over quota ---"
setup_run; clean_sys; geodata_on
env ACTION=add PROTOCOL=vless MODE=reality REGION=hk PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 TQ_LIMIT=throttle TQ_RATE=125000 TQ_QUOTA=1 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/add17k0.out" 2>&1
check_eq "T17k0 vless add exit 0" "$?" "0"
setup_run
env ACTION=add PROTOCOL=ss2022 SS_PORT=8388 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 \
  bash "$SCRIPT" < /dev/null > "$T/run/add17k1.out" 2>&1
check_eq "T17k1 ss add exit 0" "$?" "0"
check_eq "T17k1b throttle kept" "$(grep '^TQ_LIMIT=' "$CONF" | cut -d= -f2)" "throttle"
check_eq "T17k1c quota kept 1G" "$(grep '^TQ_QUOTA=' "$CONF" | cut -d= -f2)" "1073741824"
setup_run
rm -f "$STATE"
watch run
nic_set 600000000 600000000
watch run
check_eq "T17k2 throttle enforced" "$(state_get '.enforced')" "throttle"
check_eq "T17k3 tc root present" "$(cat "$T/run/tc.root")" "1"
if grep -q "match ip sport 8388" "$T/run/log"; then PASS=$((PASS+1)); echo "PASS: T17k4 tc filter covers ss port out"; else FAIL=$((FAIL+1)); echo "FAIL: T17k4 tc filter covers ss port out"; fi
if grep -q "match ip dport 8388" "$T/run/log"; then PASS=$((PASS+1)); echo "PASS: T17k5 tc filter covers ss port in"; else FAIL=$((FAIL+1)); echo "FAIL: T17k5 tc filter covers ss port in"; fi

echo "--- T17l: whitelist on ss2022 — transitions + VLESS unchanged ---"
echo "--- T17l1: ss2022-only GCP then preset CDT removes whitelist ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=gcp PROTOCOL=ss2022 SS_PORT=8388 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset17l1a.out" 2>&1
check_eq "T17l1a preset gcp ss exit 0" "$?" "0"
check_eq "T17l1b routing geosite google" "$(jq -r '.routing.rules[0].domain[0]' /usr/local/etc/xray/config.json)" "geosite:google"
setup_run
env ACTION=preset TQ_PRESET=cdt bash "$SCRIPT" < /dev/null > "$T/run/preset17l1b.out" 2>&1
check_eq "T17l1c preset cdt exit 0" "$?" "0"
check_eq "T17l1d conf preset cdt" "$(grep '^TQ_PRESET=' "$CONF" | cut -d= -f2)" "cdt"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T17l1e routing removed after CDT"; else PASS=$((PASS+1)); echo "PASS: T17l1e routing removed after CDT"; fi
check_eq "T17l1f ss node still there" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "shadowsocks"
if grep -q "白名单" /root/ss2022-info.txt; then FAIL=$((FAIL+1)); echo "FAIL: T17l1g ss info no whitelist after CDT"; else PASS=$((PASS+1)); echo "PASS: T17l1g ss info no whitelist after CDT"; fi

echo "--- T17l2: VLESS GCP + ss2022, preset CDT removes whitelist for both ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=gcp PROTOCOL=vless MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset17l2a.out" 2>&1
check_eq "T17l2a preset gcp vless exit 0" "$?" "0"
setup_run
env ACTION=add PROTOCOL=ss2022 SS_PORT=8388 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 \
  bash "$SCRIPT" < /dev/null > "$T/run/add17l2b.out" 2>&1
check_eq "T17l2b ss add exit 0" "$?" "0"
check_eq "T17l2c routing covers both" "$(jq -r '.routing.rules[0].inboundTag | join(",")' /usr/local/etc/xray/config.json)" "ss2022,vless"
setup_run
env ACTION=preset TQ_PRESET=cdt bash "$SCRIPT" < /dev/null > "$T/run/preset17l2c.out" 2>&1
check_eq "T17l2d preset cdt exit 0" "$?" "0"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T17l2e routing removed after CDT"; else PASS=$((PASS+1)); echo "PASS: T17l2e routing removed after CDT"; fi
check_eq "T17l2f two inbounds kept" "$(jq -r '.inbounds | length' /usr/local/etc/xray/config.json)" "2"
check_eq "T17l2g vless kept" "$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)" "vless"
check_eq "T17l2h ss kept" "$(jq -r '.inbounds[1].protocol' /usr/local/etc/xray/config.json)" "shadowsocks"

echo "--- T17l3: VLESS-only GCP whitelist unchanged (single vless, same rules) ---"
setup_run; clean_sys; geodata_on
env ACTION=preset TQ_PRESET=gcp PROTOCOL=vless MODE=reality PORT=443 XHTTP_PATH=/api \
  UUID=11111111-2222-3333-4444-555555555555 ENABLE_BBR=0 SPLIT=0 \
  PUBLIC_IP=198.51.100.20 \
  bash "$SCRIPT" < /dev/null > "$T/run/preset17l3.out" 2>&1
check_eq "T17l3a preset gcp vless exit 0" "$?" "0"
check_eq "T17l3b routing inboundTag only vless" "$(jq -r '.routing.rules[0].inboundTag | join(",")' /usr/local/etc/xray/config.json)" "vless"
check_eq "T17l3c routing catch-all inboundTag only vless" "$(jq -r '.routing.rules[1].inboundTag | join(",")' /usr/local/etc/xray/config.json)" "vless"
check_eq "T17l3d routing domain only google" "$(jq -r '.routing.rules[0].domain | join(",")' /usr/local/etc/xray/config.json)" "geosite:google"
check_eq "T17l3e routing google to direct" "$(jq -r '.routing.rules[0].outboundTag' /usr/local/etc/xray/config.json)" "direct"
check_eq "T17l3f routing rest to blocked" "$(jq -r '.routing.rules[1].outboundTag' /usr/local/etc/xray/config.json)" "blocked"
check_eq "T17l3g vless inbound tagged vless" "$(jq -r '.inbounds[0].tag' /usr/local/etc/xray/config.json)" "vless"
check_eq "T17l3h vless sniffing on" "$(jq -r '.inbounds[0].sniffing.enabled' /usr/local/etc/xray/config.json)" "true"
check_out "T17l3i vless info whitelist" /root/install-info.txt "白名单：仅谷歌系"

echo "--- T17l4: ss2022-only add with CDT preset, no whitelist ---"
setup_run; clean_sys; geodata_on
env ACTION=add PROTOCOL=ss2022 SS_PORT=8388 SS_PASSWORD="$SS_PW" PUBLIC_IP=198.51.100.20 ENABLE_BBR=0 TQ_PRESET=cdt \
  bash "$SCRIPT" < /dev/null > "$T/run/add17l4.out" 2>&1
check_eq "T17l4a ss add cdt exit 0" "$?" "0"
if jq -e .routing /usr/local/etc/xray/config.json >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: T17l4b no routing for CDT"; else PASS=$((PASS+1)); echo "PASS: T17l4b no routing for CDT"; fi
if grep -q "白名单" /root/ss2022-info.txt; then FAIL=$((FAIL+1)); echo "FAIL: T17l4c ss info no whitelist for CDT"; else PASS=$((PASS+1)); echo "PASS: T17l4c ss info no whitelist for CDT"; fi

echo ""
echo "RESULT: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
