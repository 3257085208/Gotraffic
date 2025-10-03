#!/usr/bin/env bash
# ========================================
#   DLTraffic 简单版 (Hetzner 专用源)
#   功能: 下行带宽消耗 (循环)
#   用法: bash dltraffic.sh <GiB> <间隔分钟> <线程数>
#   示例: bash dltraffic.sh 7 10 4
# ========================================

set -Eeuo pipefail

LIMIT_GB=${1:-5}             # 每轮消耗多少 GiB
INTERVAL_MINUTES=${2:-30}    # 每轮间隔分钟
THREADS=${3:-2}              # 并发线程数

# 下载源列表 (Hetzner 各节点)
URLS=(
  "https://nbg1-speed.hetzner.com/1GB.bin"
  "https://fsn1-speed.hetzner.com/1GB.bin"
  "https://hel1-speed.hetzner.com/1GB.bin"
  "https://ash-speed.hetzner.com/1GB.bin"
  "https://hil-speed.hetzner.com/1GB.bin"
  "https://sin-speed.hetzner.com/1GB.bin"
)

bytes_to_human(){
  local b=${1:-0} scale=0 units=(B KiB MiB GiB TiB)
  while (( b >= 1024 && scale < ${#units[@]}-1 )); do
    b=$(( b/1024 ))
    ((scale++))
  done
  echo "$b ${units[$scale]}"
}

consume_window(){
  local target_bytes=$(( LIMIT_GB * 1024 * 1024 * 1024 ))
  local used=0
  echo "[`date '+%F %T'`] 本轮开始：目标 ${LIMIT_GB} GiB，线程 $THREADS"

  worker(){
    while (( used < target_bytes )); do
      url=${URLS[$RANDOM % ${#URLS[@]}]}
      sz=$(curl -k -L --max-time 1800 --connect-timeout 10 --retry 2 --retry-delay 2 \
                --fail --silent --show-error \
                --output /dev/null --write-out '%{size_download}' "$url" || echo 0)
      if [[ "$sz" =~ ^[0-9]+$ ]] && (( sz > 0 )); then
        (( used += sz ))
      else
        echo "[`date '+%T'`] 下载失败: $url"
        sleep 1
      fi
    done
  }

  pids=()
  for ((i=1;i<=THREADS;i++)); do
    worker &
    pids+=($!)
  done

  while :; do
    echo "[`date '+%T'`] 进度: $(bytes_to_human $used) / $(bytes_to_human $target_bytes)"
    (( used >= target_bytes )) && break
    sleep 5
  done

  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  echo "[`date '+%F %T'`] 本轮完成: $(bytes_to_human $used)"
}

# 无限循环
while :; do
  consume_window
  echo "[`date '+%F %T'`] 休息 ${INTERVAL_MINUTES} 分钟..."
  sleep $((INTERVAL_MINUTES * 60))
done
