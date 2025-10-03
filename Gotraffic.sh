#!/usr/bin/env bash
# gotraffic-core.sh — threads + per-interval cap (minutes window)

set -Eeuo pipefail

: "${LIMIT_INTERVAL_GB:=10}"                  # 每窗口目标消耗 GiB
: "${INTERVAL_MINUTES:=30}"                   # 窗口时长（分钟）
: "${THREADS:=2}"                             # 并发线程数
: "${MODE:=download}"                         # download | upload | ud
: "${URLS_DL:=/etc/gotraffic/urls.dl.txt}"    # 下行列表
: "${URLS_UL:=/etc/gotraffic/urls.ul.txt}"    # 上行列表
: "${STATE_FILE:=/var/lib/gotraffic/state.txt}"
: "${LOG_FILE:=/var/log/gotraffic.log}"
: "${CHUNK_MIN_MB:=128}"
: "${CHUNK_MAX_MB:=512}"
: "${RANDOM_SLEEP_MAX:=2}"
: "${USER_AGENT:=GoTraffic/1.1}"
: "${RATE_LIMIT:=}"
: "${MAX_SESSION_GB:=5}"                      # 本次执行上限 GiB，0=不限

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOG_FILE")"
touch "$STATE_FILE" "$LOG_FILE"

# 默认 URL
[ -e "$URLS_DL" ] || echo "https://speed.cloudflare.com/__down?bytes={bytes}" > "$URLS_DL"
[ -e "$URLS_UL" ] || echo "# 在这里写你的上传URL，比如 https://example.com/upload" > "$URLS_UL"

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
bytes_h(){ awk -v b="$1" 'BEGIN{split("B KB MB GB TB",u);i=1;while(b>=1024&&i<5){b/=1024;i++}printf "%.2f %s",b,u[i] }'; }
has_urls(){ awk 'NF && $1 !~ /^#/' "$1" | grep -q .; }

# ---------------- 窗口状态 ----------------
read_state(){
  if [ -f "$STATE_FILE" ]; then
    awk '
      NR==1 { print $1+0 }
      NR==2 { print $1+0 }
    ' "$STATE_FILE"
  fi
}

write_state(){
  local start="$1" used="$2"
  printf '%s\n%s\n' "$start" "$used" > "$STATE_FILE"
}

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

# ---------------- 下载 / 上传 ----------------
pick_url(){ awk 'NF && $1 !~ /^#/' "$1" | { command -v shuf >/dev/null && shuf -n1 || head -n1; }; }
prepare_url(){ local url="$1" size="$2"; echo "${url//\{bytes\}/$size}"; }
rand_chunk(){ awk -v min="$CHUNK_MIN_MB" -v max="$CHUNK_MAX_MB" 'BEGIN{srand(); m=int(min+rand()*(max-min+1)); print m*1024*1024;}'; }

curl_dl(){
  local url="$1"; local rate=(); [ -n "$RATE_LIMIT" ] && rate=(--limit-rate "$RATE_LIMIT")
  curl -A "$USER_AGENT" -L --fail --silent --show-error --output /dev/null "${rate[@]}" --write-out '%{size_download}\n' "$url"
}

curl_ul(){
  local url="$1" size="$2"; local rate=(); [ -n "$RATE_LIMIT" ] && rate=(--limit-rate "$RATE_LIMIT")
  head -c "$size" /dev/zero | curl -A "$USER_AGENT" -L --fail --silent --show-error -X POST --data-binary @- --output /dev/null "${rate[@]}" --write-out '%{size_upload}\n' "$url"
}

# ---------------- 状态 ----------------
status(){
  ensure_window
  local limit=$((LIMIT_INTERVAL_GB*1024*1024*1024)) used="$(get_used)" left=$((limit-used)); [ "$left" -lt 0 ] && left=0
  local s="$(window_left_secs)"
  log "目标消耗：$(bytes_h "$used") / $(bytes_h "$limit") | 剩余 $(bytes_h "$left") | 线程=$THREADS 模式=$MODE | 窗口剩 $(printf '%dm%02ds' $((s/60)) $((s%60)))"
}

