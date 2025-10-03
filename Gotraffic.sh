#!/usr/bin/env bash
# Gotraffic.sh — super-simple Q&A installer (threads + per-interval cap)
set -Eeuo pipefail

# 依赖 & 权限
command -v systemctl >/dev/null || { echo "需要 systemd（systemctl）。"; exit 1; }
command -v curl >/dev/null || { echo "缺少 curl，请先安装。"; exit 1; }
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "请用 root 运行：sudo bash Gotraffic.sh"; exit 1; }

echo "=== GoTraffic 极简安装 ===（直接回车用默认）"
read -rp "每窗口配额 GiB [100]: " LIMIT_INTERVAL_GB; LIMIT_INTERVAL_GB=${LIMIT_INTERVAL_GB:-100}
read -rp "窗口时长 小时  [24]: "   INTERVAL_HOURS;   INTERVAL_HOURS=${INTERVAL_HOURS:-24}
read -rp "并发线程数    [2]: "    THREADS;          THREADS=${THREADS:-2}
read -rp "定时触发 分钟  [15]: "  TIMER_EVERY_MIN;  TIMER_EVERY_MIN=${TIMER_EVERY_MIN:-15}

# 固定默认（如需改：安装后编辑 /etc/systemd/system/gotraffic.service 的 Environment）
MODE=download           # upload=走出站，需要你自建 /upload 接口
RATE_LIMIT=             # 例如 50M；空=不限
CHUNK_MIN_MB=256
CHUNK_MAX_MB=1024
URLS_FILE=/etc/gotraffic/urls.txt
STATE_FILE=/var/lib/gotraffic/state.txt
LOG_FILE=/var/log/gotraffic.log
CORE=/usr/local/bin/gotraffic-core.sh

install -d -m 0755 /usr/local/bin /etc/gotraffic /var/lib/gotraffic
# ---- 核心脚本 ----
cat >"$CORE" <<'EOF_CORE'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${LIMIT_INTERVAL_GB:=100}"
: "${INTERVAL_HOURS:=24}"
: "${THREADS:=2}"
: "${MODE:=download}"                      # download|upload
: "${URLS_FILE:=/etc/gotraffic/urls.txt}"
: "${STATE_FILE:=/var/lib/gotraffic/state.txt}"   # 两行：start_epoch / used_bytes
: "${LOG_FILE:=/var/log/gotraffic.log}"
: "${CHUNK_MIN_MB:=256}"
: "${CHUNK_MAX_MB:=1024}"
: "${RANDOM_SLEEP_MAX:=3}"
: "${USER_AGENT:=GoTraffic/1.0}"
: "${RATE_LIMIT:=}"
: "${MAX_SESSION_GB:=5}"                  # 单次运行上限（GiB），0=不限

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")" "$(dirname "$URLS_FILE")"
touch "$STATE_FILE" "$LOG_FILE"
[ -e "$URLS_FILE" ] || cat > "$URLS_FILE" <<'EOF'
https://speed.cloudflare.com/__down?bytes={bytes}
EOF

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
bytes_h(){ awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u);i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.2f %s",b,u[i] }'; }

read_state(){ awk 'NR==1{print $1+0} NR==2{print $1+0}' "$STATE_FILE" 2>/dev/null | awk 'NF{print}'; }
write_state(){ printf '%s\n%s\n' "$1" "$2" > "$STATE_FILE"; }
ensure_window(){
  local now=$(date +%s) start=0 used=0 secs=$((INTERVAL_HOURS*3600))
  mapfile -t s < <(read_state); [ "${#s[@]}" -ge 1 ] && start="${s[0]}"; [ "${#s[@]}" -ge 2 ] && used="${s[1]}"
  if [ -z "$start" ] || [ "$start" -le 0 ] || [ $((now-start)) -ge "$secs" ]; then start="$now"; used=0; fi
  write_state "$start" "$used"
}
get_used(){ awk 'NR==2{print $1+0}' "$STATE_FILE" 2>/dev/null || echo 0; }
add_used(){ local add="$1"; mapfile -t s < <(read_state); local start="${s[0]:-$(date +%s)}" used="${s[1]:-0}"; used=$((used+add)); write_state "$start" "$used"; }
window_left_secs(){ local start=$(awk 'NR==1{print $1+0}' "$STATE_FILE" 2>/dev/null || echo 0); local secs=$((INTERVAL_HOURS*3600)); local now=$(date +%s); local left=$((secs-(now-start))); [ "$left" -lt 0 ] && left=0; echo "$left"; }

