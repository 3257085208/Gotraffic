#!/usr/bin/env bash
# Gotraffic.sh — minutes-based window + modes (d/u/ud) + uninstall + gotr shortcut
set -Eeuo pipefail

# deps & root
command -v systemctl >/dev/null || { echo "需要 systemd（systemctl）。"; exit 1; }
command -v curl >/dev/null || { echo "缺少 curl，请先安装。"; exit 1; }
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "请用 root 运行：sudo bash Gotraffic.sh"; exit 1; }

echo "=== GoTraffic 安装（分钟级窗口）==="
read -rp "每个窗口要消耗多少流量（GiB）[10]: " LIMIT_INTERVAL_GB; LIMIT_INTERVAL_GB=${LIMIT_INTERVAL_GB:-10}
read -rp "窗口间隔时长（分钟）[30]: "          INTERVAL_MINUTES; INTERVAL_MINUTES=${INTERVAL_MINUTES:-30}

# defaults (可后续用 systemd edit 调整)
THREADS=2                 # 并发线程默认 2
MODE=download             # 默认下行
RATE_LIMIT=               # 例 50M；空=不限
CHUNK_MIN_MB=128
CHUNK_MAX_MB=512
TIMER_EVERY_MIN=2         # 每 2 分钟触发
URLS_DL=/etc/gotraffic/urls.dl.txt
URLS_UL=/etc/gotraffic/urls.ul.txt
STATE_FILE=/var/lib/gotraffic/state.txt
LOG_FILE=/var/log/gotraffic.log
CORE=/usr/local/bin/gotraffic-core.sh

install -d -m 0755 /usr/local/bin /etc/gotraffic /var/lib/gotraffic

# ---------------- 核心程序（支持 d/u/ud） ----------------
cat >"$CORE" <<'EOF_CORE'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${LIMIT_INTERVAL_GB:=10}"                 # 每个窗口的目标消耗（GiB）
: "${INTERVAL_MINUTES:=30}"                  # 窗口时长（分钟）
: "${THREADS:=2}"                            # 并发线程
: "${MODE:=download}"                        # download | upload | ud
: "${URLS_DL:=/etc/gotraffic/urls.dl.txt}"   # 下行拉取URL列表
: "${URLS_UL:=/etc/gotraffic/urls.ul.txt}"   # 上行上传URL列表（你自备接收端）
: "${STATE_FILE:=/var/lib/gotraffic/state.txt}"  # 两行：start_epoch / used_bytes
: "${LOG_FILE:=/var/log/gotraffic.log}"
: "${CHUNK_MIN_MB:=128}"
: "${CHUNK_MAX_MB:=512}"
: "${RANDOM_SLEEP_MAX:=2}"
: "${USER_AGENT:=GoTraffic/1.1}"
: "${RATE_LIMIT:=}"
: "${MAX_SESSION_GB:=5}"                     # 本次执行最多消耗（GiB），0=不限

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")"
touch "$STATE_FILE" "$LOG_FILE"

# 缺省下载URL列表（CF测速，精准字节；请合规使用）
[ -e "$URLS_DL" ] || cat > "$URLS_DL" <<'EOF'
https://speed.cloudflare.com/__down?bytes={bytes}
EOF
# 缺省上传URL列表（示例；需改成你的接收端 /upload）
[ -e "$URLS_UL" ] || cat > "$URLS_UL" <<'EOF'
# 在这里放你的上传接收端URL（会以 POST /dev/zero 方式上传指定字节）
# 例如（请改成你自己的域名，确保后端丢弃请求体不写盘）：
# https://upload.yourdomain.com/upload
EOF

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
bytes_h(){ awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u);i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.2f %s",b,u[i] }'; }
has_urls(){ awk 'NF && $1 !~ /^#/' "$1" | grep -q .; }

# —— 窗口状态（start_epoch, used_bytes）——
read_state(){ awk 'NR==1{print $1+0} NR==2{print $1+0}' "$STATE_FILE" 2>/dev/null | awk 'NF{print}'; }
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
window_left_secs(){ local start=$(awk 'NR==1{print $1+0}' "$STATE_FILE" 2>/dev/null || echo 0); local secs=$((INTERVAL_MINUTES*60)); local now=$(date +%s); local left=$((secs-(now-start))); [ "$left" -lt 0 ] && left=0; echo "$left"; }

# —— 传输工具 —— 
pick_url(){ awk 'NF && $1 !~ /^#/' "$1" | { command -v shuf >/dev/null && shuf -n1 || head -n1; }; }
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
  log "目标消耗：$(bytes_h "$used") / $(bytes_h "$limit") | 剩余 $(bytes_h "$left") | 线程=$THREADS 模式=$MODE | 窗口剩 $(printf '%dm%02ds' $((s/60)) $((s%60)))"
}

