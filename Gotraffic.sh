#!/usr/bin/env bash
# ========================================
#   GoTraffic 流量消耗工具
#   作者: DaFuHao
#   版本: v1.3.4
#   日期: 2025-10-03
# ========================================

set -Eeuo pipefail
VERSION="v1.3.4"; AUTHOR="DaFuHao"; DATE="2025-10-03"

# 安装阶段默认值（运行期以 systemd Environment 为准；可 gotr config 修改）
: "${LIMIT_GB:=10}"                   # 每窗口额度 GiB
: "${INTERVAL_MINUTES:=30}"           # 窗口时长(分钟)
: "${THREADS:=4}"                     # 并发 1-32
: "${MODE:=download}"                 # download | upload | ud
: "${STATE_FILE:=/root/gotraffic.state}"
: "${LOG_FILE:=/root/gotraffic.log}"
: "${URLS_DL:=/etc/gotraffic/urls.dl.txt}"
: "${URLS_UL:=/etc/gotraffic/urls.ul.txt}"

# 强化参数（gotr config 可改）
: "${CHUNK_BYTES_DL:=250000000}"      # 单次下载字节（默认 250,000,000 B ≈ 238 MiB）
: "${CHUNK_BYTES_UL:=25000000}"       # 单次上传字节
: "${BATCH_SLEEP_MS:=120}"            # 批次间隔毫秒
: "${ZERO_BACKOFF_MS:=1200}"          # 全 0 批次初始退避
: "${ZERO_BACKOFF_MAX_MS:=10000}"     # 全 0 批次最大退避
: "${ZERO_STREAK_SWITCH:=6}"          # 连续几次 0B 后切换偏好非 CF 域
: "${DEBUG:=0}"

# 默认多源清单（首次安装若文件不存在才写入）
DEFAULT_DL_URLS=$'# 你也可以继续追加更多源（每行一个）\nhttps://speed.cloudflare.com/__down?bytes=104857600\nhttps://speed.cloudflare.com/__down?bytes=524288000\nhttps://speed.cloudflare.com/__down?bytes=25000000\nhttps://speed.cloudflare.com/__down?bytes=1073741824\nhttps://p1.dailygn.com/obj/g-marketing-act-assets/2024_11_28_14_54_37/mv_1128_1080px.mp4\n'
DEFAULT_UL_URL="https://speed.cloudflare.com/__down?bytes={bytes}"

banner(){ cat <<EOF
========================================
   GoTraffic 流量消耗工具
   作者: $AUTHOR
   版本: $VERSION
   日期: $DATE
========================================
EOF
}