pick_url(){ awk 'NF && $1 !~ /^#/' "$URLS_FILE" | { command -v shuf >/dev/null && shuf -n1 || head -n1; }; }
prepare_url(){ local url="$1" size="$2"; echo "${url//\{bytes\}/$size}"; }
rand_chunk(){ awk -v min="$CHUNK_MIN_MB" -v max="$CHUNK_MAX_MB" 'BEGIN{srand(); m=int(min+rand()*(max-min+1)); print m*1024*1024;}'; }

curl_dl(){ # $1:url
  local url="$1"; local rate=(); [ -n "$RATE_LIMIT" ] && rate=(--limit-rate "$RATE_LIMIT")
  curl -A "$USER_AGENT" -L --fail --silent --show-error --output /dev/null "${rate[@]}" --write-out '%{size_download}\n' "$url"
}
curl_ul(){ # $1:url $2:size
  local url="$1" size="$2"; local rate=(); [ -n "$RATE_LIMIT" ] && rate=(--limit-rate "$RATE_LIMIT")
  head -c "$size" /dev/zero | curl -A "$USER_AGENT" -L --fail --silent --show-error -X POST --data-binary @- --output /dev/null "${rate[@]}" --write-out '%{size_upload}\n' "$url"
}

status(){
  ensure_window
  local limit=$((LIMIT_INTERVAL_GB*1024*1024*1024)) used="$(get_used)" left=$((limit-used)); [ "$left" -lt 0 ] && left=0
  local s="$(window_left_secs)"
  log "窗口 $(bytes_h "$used") / $(bytes_h "$limit") | 剩余 $(bytes_h "$left") | 线程=$THREADS 模式=$MODE | 窗口剩 $(printf '%dh%02dm' $((s/3600)) $((s%3600/60)))"
}

run_batch(){ # 按 THREADS 并发一批，返回本批字节数
  local allow="$1" session_left="$2" idx=0 sum=0 tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  for ((t=1; t<=THREADS; t++)); do
    [ "$allow" -le 0 ] && break
    local chunk="$(rand_chunk)"; [ "$chunk" -gt "$allow" ] && chunk="$allow"
    [ "$session_left" -gt 0 ] && [ "$chunk" -gt "$session_left" ] && chunk="$session_left"
    [ "$chunk" -le 0 ] && break
    {
      local url="$(pick_url)" u="$(prepare_url "$url" "$chunk")" got=0
      if [ "$MODE" = "upload" ]; then got="$(curl_ul "$u" "$chunk" || echo 0)"; else got="$(curl_dl "$u" || echo 0)"; fi
      got="${got%%.*}"; echo "$got" > "$tmp/o.$idx"
      printf '%s\n' "线程#$t | $(bytes_h "$chunk") → $(bytes_h "$got") | $u" >> "$tmp/log"
    } & idx=$((idx+1))
    allow=$((allow - chunk)); [ "$session_left" -gt 0 ] && session_left=$((session_left - chunk))
  done
  wait || true
  [ -f "$tmp/log" ] && while IFS= read -r L; do log "$L"; done < "$tmp/log"
  local f v; for f in "$tmp"/o.* 2>/dev/null; do [ -f "$f" ] || continue; v="$(cat "$f")"; v="${v%%.*}"; sum=$((sum+v)); done
  echo "$sum"
}

