#!/usr/bin/env bash
# ========================================
#   GoTraffic 流量消耗工具
#   作者: DaFuHao
#   版本: v1.0.9
#   日期: 2025年10月3日
# ========================================

set -Eeuo pipefail

VERSION="v1.0.9"
AUTHOR="DaFuHao"
DATE="2025年10月3日"

# ------- 默认配置（安装时使用；运行时以 systemd Environment 为准） -------
: "${LIMIT_GB:=10}"                 # 窗口额度 GiB
: "${INTERVAL_MINUTES:=30}"         # 窗口时长(分钟)
: "${THREADS:=2}"                   # 并发 1-32
: "${MODE:=download}"               # download | upload | ud
: "${STATE_FILE:=/root/gotraffic.state}"
: "${LOG_FILE:=/root/gotraffic.log}"
: "${URLS_DL:=/etc/gotraffic/urls.dl.txt}"
: "${URLS_UL:=/etc/gotraffic/urls.ul.txt}"
DEFAULT_DL_URL="https://speed.cloudflare.com/__down?bytes=25000000"
DEFAULT_UL_URL="https://speed.cloudflare.com/__down?bytes=25000000"

banner(){
  echo "========================================"
  echo "   GoTraffic 流量消耗工具"
  echo "   作者: $AUTHOR"
  echo "   版本: $VERSION"
  echo "   日期: $DATE"
  echo "========================================"
}

# ----------------- 写入核心脚本 -----------------
write_core(){
  cat >/usr/local/bin/gotraffic-core.sh <<'EOF_CORE'
#!/usr/bin/env bash
set -Eeuo pipefail

# ---- 从 systemd Environment 读取，给默认值 ----
: "${LIMIT_GB:=10}"
: "${INTERVAL_MINUTES:=30}"
: "${THREADS:=2}"
: "${MODE:=download}"
: "${STATE_FILE:=/root/gotraffic.state}"
: "${LOG_FILE:=/root/gotraffic.log}"
: "${URLS_DL:=/etc/gotraffic/urls.dl.txt}"
: "${URLS_UL:=/etc/gotraffic/urls.ul.txt}"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# 依赖检查
if ! command -v curl >/dev/null 2>&1; then
  echo "[ERROR] curl 未安装，请先安装 curl" | tee -a "$LOG_FILE"
  exit 1
fi

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
bytes_h(){ awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u);i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.2f %s",b,u[i] }'; }

# -------- 窗口状态 (state: 第一行=窗口起始时间戳, 第二行=本窗已用字节) --------
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
add_used(){ local add="$1"; mapfile -t s < <(read_state); local start="${s[0]:-$(date +%s)}" used="${s[1]:-0}"; write_state "$start" "$((used+add))"; }

pick_url(){
  # 随机一条；无 shuf 时取第一条
  if command -v shuf >/dev/null 2>&1; then
    awk 'NF && $1 !~ /^#/' "$1" | shuf -n1
  else
    awk 'NF && $1 !~ /^#/' "$1" | head -n1
  fi
}
curl_dl(){ curl -L --silent --fail --output /dev/null --write-out '%{size_download}\n' "$1"; }
curl_ul(){ head -c 25000000 /dev/zero | curl -L --silent --fail -X POST --data-binary @- --output /dev/null --write-out '%{size_upload}\n' "$1"; }

run_once(){
  ensure_window
  local limit=$((LIMIT_GB*1024*1024*1024)) used=$(get_used) left=$((limit-used))
  [ "$left" -le 0 ] && { log "本窗口额度已完成"; return 0; }

  local tmp; tmp="$(mktemp)"
  log "开始：额度=$(bytes_h "$limit") 已用=$(bytes_h "$used") 线程=$THREADS 模式=$MODE"

  for ((i=1;i<=THREADS;i++)); do
    {
      local got=0 u g1 g2
      case "$MODE" in
        download) u="$(pick_url "$URLS_DL")"; got="$(curl_dl "$u" || echo 0)";;
        upload)   u="$(pick_url "$URLS_UL")"; got="$(curl_ul "$u" || echo 0)";;
        ud)       u="$(pick_url "$URLS_DL")"; g1="$(curl_dl "$u" || echo 0)"; u="$(pick_url "$URLS_UL")"; g2="$(curl_ul "$u" || echo 0)"; got=$((g1+g2));;
      esac
      echo "${got%%.*}" >> "$tmp"
    } &
  done
  wait

  local got_total=0 line
  while read -r line; do [ -n "$line" ] && got_total=$((got_total+line)); done < "$tmp"
  rm -f "$tmp"

  add_used "$got_total"
  used=$(get_used)
  log "完成：新增 $(bytes_h "$got_total") | 累计 $(bytes_h "$used") / $(bytes_h "$limit")"
}