# ----------------- 核心脚本 -----------------
write_core(){
  cat >/usr/local/bin/gotraffic-core.sh <<'EOF_CORE'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${LIMIT_GB:=10}"
: "${INTERVAL_MINUTES:=30}"
: "${THREADS:=4}"
: "${MODE:=download}"
: "${STATE_FILE:=/root/gotraffic.state}"
: "${LOG_FILE:=/root/gotraffic.log}"
: "${URLS_DL:=/etc/gotraffic/urls.dl.txt}"
: "${URLS_UL:=/etc/gotraffic/urls.ul.txt}"
: "${CHUNK_BYTES_DL:=250000000}"
: "${CHUNK_BYTES_UL:=25000000}"
: "${BATCH_SLEEP_MS:=120}"
: "${ZERO_BACKOFF_MS:=1200}"
: "${ZERO_BACKOFF_MAX_MS:=10000}"
: "${ZERO_STREAK_SWITCH:=6}"
: "${DEBUG:=0}"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
command -v curl >/dev/null 2>&1 || { echo "[$(date '+%F %T')] [ERROR] curl 未安装" | tee -a "$LOG_FILE"; exit 1; }
[ "$DEBUG" = "1" ] && set -x

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
bytes_h(){ awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u);i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.2f %s",b,u[i] }'; }

# --- 状态文件: 第1行=窗口起始秒，第2行=已用字节 ---
read_state(){ [ -f "$STATE_FILE" ] && awk 'NR==1{print $1+0} NR==2{print $1+0}' "$STATE_FILE"; }
write_state(){ printf '%s\n%s\n' "$1" "$2" > "$STATE_FILE"; }
get_used(){ awk 'NR==2{print $1+0}' "$STATE_FILE" 2>/dev/null || echo 0; }

window_secs_left(){
  local secs start now; secs=$((INTERVAL_MINUTES*60))
  start=$(awk 'NR==1{print $1+0}' "$STATE_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  local left=$((secs-(now-start))); [ "$left" -lt 0 ] && left=0; echo "$left"
}
ensure_window(){
  local now_ts secs start used
  now_ts=$(date +%s); secs=$((INTERVAL_MINUTES*60))
  start=0; used=0
  mapfile -t s < <(read_state || true)
  [ "${#s[@]}" -ge 1 ] && start="${s[0]}"; [ "${#s[@]}" -ge 2 ] && used="${s[1]}"
  if [ -z "${start:-}" ] || [ "$start" -le 0 ] || [ $((now_ts-start)) -ge "$secs" ]; then
    start="$now_ts"; used=0
  fi
  write_state "$start" "$used"
}
add_used(){ local add="$1"; mapfile -t s < <(read_state || true); local start="${s[0]:-$(date +%s)}" used="${s[1]:-0}"; write_state "$start" "$((used+add))"; }

# ---------- URL 选取与下载策略 ----------
_is_cf_domain(){ echo "$1" | grep -qiE '(^|://)([^/]*\.)?cloudflare\.com(/|$)'; }

# 从清单中选源：优先选择非 CF（当连续 0B 达阈值时）
pick_url_smart(){
  local list="$1" prefer_non_cf="$2"
  if [ "$prefer_non_cf" = "1" ]; then
    # 有非 CF 行就从非 CF 里取，否则退化到全表
    awk 'NF && $1 !~ /^#/ && $0 !~ /cloudflare\.com/i' "$list" | { command -v shuf >/dev/null 2>&1 && shuf -n1 || head -n1; } \
      || awk 'NF && $1 !~ /^#/' "$list" | { command -v shuf >/dev/null 2>&1 && shuf -n1 || head -n1; }
  else
    awk 'NF && $1 !~ /^#/' "$list" | { command -v shuf >/dev/null 2>&1 && shuf -n1 || head -n1; }
  fi
}

bust(){ # 追加随机参数避免缓存/限频
  local u="$1" r; r=$RANDOM$RANDOM$RANDOM
  if [[ "$u" == *\{bytes\}* && -n "${2:-}" ]]; then
    u="${u//\{bytes\}/$2}"
  fi
  if [[ "$u" == *\?* ]]; then
    echo "${u}&r=${r}"
  else
    echo "${u}?r=${r}"
  fi
}

dl_with_bytes(){
  local u="$1"
  curl --http1.1 -L --silent --show-error --fail --output /dev/null --write-out '%{size_download}\n' "$u"
}
dl_with_range(){
  local u="$1" bytes="$2"
  local end=$((bytes-1))
  curl --http1.1 -L --silent --show-error --fail --range "0-${end}" --output /dev/null --write-out '%{size_download}\n' "$u"
}

curl_dl_choose(){
  local raw="$1" bytes="$2"
  if [[ "$raw" == *\{bytes\}* || "$raw" == *"bytes="* ]]; then
    dl_with_bytes "$(bust "$raw" "$bytes")"
  else
    dl_with_range "$(bust "$raw" "$bytes")" "$bytes"
  fi
}

curl_ul(){ head -c "$2" /dev/zero | curl --http1.1 -L --silent --show-error --fail -X POST --data-binary @- --output /dev/null --write-out '%{size_upload}\n' "$1"; }

sleep_ms(){ awk -v ms="$1" 'BEGIN{printf "%.3f", ms/1000}' | { read s; sleep "$s"; } 2>/dev/null || true; }

run_batch_once(){
  local prefer_non_cf="$1" tmp; tmp="$(mktemp)"
  local i
  for ((i=1;i<=THREADS;i++)); do
    {
      local got=0 u g1 g2
      case "$MODE" in
        download)
          u="$(pick_url_smart "$URLS_DL" "$prefer_non_cf")"
          got="$(curl_dl_choose "$u" "$CHUNK_BYTES_DL" || echo 0)"
        ;;
        upload)
          u="$(pick_url_smart "$URLS_UL" 0)"; u="$(bust "$u" "$CHUNK_BYTES_UL")"
          got="$(curl_ul "$u" "$CHUNK_BYTES_UL" || echo 0)"
        ;;
        ud)
          u="$(pick_url_smart "$URLS_DL" "$prefer_non_cf")"
          g1="$(curl_dl_choose "$u" "$CHUNK_BYTES_DL" || echo 0)"
          u="$(pick_url_smart "$URLS_UL" 0)"; u="$(bust "$u" "$CHUNK_BYTES_UL")"
          g2="$(curl_ul "$u" "$CHUNK_BYTES_UL" || echo 0)"
          got=$((g1+g2))
        ;;
      esac
      echo "${got%%.*}" >> "$tmp"
    } &
  done
  wait || true
  local sum=0 line; while read -r line; do [ -n "$line" ] && sum=$((sum+line)); done < "$tmp"
  rm -f "$tmp"
  echo "$sum"
}

