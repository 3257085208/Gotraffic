#!/usr/bin/env bash
# ========================================
#   GoTraffic 流量消耗工具
#   作者: DaFuHao
#   版本: v1.0.7
#   日期: 2025年10月3日
# ========================================

set -Eeuo pipefail

VERSION="v1.0.7"
AUTHOR="DaFuHao"
DATE="2025年10月3日"

# ---------------- 默认配置 ----------------
: "${LIMIT_GB:=10}"
: "${INTERVAL_MINUTES:=30}"
: "${THREADS:=2}"
: "${MODE:=download}"
: "${STATE_FILE:=/root/gotraffic.state}"
: "${LOG_FILE:=/root/gotraffic.log}"

: "${URLS_DL:=/etc/gotraffic/urls.dl.txt}"
: "${URLS_UL:=/etc/gotraffic/urls.ul.txt}"
DEFAULT_DL_URL="https://speed.cloudflare.com/__down?bytes=25000000"
DEFAULT_UL_URL="https://speed.cloudflare.com/__down?bytes=25000000"

mkdir -p /etc/gotraffic
[ -f "$URLS_DL" ] || echo "$DEFAULT_DL_URL" > "$URLS_DL"
[ -f "$URLS_UL" ] || echo "$DEFAULT_UL_URL" > "$URLS_UL"

# ---------------- 工具函数 ----------------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
bytes_h(){ awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u);i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.2f %s",b,u[i] }'; }

# ---------------- 状态管理 ----------------
read_state(){
  if [ -f "$STATE_FILE" ]; then
    awk 'NR==1{print $1+0} NR==2{print $1+0}' "$STATE_FILE"
  fi
}

write_state(){ printf '%s\n%s\n' "$1" "$2" > "$STATE_FILE"; }

ensure_window(){
  local now_ts=$(date +%s) start=0 used=0 secs=$((INTERVAL_MINUTES*60))
  mapfile -t s < <(read_state)
  [ "${#s[@]}" -ge 1 ] && start="${s[0]}"
  [ "${#s[@]}" -ge 2 ] && used="${s[1]}"
  if [ -z "$start" ] || [ "$start" -le 0 ] || [ $((now_ts-start)) -ge "$secs" ]; then
    start="$now_ts"; used=0
  fi
  write_state "$start" "$used"
}

get_used(){ awk 'NR==2{print $1+0}' "$STATE_FILE" 2>/dev/null || echo 0; }
add_used(){ local add="$1"; mapfile -t s < <(read_state); local start="${s[0]:-$(date +%s)}" used="${s[1]:-0}"; used=$((used+add)); write_state "$start" "$used"; }

# ---------------- 流量任务 ----------------
pick_url(){ awk 'NF && $1 !~ /^#/' "$1" | head -n1; }
curl_dl(){ local url="$1"; curl -L --silent --fail --output /dev/null --write-out '%{size_download}\n' "$url"; }
curl_ul(){ local url="$1" size=25000000; head -c "$size" /dev/zero | curl -L --silent --fail -X POST --data-binary @- --output /dev/null --write-out '%{size_upload}\n' "$url"; }

run_traffic(){
  ensure_window
  local limit=$((LIMIT_GB*1024*1024*1024)) used="$(get_used)" left=$((limit-used))
  [ "$left" -le 0 ] && { log "本轮已完成额度"; return; }

  log "开始任务：额度=$(bytes_h "$limit") 已用=$(bytes_h "$used") 线程=$THREADS 模式=$MODE"

  for ((i=1; i<=THREADS; i++)); do
    case "$MODE" in
      download) curl_dl "$(pick_url "$URLS_DL")" & ;;
      upload)   curl_ul "$(pick_url "$URLS_UL")" & ;;
      ud)       curl_dl "$(pick_url "$URLS_DL")" & curl_ul "$(pick_url "$URLS_UL")" & ;;
    esac
  done
  wait

  local got=$((THREADS*25000000))
  add_used "$got"
  log "执行完成：新增 $(bytes_h "$got") | 累计 $(bytes_h "$(get_used)")/$(bytes_h "$limit")"
}

status(){
  ensure_window
  local used="$(get_used)" limit=$((LIMIT_GB*1024*1024*1024))
  echo "--- 流量状态 ---"
  echo "已用: $(bytes_h "$used") / $(bytes_h "$limit")"
  echo "--- 定时器状态 ---"
  systemctl list-timers gotraffic.timer --no-pager --all || true
}

