#!/usr/bin/env bash
# Gotraffic.sh — Q&A installer for a traffic burner (threads + per-interval cap)
# It installs /usr/local/bin/gotraffic-core.sh and systemd units.
set -Eeuo pipefail

# ---- prerequisites ----
if ! command -v systemctl >/dev/null 2>&1; then echo "需要 systemd（systemctl）。"; exit 1; fi
if ! command -v curl >/dev/null 2>&1; then echo "缺少 curl，请先安装（apt/dnf/yum/pacman）。"; exit 1; fi
if [ "${EUID:-$(id -u)}" -ne 0 ]; then echo "请用 root 运行：sudo bash Gotraffic.sh"; exit 1; fi

echo "=== Gotraffic 交互式安装（并发线程 + 间隔小时配额）==="
echo "直接回车采用默认值。单位：GiB/MB/小时/分钟均为整数。"

ask_num(){ local var="$1" prompt="$2" def="$3" v=""; while :; do read -rp "$prompt [$def]: " v || true; v="${v:-$def}"; [[ "$v" =~ ^[0-9]+$ ]] && { eval "$var=$v"; return; }; echo "请输入非负整数。"; done; }
ask_choice(){ local var="$1" prompt="$2" def="$3" a="$4" b="$5" v=""; while :; do read -rp "$prompt [$def]: " v || true; v="${v:-$def}"; [[ "$v" == "$a" || "$v" == "$b" ]] && { eval "$var='$v'"; return; }; echo "请输入 $a 或 $b。"; done; }
ask_str(){ local var="$1" prompt="$2" def="$3" v=""; read -rp "$prompt [$def]: " v || true; v="${v:-$def}"; eval "$var='$v'"; }

# ---- Q&A ----
ask_num LIMIT_INTERVAL_GB "每个窗口配额(GiB)" 100
ask_num INTERVAL_HOURS    "窗口时长(小时)，到点自动重置" 24
ask_num THREADS           "并发线程数（建议 1~8）" 2
ask_choice MODE           "模式（download=入站；upload=出站需自建接收端）" "download" "download" "upload"
ask_str RATE_LIMIT        "单连接限速（如 50M；留空=不限）" ""
ask_num CHUNK_MIN_MB      "单块最小MB" 256
ask_num CHUNK_MAX_MB      "单块最大MB" 1024
if [ "$CHUNK_MAX_MB" -lt "$CHUNK_MIN_MB" ]; then t="$CHUNK_MIN_MB"; CHUNK_MIN_MB="$CHUNK_MAX_MB"; CHUNK_MAX_MB="$t"; fi
ask_num MAX_SESSION_GB    "单次触发最多消耗(GiB)，0=不限（建议 1~10）" 5
ask_num TIMER_EVERY_MIN   "定时触发频率（每多少分钟运行一次）" 15
ask_str TIMEZONE          "时区（留空=系统默认，如 Asia/Shanghai）" ""
ask_str URLS_FILE         "URL列表路径" "/etc/gotraffic/urls.txt"
ask_str STATE_FILE        "状态文件路径" "/var/lib/gotraffic/state.txt"
ask_str LOG_FILE          "日志文件路径" "/var/log/gotraffic.log"

# ---- install core runner ----
install -d -m 0755 /usr/local/bin
cat >/usr/local/bin/gotraffic-core.sh <<'EOF_CORE'
#!/usr/bin/env bash
# gotraffic-core.sh — threads + per-interval cap (X hours). Any Linux with systemd/cron.
set -Eeuo pipefail