run_until_cap(){
  ensure_window
  local limit used left zero_sleep zero_streak prefer_non_cf
  zero_sleep="$ZERO_BACKOFF_MS"; zero_streak=0; prefer_non_cf=0
  limit=$((LIMIT_GB*1024*1024*1024))
  used=$(get_used); left=$((limit-used))
  if [ "$left" -le 0 ]; then log "本窗口额度已完成"; return 0; fi
  log "开始循环：窗口额度=$(bytes_h "$limit") 已用=$(bytes_h "$used") 线程=$THREADS 模式=$MODE 窗口剩余$(window_secs_left)s"

  while :; do
    local win_left used_now left_now got
    win_left=$(window_secs_left)
    used_now=$(get_used)
    left_now=$((limit-used_now))
    if [ "$left_now" -le 0 ]; then log "达到窗口上限，停止。"; break; fi
    if [ "$win_left" -le 0 ]; then log "窗口已结束，停止。"; break; fi

    got="$(run_batch_once "$prefer_non_cf")"; got="${got%%.*}"
    if [ "$got" -le 0 ]; then
      zero_streak=$((zero_streak+1))
      log "本批新增 0 B（可能被限速/限频） streak=${zero_streak}，退避 ${zero_sleep}ms 后再试"
      if [ "$zero_streak" -ge "$ZERO_STREAK_SWITCH" ]; then
        prefer_non_cf=1  # 开始优先非 CF 源
        log "切换为优先使用非 Cloudflare 源"
      fi
      sleep_ms "$zero_sleep"
      zero_sleep=$(( zero_sleep*2 )); [ "$zero_sleep" -gt "$ZERO_BACKOFF_MAX_MS" ] && zero_sleep="$ZERO_BACKOFF_MAX_MS"
      continue
    fi
    # 有进展就复位退避与 streak
    zero_sleep="$ZERO_BACKOFF_MS"; zero_streak=0

    add_used "$got"
    used_now=$(get_used)
    log "本批新增 $(bytes_h "$got") | 累计 $(bytes_h "$used_now") / $(bytes_h "$limit") | 窗口剩余 ${win_left}s | 源偏好: $([ "$prefer_non_cf" = "1" ] && echo non-cf || echo any)"

    [ "$BATCH_SLEEP_MS" -gt 0 ] 2>/dev/null && sleep_ms "$BATCH_SLEEP_MS"
  done
  log "本轮结束。"
}

status_cli(){
  local svc env lg th md iv cbd bsm
  svc=gotraffic.service
  env=$(systemctl show -p Environment "$svc" 2>/dev/null | sed -e 's/^Environment=//' -e 's/ /\n/g' || true)
  lg=$(echo "$env" | awk -F= '$1=="LIMIT_GB"{print $2}')
  th=$(echo "$env" | awk -F= '$1=="THREADS"{print $2}')
  md=$(echo "$env" | awk -F= '$1=="MODE"{print $2}')
  iv=$(echo "$env" | awk -F= '$1=="INTERVAL_MINUTES"{print $2}')
  cbd=$(echo "$env" | awk -F= '$1=="CHUNK_BYTES_DL"{print $2}')
  bsm=$(echo "$env" | awk -F= '$1=="BATCH_SLEEP_MS"{print $2}')
  [ -z "$lg" ] && lg="$LIMIT_GB"; [ -z "$th" ] && th="$THREADS"; [ -z "$md" ] && md="$MODE"; [ -z "$iv" ] && iv="$INTERVAL_MINUTES"
  [ -z "$cbd" ] && cbd="$CHUNK_BYTES_DL"; [ -z "$bsm" ] && bsm="$BATCH_SLEEP_MS"
  INTERVAL_MINUTES="$iv"
  ensure_window
  local used limit; used=$(get_used); limit=$((lg*1024*1024*1024))
  echo "--- 流量状态 ---"
  echo "已用: $(bytes_h "$used") / $(bytes_h "$limit")   (线程=$th 模式=$md 窗口=${iv}m 块=$cbd B 批间隔=${bsm}ms) | 窗口剩余 $(window_secs_left)s"
  echo "--- 定时器状态 ---"; systemctl list-timers gotraffic.timer --no-pager --all 2>/dev/null || true
}

edit_service_env(){ sed -i "s|Environment=\"$1=.*|Environment=\"$1=$2\"|" /etc/systemd/system/gotraffic.service; }