status_cli(){
  # 读取 systemd 的环境，避免显示默认值
  local svc=gotraffic.service
  local env; env=$(systemctl show -p Environment "$svc" 2>/dev/null | sed -e 's/^Environment=//' -e 's/ /\n/g' || true)
  local lg th md
  lg=$(echo "$env" | awk -F= '$1=="LIMIT_GB"{print $2}')
  th=$(echo "$env" | awk -F= '$1=="THREADS"{print $2}')
  md=$(echo "$env" | awk -F= '$1=="MODE"{print $2}')
  [ -z "$lg" ] && lg="$LIMIT_GB"
  [ -z "$th" ] && th="$THREADS"
  [ -z "$md" ] && md="$MODE"
  ensure_window
  local used=$(get_used) limit=$((lg*1024*1024*1024))
  echo "--- 流量状态 ---"
  echo "已用: $(bytes_h "$used") / $(bytes_h "$limit")   (线程=$th 模式=$md)"
  echo "--- 定时器状态 ---"
  systemctl list-timers gotraffic.timer --no-pager --all 2>/dev/null || true
}

edit_service_env(){ sed -i "s|Environment=\"$1=.*|Environment=\"$1=$2\"|" /etc/systemd/system/gotraffic.service; }

case "${1:-}" in
  run)        run_once ;;
  status)     status_cli ;;
  d)          edit_service_env MODE download; systemctl daemon-reload; echo "模式=download";;
  u)          edit_service_env MODE upload;   systemctl daemon-reload; echo "模式=upload";;
  ud)         edit_service_env MODE ud;       systemctl daemon-reload; echo "模式=ud";;
  now)        systemctl start gotraffic.service ;;
  log)        tail -f "$LOG_FILE" ;;
  stop)       systemctl stop gotraffic.timer; echo "定时器已停止";;
  resume)     systemctl start gotraffic.timer; echo "定时器已恢复";;
  config)
              old_l=$(systemctl cat gotraffic.service | awk -F= '/Environment="LIMIT_GB=/{print $3}' | tr -d '"')
              old_t=$(systemctl cat gotraffic.service | awk -F= '/Environment="THREADS=/{print $3}' | tr -d '"')
              old_i=$(systemctl cat gotraffic.timer    | awk -F= '/OnUnitActiveSec=/{print $2}' | sed 's/min//;s/m//')
              read -rp "新额度 GiB (当前=$old_l): " new_l; new_l=${new_l:-$old_l}
              read -rp "新线程 1-32 (当前=$old_t): " new_t; new_t=${new_t:-$old_t}
              read -rp "新间隔 分钟 (当前=$old_i): " new_i; new_i=${new_i:-$old_i}
              edit_service_env LIMIT_GB "$new_l"
              edit_service_env THREADS  "$new_t"
              sed -i "s|OnUnitActiveSec=.*|OnUnitActiveSec=${new_i}min|" /etc/systemd/system/gotraffic.timer
              systemctl daemon-reload
              systemctl restart gotraffic.timer
              echo "配置已更新 ✅ (额度=$new_lGiB 线程=$new_t 间隔=$new_i 分钟)"
              ;;
  update)     tmp=$(mktemp); if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$tmp" https://raw.githubusercontent.com/3257085208/Gotraffic/main/Gotraffic.sh; else wget -qO "$tmp" https://raw.githubusercontent.com/3257085208/Gotraffic/main/Gotraffic.sh; fi; if [ -s "$tmp" ]; then mv "$tmp" /usr/local/bin/Gotraffic.sh; chmod +x /usr/local/bin/Gotraffic.sh; echo "✅ 已下载到 /usr/local/bin/Gotraffic.sh"; else echo "❌ 更新失败"; rm -f "$tmp"; fi ;;
  uninstall)  systemctl disable --now gotraffic.timer 2>/dev/null || true; systemctl disable --now gotraffic.service 2>/dev/null || true; rm -f /etc/systemd/system/gotraffic.{service,timer}; rm -f /usr/local/bin/gotraffic-core.sh /usr/local/bin/gotr; rm -f "$LOG_FILE" "$STATE_FILE"; systemctl daemon-reload; echo "已卸载 ✅";;
  version)    echo "GoTraffic core $(date '+%F %T')";;
  *)          echo "用法: gotr {d|u|ud|now|status|log|stop|resume|config|update|uninstall|version}";;