: "${LIMIT_INTERVAL_GB:=100}"        # 每个窗口配额（GiB）
: "${INTERVAL_HOURS:=24}"            # 窗口时长（小时）
: "${THREADS:=2}"                    # 并发线程数
: "${MODE:=download}"                # download | upload
: "${URLS_FILE:=/etc/gotraffic/urls.txt}"
: "${STATE_FILE:=/var/lib/gotraffic/state.txt}"   # 两行：start_epoch / used_bytes
: "${LOG_FILE:=/var/log/gotraffic.log}"
: "${CHUNK_MIN_MB:=256}"
: "${CHUNK_MAX_MB:=1024}"
: "${RANDOM_SLEEP_MAX:=3}"
: "${USER_AGENT:=GoTraffic/1.0}"
: "${RATE_LIMIT:=}"                  # e.g. 50M / 1000k
: "${MAX_SESSION_GB:=5}"             # 本次执行最多消耗，0=不限

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")" "$(dirname "$URLS_FILE")"
touch "$STATE_FILE" "$LOG_FILE"
[ -e "$URLS_FILE" ] || cat > "$URLS_FILE" <<'EOF'
# 模板端点（精准按字节）。谨慎使用公共测速端点，遵守对方条款。
https://speed.cloudflare.com/__down?bytes={bytes}
# 也可追加可Range的大文件URL：
# https://cdn.example.com/big.bin
EOF

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
bytes_h(){ awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u);i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.2f %s",b,u[i] }'; }

# ---- window state ----
read_state(){ awk 'NR==1{print $1+0} NR==2{print $1+0}' "$STATE_FILE" 2>/dev/null | awk 'NF{print}'; }
write_state(){ printf '%s\n%s\n' "$1" "$2" > "$STATE_FILE"; }
ensure_window(){
  local now_ts start used secs
  now_ts=$(date +%s)
  secs=$((INTERVAL_HOURS*3600))
  start=0; used=0
  mapfile -t s < <(read_state)
  [ "${#s[@]}" -ge 1 ] && start="${s[0]}"
  [ "${#s[@]}" -ge 2 ] && used="${s[1]}"
  if [ -z "$start" ] || [ "$start" -le 0 ] || [ $((now_ts - start)) -ge "$secs" ]; then
    start="$now_ts"; used=0
  fi
  write_state "$start" "$used"
}
get_used(){ awk 'NR==2{print $1+0}' "$STATE_FILE" 2>/dev/null || echo 0; }
add_used(){ local add="$1" start used; mapfile -t s < <(read_state); start="${s[0]:-$(date +%s)}"; used="${s[1]:-0}"; used=$((used+add)); write_state "$start" "$used"; }
window_left_secs(){ local start=$(awk 'NR==1{print $1+0}' "$STATE_FILE" 2>/dev/null || echo 0); local secs=$((INTERVAL_HOURS*3600)); local now=$(date +%s); local left=$((secs-(now-start))); [ "$left" -lt 0 ] && left=0; echo "$left"; }

# ---- transfer helpers ----
pick_url(){ awk 'NF && $1 !~ /^#/' "$URLS_FILE" | { command -v shuf >/dev/null && shuf -n1 || (sort -R | head -n1); }; }
prepare_url(){ local url="$1" size="$2"; echo "${url//\{bytes\}/$size}"; }
rand_chunk(){ awk -v min="$CHUNK_MIN_MB" -v max="$CHUNK_MAX_MB" 'BEGIN{srand(); m=int(min+rand()*(max-min+1)); print m*1024*1024;}'; }

curl_dl(){ # $1:url $2:size_bytes
  local url="$1" size="$2" ; local rate=(); [ -n "$RATE_LIMIT" ] && rate=(--limit-rate "$RATE_LIMIT")
  if [[ "$url" == *"__down?bytes="* ]]; then
    curl -A "$USER_AGENT" -L --fail --silent --show-error --output /dev/null "${rate[@]}" --write-out '%{size_download}\n' "$url"
  else
    curl -A "$USER_AGENT" -L --fail --silent --show-error -H "Range: bytes=0-$((size-1))" --output /dev/null "${rate[@]}" --write-out '%{size_download}\n' "$url"
  fi
}
curl_ul(){ # $1:url $2:size_bytes
  local url="$1" size="$2" ; local rate=(); [ -n "$RATE_LIMIT" ] && rate=(--limit-rate "$RATE_LIMIT")
  head -c "$size" /dev/zero | curl -A "$USER_AGENT" -L --fail --silent --show-error -X POST --data-binary @- --output /dev/null "${rate[@]}" --write-out '%{size_upload}\n' "$url"
}