case "${1:-}" in
  run)        run_until_cap ;;
  status)     status_cli ;;
  d)          edit_service_env MODE download; systemctl daemon-reload; echo "模式=download";;
  u)          edit_service_env MODE upload;   systemctl daemon-reload; echo "模式=upload";;
  ud)         edit_service_env MODE ud;       systemctl daemon-reload; echo "模式=ud";;
  now|new)    systemctl start gotraffic.service ;;
  abort)      systemctl kill gotraffic.service || true; echo "已尝试中止当前任务";;
  log)        tail -f "$LOG_FILE" ;;
  stop)       systemctl stop gotraffic.timer; echo "定时器已停止";;
  resume)     systemctl start gotraffic.timer; echo "定时器已恢复";;
  config)
              old_l=$(systemctl cat gotraffic.service | awk -F= '/Environment="LIMIT_GB=/{print $3}' | tr -d '"')
              old_t=$(systemctl cat gotraffic.service | awk -F= '/Environment="THREADS=/{print $3}' | tr -d '"')
              old_i=$(systemctl cat gotraffic.service | awk -F= '/Environment="INTERVAL_MINUTES=/{print $3}' | tr -d '"')
              old_cbd=$(systemctl cat gotraffic.service | awk -F= '/Environment="CHUNK_BYTES_DL=/{print $3}' | tr -d '"')
              old_bsm=$(systemctl cat gotraffic.service | awk -F= '/Environment="BATCH_SLEEP_MS=/{print $3}' | tr -d '"')
              [ -z "$old_i" ] && old_i=$(systemctl cat gotraffic.timer | awk -F= '/^OnCalendar=/{print $2}' | sed -n 's#.*:0/\([0-9]\+\):00.*#\1#p')

              read -rp "新额度 GiB (当前=$old_l): " new_l;   new_l=${new_l:-$old_l}
              read -rp "新线程 1-32 (当前=$old_t): " new_t;   new_t=${new_t:-$old_t}
              read -rp "新间隔 分钟 (当前=$old_i): " new_i;   new_i=${new_i:-$old_i}
              read -rp "新 CHUNK_BYTES_DL 字节 (当前=${old_cbd:-$CHUNK_BYTES_DL}): " new_cbd; new_cbd=${new_cbd:-${old_cbd:-$CHUNK_BYTES_DL}}
              read -rp "新 BATCH_SLEEP_MS 毫秒 (当前=${old_bsm:-$BATCH_SLEEP_MS}): " new_bsm; new_bsm=${new_bsm:-${old_bsm:-$BATCH_SLEEP_MS}}

              edit_service_env LIMIT_GB "$new_l"
              edit_service_env THREADS  "$new_t"
              edit_service_env INTERVAL_MINUTES "$new_i"
              edit_service_env CHUNK_BYTES_DL "$new_cbd"
              edit_service_env BATCH_SLEEP_MS "$new_bsm"
              edit_service_env CHUNK_BYTES_UL "$CHUNK_BYTES_UL"
              edit_service_env ZERO_BACKOFF_MS "$ZERO_BACKOFF_MS"
              edit_service_env ZERO_BACKOFF_MAX_MS "$ZERO_BACKOFF_MAX_MS"
              edit_service_env ZERO_STREAK_SWITCH "$ZERO_STREAK_SWITCH"

              # 重写 timer：每 new_i 分钟触发
              cat >/etc/systemd/system/gotraffic.timer <<EOT
[Unit]
Description=Run GoTraffic every ${new_i} minutes
[Timer]
OnCalendar=*-*-* *:0/${new_i}:00
Unit=gotraffic.service
Persistent=true
AccuracySec=1s
[Install]
WantedBy=timers.target
EOT
              systemctl daemon-reload
              systemctl enable --now gotraffic.timer >/dev/null 2>&1 || true
              systemctl restart gotraffic.timer

              rm -f "$STATE_FILE" 2>/dev/null || true
              echo "配置已更新 ✅ (额度=${new_l}GiB 线程=${new_t} 间隔=${new_i} 分钟 块=${new_cbd}B 批间隔=${new_bsm}ms)"
              ;;
  update)     tmp=$(mktemp); if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$tmp" https://raw.githubusercontent.com/3257085208/Gotraffic/main/Gotraffic.sh; else wget -qO "$tmp" https://raw.githubusercontent.com/3257085208/Gotraffic/main/Gotraffic.sh; fi; if [ -s "$tmp" ]; then mv "$tmp" /usr/local/bin/Gotraffic.sh; chmod +x /usr/local/bin/Gotraffic.sh; echo "✅ 已下载到 /usr/local/bin/Gotraffic.sh"; else echo "❌ 更新失败"; rm -f "$tmp"; fi ;;
  uninstall)  systemctl disable --now gotraffic.timer 2>/dev/null || true; systemctl disable --now gotraffic.service 2>/dev/null || true; rm -f /etc/systemd/system/gotraffic.{service,timer}; rm -f /usr/local/bin/gotraffic-core.sh /usr/local/bin/gotr; rm -f "$LOG_FILE" "$STATE_FILE"; systemctl daemon-reload; echo "已卸载 ✅";;
  version)    echo "GoTraffic core $(date '+%F %T')";;
  *)          echo "用法: gotr {d|u|ud|now|new|abort|status|log|stop|resume|config|update|uninstall|version}";;