esac
EOF_CORE
  chmod +x /usr/local/bin/gotraffic-core.sh
}

# ----------------- 写入 gotr 分发器 -----------------
write_gotr(){
  cat >/usr/local/bin/gotr <<'EOF_GOTR'
#!/usr/bin/env bash
# 只做分发，不做安装
exec /usr/local/bin/gotraffic-core.sh "$@"
EOF_GOTR
  chmod +x /usr/local/bin/gotr
}

# ----------------- 写入 systemd -----------------
write_systemd(){
  # 默认 URL 文件
  mkdir -p /etc/gotraffic
  [ -s "$URLS_DL" ] || echo "https://speed.cloudflare.com/__down?bytes=25000000" > "$URLS_DL"
  [ -s "$URLS_UL" ] || echo "https://speed.cloudflare.com/__down?bytes=25000000" > "$URLS_UL"

  cat >/etc/systemd/system/gotraffic.service <<EOF
[Unit]
Description=GoTraffic core

[Service]
Type=oneshot
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"
Environment="LIMIT_GB=$LIMIT_GB"
Environment="INTERVAL_MINUTES=$INTERVAL_MINUTES"
Environment="THREADS=$THREADS"
Environment="MODE=$MODE"
Environment="STATE_FILE=$STATE_FILE"
Environment="LOG_FILE=$LOG_FILE"
Environment="URLS_DL=$URLS_DL"
Environment="URLS_UL=$URLS_UL"
ExecStart=/usr/local/bin/gotraffic-core.sh run
EOF

  cat >/etc/systemd/system/gotraffic.timer <<EOF
[Unit]
Description=Run GoTraffic every $INTERVAL_MINUTES minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=${INTERVAL_MINUTES}min
Unit=gotraffic.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now gotraffic.timer
}

# ----------------- 安装主流程 -----------------
main_install(){
  banner
  read -rp "每窗口要消耗多少流量 (GiB) [10]: " LIMIT_GB; LIMIT_GB=${LIMIT_GB:-10}
  read -rp "窗口间隔时长 (分钟) [30]: " INTERVAL_MINUTES; INTERVAL_MINUTES=${INTERVAL_MINUTES:-30}
  read -rp "并发线程数 (1-32) [2]: " THREADS; THREADS=${THREADS:-2}
  # 线程范围保护
  if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || (( THREADS<1 || THREADS>32 )); then THREADS=2; fi

  write_core
  write_gotr
  write_systemd

  echo "[$(date '+%F %T')] 安装完成 ✅" | tee -a "$LOG_FILE"
  echo "日志文件: $LOG_FILE"
  echo "快捷命令: gotr d|u|ud|now|status|log|stop|resume|config|update|uninstall"
}

# ----------------- 入口 -----------------
main_install