status(){
  ensure_window
  local limit=$((LIMIT_INTERVAL_GB*1024*1024*1024))
  local used="$(get_used)"
  local left=$((limit-used)); [ "$left" -lt 0 ] && left=0
  local secs_left="$(window_left_secs)"
  log "窗口配额：$(bytes_h "$used") / $(bytes_h "$limit") | 剩余 $(bytes_h "$left") | 窗口剩余 $(printf '%dh%02dm' $((secs_left/3600)) $((secs_left%3600/60))) | 线程=$THREADS 模式=$MODE"
}

run_batch(){ # 并发跑一批，返回本批总字节
  local total_left="$1" session_left="$2" ; local idx=0 sum=0 t
  local tmpdir; tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' RETURN
  local alloc_left="$total_left"
  for ((t=1; t<=THREADS; t++)); do
    [ "$alloc_left" -le 0 ] && break
    local chunk="$(rand_chunk)"
    [ "$chunk" -gt "$alloc_left" ] && chunk="$alloc_left"
    if [ "$session_left" -gt 0 ] && [ "$chunk" -gt "$session_left" ]; then chunk="$session_left"; fi
    [ "$chunk" -le 0 ] && break
    {
      local url u got=0
      url="$(pick_url)"; u="$(prepare_url "$url" "$chunk")"
      if [ "$MODE" = "upload" ]; then got="$(curl_ul "$u" "$chunk" || echo 0)"; else got="$(curl_dl "$u" "$chunk" || echo 0)"; fi
      got="${got%%.*}"
      echo "$got" > "$tmpdir/out.$idx"
      printf '%s\n' "线程#$t 目标：$u | 计划 $(bytes_h "$chunk") | 实际 $(bytes_h "$got")" >> "$tmpdir/log"
    } &
    idx=$((idx+1))
    alloc_left=$((alloc_left - chunk))
    [ "$session_left" -gt 0 ] && session_left=$((session_left - chunk))
  done
  wait || true
  [ -f "$tmpdir/log" ] && while IFS= read -r L; do log "$L"; done < "$tmpdir/log"
  local f v
  for f in "$tmpdir"/out.* 2>/dev/null; do [ -f "$f" ] || continue; v="$(cat "$f")"; v="${v%%.*}"; sum=$((sum+v)); done
  echo "$sum"
}

main(){
  [ "${1:-}" = "status" ] && { status; exit 0; }
  [ -f /etc/gotraffic/STOP ] && { log "发现 STOP 文件，退出。"; exit 0; }
  if ! awk 'NF && $1 !~ /^#/' "$URLS_FILE" | grep -q .; then log "未找到可用URL：$URLS_FILE"; exit 1; fi
  ensure_window

  local limit=$((LIMIT_INTERVAL_GB*1024*1024*1024))
  local used="$(get_used)"
  local left=$((limit-used)); [ "$left" -lt 0 ] && left=0
  local session_cap=$((MAX_SESSION_GB*1024*1024*1024))
  local session_used=0

  log "启动：窗口 $(bytes_h "$limit")，已用 $(bytes_h "$used")，线程=$THREADS，模式=$MODE；本次上限=$( [ "$session_cap" -gt 0 ] && bytes_h "$session_cap" || echo 不限 )"
  [ "$left" -le 0 ] && { log "本窗口已到配额，退出。"; exit 0; }

  while :; do
    ensure_window
    used="$(get_used)"
    left=$((limit-used))
    [ "$left" -le 0 ] && { log "达到本窗口配额，结束本次。"; break; }

    local session_left=$left
    if [ "$session_cap" -gt 0 ]; then
      session_left=$((session_cap-session_used))
      [ "$session_left" -le 0 ] && { log "达到本次执行上限，结束。"; break; }
      [ "$left" -lt "$session_left" ] || true
    fi

    local batch_allow="$left"
    if [ "$session_cap" -gt 0 ] && [ "$session_left" -lt "$batch_allow" ]; then batch_allow="$session_left"; fi
    [ "$batch_allow" -le 0 ] && break

    local got_batch; got_batch="$(run_batch "$batch_allow" "$session_left")"; got_batch="${got_batch%%.*}"
    [ "$got_batch" -le 0 ] && { log "本批传输为0，稍后重试"; sleep 2; continue; }

    add_used "$got_batch"
    session_used=$((session_used+got_batch))
    log "本批合计：$(bytes_h "$got_batch") | 本次累计：$(bytes_h "$session_used") | 窗口累计：$(bytes_h "$((used+got_batch))")/$(bytes_h "$limit")"

    [ "$RANDOM_SLEEP_MAX" -gt 0 ] && sleep "$((RANDOM % (RANDOM_SLEEP_MAX + 1)))"
  done

  local left_secs; left_secs="$(window_left_secs)"
  log "结束。本窗口还剩 $(printf '%dh%02dm' $((left_secs/3600)) $((left_secs%3600/60)))."
}

