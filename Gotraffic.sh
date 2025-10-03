#!/usr/bin/env bash
# ========================================
#   GoTraffic 一键安装器 (systemd + gotr)
# ========================================

set -Eeuo pipefail

INSTALL_DIR="/usr/local/gotraffic"
BIN_LINK="/usr/local/bin/gotr"
SERVICE="/etc/systemd/system/gotraffic.service"
TIMER="/etc/systemd/system/gotraffic.timer"

mkdir -p "$INSTALL_DIR"

# ============ 主脚本 ==============
cat > "$INSTALL_DIR/Gotraffic.sh" <<"EOF"
#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$SCRIPT_DIR/gotraffic.state"
LOCK_FILE="$SCRIPT_DIR/gotraffic.lock"
LOG_FILE="$SCRIPT_DIR/gotraffic.log"

LIMIT_GB=5
INTERVAL_MINUTES=30
THREADS=2
URLS=()

log(){
  echo -e "$1" | tee -a "$LOG_FILE"
}

bytes_to_human(){
  local b=${1:-0} scale=0 units=(B KiB MiB GiB TiB)
  while (( b >= 1024 && scale < ${#units[@]}-1 )); do
    b=$(( b/1024 )); ((scale++))
  done
  echo "$b ${units[$scale]}"
}

inc_bytes(){
  local add=$1
  exec 200>$LOCK_FILE
  flock -w 10 200
  local have=0
  [[ -s $STATE_FILE ]] && have=$(cat $STATE_FILE)
  echo $(( have + add )) > $STATE_FILE
  flock -u 200
}

ask_params(){
  read -rp "请输入要消耗的流量 (GiB): " LIMIT_GB
  read -rp "请输入间隔时间 (分钟): " INTERVAL_MINUTES
  read -rp "请输入线程数量 (1-32): " THREADS
  (( THREADS<1 )) && THREADS=1
  (( THREADS>32 )) && THREADS=32

  echo "请选择下载源："
  echo "  A) 国外 (Cloudflare)"
  echo "  B) 国内 (QQ / 学习强国)"
  read -rp "请输入选择 (A/B): " AREA

  if [[ "$AREA" =~ ^[Aa]$ ]]; then
    URLS=("https://speed.cloudflare.com/__down?during=download&bytes=1073741824")
  else
    URLS=(
      "https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
      "https://wirelesscdn-download.xuexi.cn/publish/xuexi_android/latest/xuexi_android_10002068.apk"
    )
  fi

  cat > "$SCRIPT_DIR/gotraffic.conf" <<EOC
LIMIT_GB=$LIMIT_GB
INTERVAL_MINUTES=$INTERVAL_MINUTES
THREADS=$THREADS
AREA=$AREA
EOC
}

load_params(){
  [[ -f "$SCRIPT_DIR/gotraffic.conf" ]] && source "$SCRIPT_DIR/gotraffic.conf"
  if [[ "$AREA" =~ ^[Aa]$ ]]; then
    URLS=("https://speed.cloudflare.com/__down?during=download&bytes=1073741824")
  else
    URLS=(
      "https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
      "https://wirelesscdn-download.xuexi.cn/publish/xuexi_android/latest/xuexi_android_10002068.apk"
    )
  fi
}

consume_window(){
  local target_bytes=$(( LIMIT_GB * 1024 * 1024 * 1024 ))
  echo 0 > "$STATE_FILE"
  log "[`date '+%F %T'`] 本轮开始：目标 ${LIMIT_GB} GiB，线程 $THREADS"

  worker(){
    local chunk=$((50*1024*1024))
    while :; do
      local used=$(cat "$STATE_FILE")
      (( used >= target_bytes )) && break
      url=${URLS[$RANDOM % ${#URLS[@]}]}
      sz=$(curl -k -L --range 0-$((chunk-1)) --max-time 300 \
                --connect-timeout 10 --retry 2 --retry-delay 2 \
                --fail --silent --show-error \
                --output /dev/null --write-out '%{size_download}' "$url" || echo 0)
      [[ "$sz" =~ ^[0-9]+$ ]] && (( sz > 0 )) && inc_bytes "$sz"
    done
  }

  for ((i=1;i<=THREADS;i++)); do worker & done

  while :; do
    local used=$(cat "$STATE_FILE")
    log "[`date '+%T'`] 进度: $(bytes_to_human $used) / $(bytes_to_human $target_bytes)"
    (( used >= target_bytes )) && break
    sleep 5
  done

  log "[`date '+%F %T'`] 本轮完成"
}

main_loop(){
  load_params || ask_params
  while :; do
    consume_window
    log "[`date '+%F %T'`] 休息 ${INTERVAL_MINUTES} 分钟..."
    sleep $((INTERVAL_MINUTES * 60))
  done
}

case "$1" in
  run) main_loop ;;
  uninstall)
    systemctl stop gotraffic.timer gotraffic.service || true
    systemctl disable gotraffic.timer || true
    rm -f /etc/systemd/system/gotraffic.service
    rm -f /etc/systemd/system/gotraffic.timer
    systemctl daemon-reload
    rm -rf "$SCRIPT_DIR"
    rm -f /usr/local/bin/gotr
    echo "已卸载 GoTraffic"
    ;;
  *) main_loop ;;
esac
EOF

chmod +x "$INSTALL_DIR/Gotraffic.sh"

# ============ systemd 单元文件 ==============
cat > "$SERVICE" <<"EOF"
[Unit]
Description=GoTraffic Bandwidth Consumer
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/gotraffic/Gotraffic.sh run
Restart=always
EOF

cat > "$TIMER" <<"EOF"
[Unit]
Description=GoTraffic Auto Start

[Timer]
OnBootSec=1min
Unit=gotraffic.service

[Install]
WantedBy=timers.target
EOF

# ============ 快捷命令 ==============
cat > "$BIN_LINK" <<"EOF"
#!/usr/bin/env bash
exec /usr/local/gotraffic/Gotraffic.sh "$@"
EOF

chmod +x "$BIN_LINK"

# ============ 启动服务 ==============
systemctl daemon-reload
systemctl enable gotraffic.timer
systemctl start gotraffic.timer

echo "✅ GoTraffic 已安装完成"
echo "命令: gotr run|status|log|uninstall"
echo "日志: /usr/local/gotraffic/gotraffic.log"