# ---------------- systemd ----------------
install_systemd(){
cat >/etc/systemd/system/gotraffic.service <<EOF
[Unit]
Description=GoTraffic core

[Service]
Type=oneshot
Environment="LIMIT_GB=$LIMIT_GB"
Environment="THREADS=$THREADS"
Environment="MODE=$MODE"
Environment="URLS_DL=$URLS_DL"
Environment="URLS_UL=$URLS_UL"
Environment="STATE_FILE=$STATE_FILE"
Environment="LOG_FILE=$LOG_FILE"
ExecStart=/usr/local/bin/gotraffic-core.sh core
EOF

cat >/etc/systemd/system/gotraffic.timer <<EOF
[Unit]
Description=Run GoTraffic every $INTERVAL_MINUTES minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL_MINUTES}min
Unit=gotraffic.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now gotraffic.timer
}

# ---------------- 快捷命令分发器 ----------------
gotr(){
case "$1" in
  d) sudo systemctl set-environment MODE=download && log "切换到下载模式" ;;
  u) sudo systemctl set-environment MODE=upload && log "切换到上传模式" ;;
  ud) sudo systemctl set-environment MODE=ud && log "切换到上下行模式" ;;
  now) sudo systemctl start gotraffic.service ;;
  status) status ;;
  log) tail -f "$LOG_FILE" ;;
  stop) systemctl stop gotraffic.timer && log "定时器已停止" ;;
  resume) systemctl start gotraffic.timer && log "定时器已恢复" ;;
  config) echo "修改配置请重新执行 Gotraffic.sh";;
  update)
    tmp=$(mktemp)
    wget -qO "$tmp" https://raw.githubusercontent.com/3257085208/Gotraffic/main/Gotraffic.sh
    if [ -s "$tmp" ]; then
      mv "$tmp" /usr/local/bin/Gotraffic.sh
      chmod +x /usr/local/bin/Gotraffic.sh
      echo "✅ 已更新到最新版，请运行: bash /usr/local/bin/Gotraffic.sh"
    else
      echo "❌ 更新失败"
      rm -f "$tmp"
    fi
    ;;
  uninstall) systemctl disable --now gotraffic.timer; rm -f /etc/systemd/system/gotraffic.{service,timer}; rm -f /usr/local/bin/gotraffic-core.sh /usr/local/bin/gotr; log "GoTraffic 已卸载" ;;
  *) echo "=== GoTraffic 快捷命令用法 (版本: $VERSION) ===
  gotr d        切换到下载模式
  gotr u        切换到上传模式
  gotr ud       切换到上下行模式
  gotr now      立即执行一次
  gotr status   查看状态
  gotr log      实时日志
  gotr stop     停止定时器
  gotr resume   恢复定时器
  gotr config   修改额度/间隔/线程
  gotr update   更新脚本
  gotr uninstall 卸载 GoTraffic";;
esac
}

# ---------------- 主安装入口 ----------------
if [[ "${1:-}" == "core" ]]; then
  run_traffic
else
  echo "========================================"
  echo "   GoTraffic 流量消耗工具"
  echo "   作者: $AUTHOR"
  echo "   版本: $VERSION"
  echo "   日期: $DATE"
  echo "========================================"
  read -rp "每窗口要消耗多少流量 (GiB) [10]: " LIMIT_GB
  LIMIT_GB=${LIMIT_GB:-10}
  read -rp "窗口间隔时长 (分钟) [30]: " INTERVAL_MINUTES
  INTERVAL_MINUTES=${INTERVAL_MINUTES:-30}
  read -rp "并发线程数 (1-32) [2]: " THREADS
  THREADS=${THREADS:-2}

  cp "$0" /usr/local/bin/gotraffic-core.sh
  chmod +x /usr/local/bin/gotraffic-core.sh
  cat >/usr/local/bin/gotr <<'EOF'
#!/usr/bin/env bash
/usr/local/bin/gotraffic-core.sh "$@"
EOF
  chmod +x /usr/local/bin/gotr

  install_systemd
  log "安装完成 ✅"
  echo "日志文件: $LOG_FILE"
  echo "快捷命令: gotr d|u|ud|now|status|log|stop|resume|config|update|uninstall"
fi