esac
EOF_CORE
  chmod +x /usr/local/bin/gotraffic-core.sh
}

# ----------------- gotr 分发器 -----------------
write_gotr(){
  cat >/usr/local/bin/gotr <<'EOF_GOTR'
#!/usr/bin/env bash
exec /usr/local/bin/gotraffic-core.sh "$@"
EOF_GOTR
  chmod +x /usr/local/bin/gotr
}

# ----------------- systemd 单元 -----------------
write_systemd(){
  mkdir -p /etc/gotraffic
  if [ ! -s "$URLS_DL" ]; then printf "%b" "$DEFAULT_DL_URLS" > "$URLS_DL"; fi
  [ -s "$URLS_UL" ] || echo "$DEFAULT_UL_URL" > "$URLS_UL"

  cat >/etc/systemd/system/gotraffic.service <<EOF
[Unit]
Description=GoTraffic core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
TimeoutStartSec=0
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"
Environment="LIMIT_GB=$LIMIT_GB"
Environment="INTERVAL_MINUTES=$INTERVAL_MINUTES"
Environment="THREADS=$THREADS"
Environment="MODE=$MODE"
Environment="STATE_FILE=$STATE_FILE"
Environment="LOG_FILE=$LOG_FILE"
Environment="URLS_DL=$URLS_DL"
Environment="URLS_UL=$URLS_UL"
Environment="CHUNK_BYTES_DL=$CHUNK_BYTES_DL"
Environment="CHUNK_BYTES_UL=$CHUNK_BYTES_UL"
Environment="BATCH_SLEEP_MS=$BATCH_SLEEP_MS"
Environment="ZERO_BACKOFF_MS=$ZERO_BACKOFF_MS"
Environment="ZERO_BACKOFF_MAX_MS=$ZERO_BACKOFF_MAX_MS"
Environment="ZERO_STREAK_SWITCH=$ZERO_STREAK_SWITCH"
ExecStart=/usr/local/bin/gotraffic-core.sh run
EOF

  cat >/etc/systemd/system/gotraffic.timer <<EOF
[Unit]
Description=Run GoTraffic every ${INTERVAL_MINUTES} minutes

[Timer]
OnCalendar=*-*-* *:0/${INTERVAL_MINUTES}:00
Unit=gotraffic.service
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now gotraffic.timer
  systemctl start gotraffic.service || true
}

# ----------------- 安装 -----------------
main_install(){
  banner
  read -rp "每窗口要消耗多少流量 (GiB) [10]: " LIMIT_GB; LIMIT_GB=${LIMIT_GB:-10}
  read -rp "窗口间隔时长 (分钟) [30]: " INTERVAL_MINUTES; INTERVAL_MINUTES=${INTERVAL_MINUTES:-30}
  read -rp "并发线程数 (1-32) [4]: " THREADS; THREADS=${THREADS:-4}
  [[ "$THREADS" =~ ^[0-9]+$ ]] && (( THREADS>=1 && THREADS<=32 )) || THREADS=4

  write_core
  write_gotr
  write_systemd

  echo "[$(date '+%F %T')] 安装完成 ✅" | tee -a "$LOG_FILE"
  echo "日志文件: $LOG_FILE"
  echo "快捷命令: gotr d|u|ud|now|new|abort|status|log|stop|resume|config|update|uninstall"
}

# 默认多源（供首次安装写入）
DEFAULT_DL_URLS=$'# 你也可以继续追加更多源（每行一个）\nhttps://speed.cloudflare.com/__down?bytes=104857600\nhttps://speed.cloudflare.com/__down?bytes=524288000\nhttps://speed.cloudflare.com/__down?bytes=25000000\nhttps://speed.cloudflare.com/__down?bytes=1073741824\nhttps://p1.dailygn.com/obj/g-marketing-act-assets/2024_11_28_14_54_37/mv_1128_1080px.mp4\n'
DEFAULT_UL_URL="https://speed.cloudflare.com/__down?bytes={bytes}"

main_install
