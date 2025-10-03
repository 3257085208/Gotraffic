#!/usr/bin/env bash
# Gotraffic.sh — 单文件一键安装 + 核心逻辑 + systemd + 快捷命令
set -Eeuo pipefail

# =============== 交互设置 ===============
echo "=== GoTraffic 安装（分钟级窗口）==="
read -rp "每个窗口要消耗多少流量（GiB）[10]: " LIMIT_INTERVAL_GB; LIMIT_INTERVAL_GB=${LIMIT_INTERVAL_GB:-10}
read -rp "窗口间隔时长（分钟）[30]: " INTERVAL_MINUTES; INTERVAL_MINUTES=${INTERVAL_MINUTES:-30}

# 默认参数
THREADS=2
MODE=download
STATE_FILE=/var/lib/gotraffic/state.txt
LOG_FILE=/var/log/gotraffic.log
URLS_DL=/etc/gotraffic/urls.dl.txt
URLS_UL=/etc/gotraffic/urls.ul.txt
CORE=/usr/local/bin/gotraffic-core.sh

# =============== 安装核心程序 ===============
install -d /etc/gotraffic /var/lib/gotraffic
touch "$STATE_FILE" "$LOG_FILE"

cat >"$CORE" <<'EOF_CORE'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${LIMIT_INTERVAL_GB:=10}"
: "${INTERVAL_MINUTES:=30}"
: "${THREADS:=2}"
: "${MODE:=download}"
: "${URLS_DL:=/etc/gotraffic/urls.dl.txt}"
: "${URLS_UL:=/etc/gotraffic/urls.ul.txt}"
: "${STATE_FILE:=/var/lib/gotraffic/state.txt}"
: "${LOG_FILE:=/var/log/gotraffic.log}"
: "${CHUNK_MIN_MB:=128}"
: "${CHUNK_MAX_MB:=512}"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")"
touch "$STATE_FILE" "$LOG_FILE"

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

# 🚀 强制 GiB 显示
bytes_gib(){ awk -v b="$1" 'BEGIN{printf "%.2f GiB", b/1024/1024/1024}'; }

read_state(){ [ -s "$STATE_FILE" ] && cat "$STATE_FILE" || echo -e "0\n0"; }
write_state(){ echo -e "$1\n$2" > "$STATE_FILE"; }

ensure_window(){
  local now=$(date +%s)
  mapfile -t s < <(read_state)
  local start="${s[0]:-0}" used="${s[1]:-0}"
  if (( now - start >= INTERVAL_MINUTES*60 )); then
    write_state "$now" 0
  fi
}

get_used(){ sed -n 2p "$STATE_FILE" 2>/dev/null || echo 0; }
add_used(){ local add=$1; mapfile -t s < <(read_state); local start="${s[0]:-$(date +%s)}"; local used=$((s[1]+add)); write_state "$start" "$used"; }

pick_url(){ grep -v '^#' "$1" | shuf -n1; }
rand_chunk(){ awk -v min="$CHUNK_MIN_MB" -v max="$CHUNK_MAX_MB" 'BEGIN{srand();print int((min+rand()*(max-min+1))*1024*1024)}'; }

# 🔥 修复: URL 替换 {bytes}
prepare_url(){ local url="$1" size="$2"; echo "${url//\{bytes\}/$size}"; }

curl_dl(){ curl -L --silent --output /dev/null --write-out '%{size_download}\n' "$1"; }
curl_ul(){ head -c "$2" /dev/zero | curl -X POST --data-binary @- -s -o /dev/null --write-out '%{size_upload}\n' "$1"; }

main(){
  ensure_window
  local limit=$((LIMIT_INTERVAL_GB*1024*1024*1024))
  local used=$(get_used)
  local left=$((limit-used))
  (( left <= 0 )) && { log "窗口已满"; exit 0; }

  local chunk=$(rand_chunk)
  (( chunk > left )) && chunk=$left

  if [ "$MODE" = "download" ]; then
    url=$(pick_url "$URLS_DL"); url=$(prepare_url "$url" "$chunk"); got=$(curl_dl "$url")
  elif [ "$MODE" = "upload" ]; then
    url=$(pick_url "$URLS_UL"); got=$(curl_ul "$url" "$chunk")
  else
    url=$(pick_url "$URLS_DL"); url=$(prepare_url "$url" "$chunk"); got1=$(curl_dl "$url")
    url=$(pick_url "$URLS_UL"); got2=$(curl_ul "$url" "$chunk")
    got=$((got1+got2))
  fi

  got=${got%%.*}
  add_used "$got"
  log "消耗 $(bytes_gib "$got") | 窗口累计 $(bytes_gib $((used+got)))/$(bytes_gib $limit)"
}
main "$@"
EOF_CORE

chmod +x "$CORE"

# 默认URL文件
[ -e "$URLS_DL" ] || echo "https://speed.cloudflare.com/__down?bytes={bytes}" > "$URLS_DL"
[ -e "$URLS_UL" ] || echo "# 在这里填上行接收端URL" > "$URLS_UL"

# =============== systemd 配置 ===============
cat >/etc/systemd/system/gotraffic.service <<EOF
[Unit]
Description=GoTraffic core
[Service]
Type=oneshot
Environment=LIMIT_INTERVAL_GB=$LIMIT_INTERVAL_GB
Environment=INTERVAL_MINUTES=$INTERVAL_MINUTES
Environment=THREADS=$THREADS
Environment=MODE=$MODE
ExecStart=$CORE
EOF

cat >/etc/systemd/system/gotraffic.timer <<EOF
[Unit]
Description=Run GoTraffic
[Timer]
OnBootSec=1m
OnUnitActiveSec=2m
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now gotraffic.timer

# =============== 快捷命令 gotr ===============
cat >/usr/local/bin/gotr <<'EOF_GOTR'
#!/usr/bin/env bash
set -e
svc=gotraffic.service
core=/usr/local/bin/gotraffic-core.sh
case "$1" in
  d) systemctl set-environment MODE=download; echo "切换到下行";;
  u) systemctl set-environment MODE=upload; echo "切换到上行";;
  ud) systemctl set-environment MODE=ud; echo "切换到上下行";;
  now) systemctl start $svc;;
  status) $core;;
  uninstall)
    systemctl disable --now gotraffic.timer || true
    systemctl disable --now $svc || true
    rm -f /etc/systemd/system/gotraffic.{service,timer}
    rm -f /usr/local/bin/gotraffic-core.sh /usr/local/bin/gotr
    rm -rf /etc/gotraffic /var/lib/gotraffic /var/log/gotraffic.log
    systemctl daemon-reload
    echo "GoTraffic 已卸载"
    ;;
  *) echo "用法: gotr d|u|ud|now|status|uninstall";;
esac
EOF_GOTR

chmod +x /usr/local/bin/gotr

echo "安装完成 ✅"
echo "快捷命令: gotr d|u|ud|now|status|uninstall"