run_batch_dir(){ # $1:dl|ul  $2:allow_bytes  $3:session_left_bytes
  local dir="$1" allow="$2" session_left="$3" idx=0 sum=0 tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  local list= ; [ "$dir" = "dl" ] && list="$URLS_DL" || list="$URLS_UL"
  if ! has_urls "$list"; then
    log "WARN: $dir 列表($list)为空，跳过该方向。"
    echo 0; return
  fi
  for ((t=1; t<=THREADS; t++)); do
    [ "$allow" -le 0 ] && break
    local chunk="$(rand_chunk)"; [ "$chunk" -gt "$allow" ] && chunk="$allow"
    [ "$session_left" -gt 0 ] && [ "$chunk" -gt "$session_left" ] && chunk="$session_left"
    [ "$chunk" -le 0 ] && break
    {
      local url="$(pick_url "$list")" u="$(prepare_url "$url" "$chunk")" got=0
      if [ "$dir" = "ul" ]; then got="$(curl_ul "$u" "$chunk" || echo 0)"; else got="$(curl_dl "$u" || echo 0)"; fi
      got="${got%%.*}"; echo "$got" > "$tmp/o.$idx"
      printf '%s\n' "[$dir] 线程#$t | 计划 $(bytes_h "$chunk") → 实际 $(bytes_h "$got") | $u" >> "$tmp/log"
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
  ensure_window

  local limit=$((LIMIT_INTERVAL_GB*1024*1024*1024)) used="$(get_used)" left=$((limit-used)); [ "$left" -lt 0 ] && left=0
  local session_cap=$((MAX_SESSION_GB*1024*1024*1024)) session_used=0
  log "启动：窗口目标 $(bytes_h "$limit")，已用 $(bytes_h "$used")，线程=$THREADS，模式=$MODE；本次上限=$( [ "$session_cap" -gt 0 ] && bytes_h "$session_cap" || echo 不限 )"
  [ "$left" -le 0 ] && { log "本窗口已达目标，退出。"; exit 0; }

  while :; do
    ensure_window; used="$(get_used)"; left=$((limit-used)); [ "$left" -le 0 ] && { log "达到本窗口目标。"; break; }
    local session_left=$left; if [ "$session_cap" -gt 0 ]; then session_left=$((session_cap-session_used)); [ "$session_left" -le 0 ] && { log "达到本次上限。"; break; } fi
    local allow="$left"; [ "$session_cap" -gt 0 ] && [ "$session_left" -lt "$allow" ] && allow="$session_left"
    [ "$allow" -le 0 ] && break

    local got_batch=0
    case "$MODE" in
      download) got_batch="$(run_batch_dir dl "$allow" "$session_left")" ;;
      upload)   got_batch="$(run_batch_dir ul "$allow" "$session_left")" ;;
      ud)
        # 下行/上行各取一半（整数除2）；如果某方向列表为空，则尽量由另一方向完成
        local half=$((allow/2)); [ "$half" -lt 1 ] && half="$allow"
        local got_dl=0 got_ul=0
        if has_urls "$URLS_DL"; then got_dl="$(run_batch_dir dl "$half" "$session_left")"; fi
        # 更新剩余再跑上行
        local left_after=$((allow - got_dl))
        if has_urls "$URLS_UL" && [ "$left_after" -gt 0 ]; then
          local sess_after=$session_left; [ "$session_cap" -gt 0 ] && sess_after=$((session_left - got_dl))
          [ "$sess_after" -lt 0 ] && sess_after=0
          got_ul="$(run_batch_dir ul "$left_after" "$sess_after")"
        fi
        got_batch=$((got_dl + got_ul))
        ;;
      *) log "未知 MODE=$MODE"; exit 1;;
    esac

    got_batch="${got_batch%%.*}"
    [ "$got_batch" -le 0 ] && { log "本批为0，稍后重试"; sleep 1; continue; }
    add_used "$got_batch"
    session_used=$((session_used+got_batch))
    log "本批合计：$(bytes_h "$got_batch") | 本次累计：$(bytes_h "$session_used") | 窗口累计：$(bytes_h "$((used+got_batch))")/$(bytes_h "$limit")"
    [ "$RANDOM_SLEEP_MAX" -gt 0 ] && sleep "$((RANDOM % (RANDOM_SLEEP_MAX + 1)))"
  done

  local s="$(window_left_secs)"; log "结束。窗口剩余 $(printf '%dm%02ds' $((s/60)) $((s%60)))."
}