if command -v flock >/dev/null 2>&1; then ( flock -n 9 || exit 0; main "$@" ) 9> /var/lock/gotraffic.lock; else main "$@"; fi
EOF_CORE
chmod +x /usr/local/bin/gotraffic-core.sh

# default URLs file
install -d -m 0755 "$(dirname "$URLS_FILE")"
if [ ! -e "$URLS_FILE" ]; then
  cat >"$URLS_FILE" <<'EOF_URLS'
# 默认使用 Cloudflare 测速端点模板（脚本会替换 {bytes} 为本次计划字节）
https://speed.cloudflare.com/__down?bytes={bytes}
# 也可追加你自己的可Range大文件链接：
# https://cdn.example.com/big.bin
EOF_URLS
fi

# ---- systemd units ----
cat >/etc/systemd/system/gotraffic.service <<EOF_SVC
[Unit]
Description=GoTraffic core (threads + per-interval cap)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
$( [ -n "$TIMEZONE" ] && echo "Environment=TZ=$TIMEZONE" )
Environment=LIMIT_INTERVAL_GB=$LIMIT_INTERVAL_GB
Environment=INTERVAL_HOURS=$INTERVAL_HOURS
Environment=THREADS=$THREADS
Environment=MODE=$MODE
Environment=RATE_LIMIT=$RATE_LIMIT
Environment=MAX_SESSION_GB=$MAX_SESSION_GB
Environment=CHUNK_MIN_MB=$CHUNK_MIN_MB
Environment=CHUNK_MAX_MB=$CHUNK_MAX_MB
Environment=URLS_FILE=$URLS_FILE
Environment=STATE_FILE=$STATE_FILE
Environment=LOG_FILE=$LOG_FILE
ExecStart=/usr/local/bin/gotraffic-core.sh
Nice=10
EOF_SVC

cat >/etc/systemd/system/gotraffic.timer <<EOF_TMR
[Unit]
Description=Run GoTraffic periodically

[Timer]
OnBootSec=5m
OnUnitActiveSec=${TIMER_EVERY_MIN}m
RandomizedDelaySec=2m
Persistent=true

[Install]
WantedBy=timers.target
EOF_TMR

systemctl daemon-reload
systemctl enable --now gotraffic.timer

echo
echo "=== 安装完成！==="
echo "线程数：$THREADS | 窗口：每 $INTERVAL_HOURS 小时配额 $LIMIT_INTERVAL_GB GiB"
echo "定时器：gotraffic.timer（每 ${TIMER_EVERY_MIN} 分钟触发一次）"
echo
echo "常用命令："
echo "  立即运行一次：  systemctl start gotraffic.service"
echo "  查看定时器：    systemctl status gotraffic.timer"
echo "  最近日志：      journalctl -u gotraffic.service -n 50 --no-pager"
echo "  查看窗口状态：  /usr/local/bin/gotraffic-core.sh status"
echo "  暂停/恢复：     touch /etc/gotraffic/STOP  |  rm -f /etc/gotraffic/STOP"
echo
echo "URL 列表：$URLS_FILE"
echo "日志文件：$LOG_FILE"
echo "状态文件：$STATE_FILE"
if [ "$MODE" = "upload" ]; then
  echo "提示：你选择了 upload（出站）。请把 $URLS_FILE 改为你的接收端URL（建议走CDN反代的 /upload），核心会 POST /dev/zero 指定字节数。"
fi