main(){
  [ "${1:-}" = "status" ] && { status; exit 0; }
  [ -f /etc/gotraffic/STOP ] && { log "发现 STOP 文件，退出。"; exit 0; }
  awk 'NF && $1 !~ /^#/' "$URLS_FILE" | grep -q . || { log "URL 列表为空：$URLS_FILE"; exit 1; }
  ensure_window
  local limit=$((LIMIT_INTERVAL_GB*1024*1024*1024)) used="$(get_used)" left=$((limit-used)); [ "$left" -lt 0 ] && left=0
  local session_cap=$((MAX_SESSION_GB*1024*1024*1024)) session_used=0
  log "启动：窗口 $(bytes_h "$limit")，已用 $(bytes_h "$used")，线程=$THREADS，模式=$MODE；本次上限=$( [ "$session_cap" -gt 0 ] && bytes_h "$session_cap" || echo 不限 )"
  [ "$left" -le 0 ] && { log "本窗口已到配额，退出。"; exit 0; }
  while :; do
    ensure_window; used="$(get_used)"; left=$((limit-used)); [ "$left" -le 0 ] && { log "达到本窗口配额。"; break; }
    local session_left=$left; [ "$session_cap" -gt 0 ] && session_left=$((session_cap-session_used)); [ "$session_cap" -gt 0 ] && [ "$session_left" -le 0 ] && { log "达到本次上限。"; break; }
    local allow="$left"; [ "$session_cap" -gt 0 ] && [ "$session_left" -lt "$allow" ] && allow="$session_left"
    local got="$(run_batch "$allow" "$session_left")"; got="${got%%.*}"; [ "$got" -le 0 ] && { log "本批为0，稍后再试"; sleep 2; continue; }
    add_used "$got"; session_used=$((session_used+got))
    log "本批合计：$(bytes_h "$got") | 本次累计：$(bytes_h "$session_used") | 窗口累计：$(bytes_h "$((used+got))")/$(bytes_h "$limit")"
    [ "$RANDOM_SLEEP_MAX" -gt 0 ] && sleep "$((RANDOM % (RANDOM_SLEEP_MAX + 1)))"
  done
  local s="$(window_left_secs)"; log "结束。窗口剩余 $(printf '%dh%02dm' $((s/3600)) $((s%3600/60)))."
}

if command -v flock >/dev/null 2>&1; then ( flock -n 9 || exit 0; main "$@" ) 9> /var/lock/gotraffic.lock; else main "$@"; fi
EOF_CORE
chmod +x "$CORE"

# URL 列表（若不存在就写入默认 CF 模板）
[ -e "$URLS_FILE" ] || { echo "https://speed.cloudflare.com/__down?bytes={bytes}" > "$URLS_FILE"; }

# systemd
cat >/etc/systemd/system/gotraffic.service <<EOF_SVC
[Unit]
Description=GoTraffic core (threads + per-interval cap)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=LIMIT_INTERVAL_GB=$LIMIT_INTERVAL_GB
Environment=INTERVAL_HOURS=$INTERVAL_HOURS
Environment=THREADS=$THREADS
Environment=MODE=$MODE
Environment=RATE_LIMIT=$RATE_LIMIT
Environment=MAX_SESSION_GB=5
Environment=CHUNK_MIN_MB=$CHUNK_MIN_MB
Environment=CHUNK_MAX_MB=$CHUNK_MAX_MB
Environment=URLS_FILE=$URLS_FILE
Environment=STATE_FILE=$STATE_FILE
Environment=LOG_FILE=$LOG_FILE
ExecStart=$CORE
Nice=10
EOF_SVC

cat >/etc/systemd/system/gotraffic.timer <<EOF_TMR
[Unit]
Description=Run GoTraffic periodically

[Timer]
OnBootSec=3m
OnUnitActiveSec=${TIMER_EVERY_MIN}m
RandomizedDelaySec=60s
Persistent=true

[Install]
WantedBy=timers.target
EOF_TMR

systemctl daemon-reload
systemctl enable --now gotraffic.timer

echo "安装完成 ✅  用法："
echo "  立即运行一次：   systemctl start gotraffic.service"
echo "  查看定时器：     systemctl status gotraffic.timer"
echo "  看状态：         /usr/local/bin/gotraffic-core.sh status"
echo "  暂停/恢复：      touch /etc/gotraffic/STOP | rm -f /etc/gotraffic/STOP"
echo "  URL 列表：       $URLS_FILE（默认已写 CF 模板）"