if command -v flock >/dev/null 2>&1; then ( flock -n 9 || exit 0; main "$@" ) 9> /var/lock/gotraffic.lock; else main "$@"; fi
EOF_CORE
chmod +x "$CORE"

# ---------------- systemd service/timer ----------------
cat >/etc/systemd/system/gotraffic.service <<EOF_SVC
[Unit]
Description=GoTraffic core (minutes window; d/u/ud)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=LIMIT_INTERVAL_GB=$LIMIT_INTERVAL_GB
Environment=INTERVAL_MINUTES=$INTERVAL_MINUTES
Environment=THREADS=$THREADS
Environment=MODE=$MODE
Environment=RATE_LIMIT=$RATE_LIMIT
Environment=CHUNK_MIN_MB=$CHUNK_MIN_MB
Environment=CHUNK_MAX_MB=$CHUNK_MAX_MB
Environment=URLS_DL=$URLS_DL
Environment=URLS_UL=$URLS_UL
Environment=STATE_FILE=$STATE_FILE
Environment=LOG_FILE=$LOG_FILE
ExecStart=$CORE
Nice=10
EOF_SVC

cat >/etc/systemd/system/gotraffic.timer <<EOF_TMR
[Unit]
Description=Run GoTraffic every ${TIMER_EVERY_MIN} minutes
[Timer]
OnBootSec=1m
OnUnitActiveSec=${TIMER_EVERY_MIN}m
RandomizedDelaySec=30s
Persistent=true
[Install]
WantedBy=timers.target
EOF_TMR

systemctl daemon-reload
systemctl enable --now gotraffic.timer

# ---------------- 快捷命令 gotr ----------------
cat >/usr/local/bin/gotr <<'EOF_CLI'
#!/usr/bin/env bash
set -Eeuo pipefail
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || exec sudo -n "$0" "$@"; }
need_root
dropin='/etc/systemd/system/gotraffic.service.d'; mkdir -p "$dropin"
svc='gotraffic.service'
core='/usr/local/bin/gotraffic-core.sh'

set_env(){
  local k="$1" v="$2" f="$dropin/override.conf"
  if [ ! -e "$f" ]; then
    printf "[Service]\nEnvironment=%s=%s\n" "$k" "$v" > "$f"
  else
    if grep -qE "^[[:space:]]*Environment=${k}=" "$f"; then
      sed -i "s|^[[:space:]]*Environment=${k}=.*|Environment=${k}=${v}|" "$f"
    else
      printf "Environment=%s=%s\n" "$k" "$v" >> "$f"
    fi
  fi
}

case "${1:-}" in
  d)   set_env MODE download; systemctl daemon-reload; systemctl restart gotraffic.timer; echo "已切换：下行(download)";;
  u)   set_env MODE upload;   systemctl daemon-reload; systemctl restart gotraffic.timer; echo "已切换：上行(upload)";;
  ud)  set_env MODE ud;       systemctl daemon-reload; systemctl restart gotraffic.timer; echo "已切换：上下行(ud)";;
  now) systemctl start "$svc";;
  status) "$core" status;;
  uninstall)
    systemctl disable --now gotraffic.timer || true
    systemctl stop "$svc" 2>/dev/null || true
    rm -f /etc/systemd/system/gotraffic.{service,timer}
    rm -rf /etc/systemd/system/gotraffic.service.d
    systemctl daemon-reload
    rm -f /usr/local/bin/gotraffic-core.sh /usr/local/bin/gotr
    rm -rf /etc/gotraffic /var/lib/gotraffic /var/lock/gotraffic.lock
    rm -f /var/log/gotraffic.log
    echo "GoTraffic 已卸载完成。"
    ;;
  *)
    cat <<'HLP'
用法:
  gotr d        # 只消耗下行（下载）
  gotr u        # 只消耗上行（上传）
  gotr ud       # 上下行都要（本批按半数/剩余分摊）
  gotr now      # 立即运行一次
  gotr status   # 查看当前窗口进度
  gotr uninstall# 卸载(含 systemd 与文件)
说明:
  上传模式需要你在 /etc/gotraffic/urls.ul.txt 配置自己的上传接收端 URL。
  下载 URL 在 /etc/gotraffic/urls.dl.txt（默认已写 CF 测速端点）。
HLP
    ;;
esac
EOF_CLI
chmod +x /usr/local/bin/gotr

echo
echo "安装完成 ✅"
echo "快捷命令： gotr d | gotr u | gotr ud | gotr now | gotr status | gotr uninstall"
echo "下载URL：  /etc/gotraffic/urls.dl.txt   （默认 CF 测速端点）"
echo "上传URL：  /etc/gotraffic/urls.ul.txt   （请填你的 /upload 接口）"
echo "查看状态： /usr/local/bin/gotraffic-core.sh status"