# ---------------- 批次运行 ----------------
run_batch_dir(){ # $1=dl|ul
  local dir="$1" allow="$2" session_left="$3" idx=0 sum=0 tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  local list= ; [ "$dir" = "dl" ] && list="$URLS_DL" || list="$URLS_UL"
  if ! has_urls "$list"; then
    log "WARN: $dir 列表($list)为空，跳过。"
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
      printf '%s\n' "[$dir] 线程#$t | 计划 $(bytes_h "$chunk") → 实际 $(bytes_h "$got")" >> "$tmp/log"
    } & idx=$((idx+1))
    allow=$((allow - chunk)); [ "$session_left" -gt 0 ] && session_left=$((session_left - chunk))
  done
  wait || true
  [ -f "$tmp/log" ] && while IFS= read -r L; do log "$L"; done < "$tmp/log"
  local f v; for f in "$tmp"/o.* 2>/dev/null; do [ -f "$f" ] || continue; v="$(cat "$f")"; v="${v%%.*}"; sum=$((sum+v)); done
  echo "$sum"
}

# ---------------- 主逻辑 ----------------
main(){
  [ "${1:-}" = "status" ] && { status; exit 0; }
  [ -f /etc/gotraffic/STOP ] && { log "发现 STOP 文件，退出。"; exit 0; }

  ensure_window
  local limit=$((LIMIT_INTERVAL_GB*1024*1024*1024)) used="$(get_used)" left=$((limit-used)); [ "$left" -lt 0 ] && left=0
  local session_cap=$((MAX_SESSION_GB*1024*1024*1024)) session_used=0

  log "启动：窗口目标 $(bytes_h "$limit")，已用 $(bytes_h "$used")，线程=$THREADS 模式=$MODE"

  [ "$left" -le 0 ] && { log "本窗口已达目标，退出。"; exit 0; }

  while :; do
    ensure_window; used="$(get_used)"; left=$((limit-used)); [ "$left" -le 0 ] && { log "窗口目标完成"; break; }

    local session_left=$left; if [ "$session_cap" -gt 0 ]; then session_left=$((session_cap-session_used)); [ "$session_left" -le 0 ] && break; fi
    local allow="$left"; [ "$session_cap" -gt 0 ] && [ "$session_left" -lt "$allow" ] && allow="$session_left"

    local got_batch=0
    case "$MODE" in
      download) got_batch="$(run_batch_dir dl "$allow" "$session_left")" ;;
      upload)   got_batch="$(run_batch_dir ul "$allow" "$session_left")" ;;
      ud)       # 一半下载一半上传
        local half=$((allow/2)); [ "$half" -lt 1 ] && half="$allow"
        local got_dl="$(run_batch_dir dl "$half" "$session_left")"
        local left_after=$((allow - got_dl))
        local got_ul=0
        if [ "$left_after" -gt 0 ]; then
          local sess_after=$((session_left - got_dl)); [ "$sess_after" -lt 0 ] && sess_after=0
          got_ul="$(run_batch_dir ul "$left_after" "$sess_after")"
        fi
        got_batch=$((got_dl + got_ul))
        ;;
    esac

    got_batch="${got_batch%%.*}"
    [ "$got_batch" -le 0 ] && { log "本批为0，等待"; sleep 1; continue; }

    add_used "$got_batch"
    session_used=$((session_used+got_batch))
    log "本批 $(bytes_h "$got_batch") | 窗口累计 $(bytes_h "$((used+got_batch))")/$(bytes_h "$limit")"

    [ "$RANDOM_SLEEP_MAX" -gt 0 ] && sleep "$((RANDOM % (RANDOM_SLEEP_MAX + 1)))"
  done

  local s="$(window_left_secs)"; log "结束。窗口剩余 $(printf '%dm%02ds' $((s/60)) $((s%60)))."
}

if command -v flock >/dev/null 2>&1; then
  (flock -n 9 || exit 0; main "$@") 9> /var/lock/gotraffic.lock
else
  main "$@"
fi
