#!/usr/bin/env bash
# ========================================
#   GoTraffic 本地目录版 + 可修改参数 + systemd工具
#   版本: v1.2.0
#   关键特性：
#     - run：自动安装/更新 systemd 并在后台启动服务（退出 SSH 也继续跑）
#     - run-foreground：前台运行调试
#     - config / set / show：修改与查看参数
#     - install-systemd / remove-systemd：安装/移除 systemd 单元（指向当前目录）
# ========================================

set -Eeuo pipefail

VERSION="v1.2.0"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
STATE_FILE="$SCRIPT_DIR/gotraffic.state"
LOCK_FILE="$SCRIPT_DIR/gotraffic.lock"
LOG_FILE="$SCRIPT_DIR/gotraffic.log"
CONF_FILE="$SCRIPT_DIR/gotraffic.conf"
SERVICE="/etc/systemd/system/gotraffic.service"
TIMER="/etc/systemd/system/gotraffic.timer"

# 默认参数（可由 config / set 写入）
LIMIT_GB=5
INTERVAL_MINUTES=30
THREADS=2
AREA="A"     # A=国外(Cloudflare), B=国内(QQ/学习强国)
CHUNK_MB=50  # 每块下载大小(MB)：国外 bytes=，国内 Range
URLS=()

UA="gotraffic/${VERSION}"

# ---------- 工具 ----------
log(){ echo -e "${1:-}" | tee -a "$LOG_FILE"; }
bytes_to_human(){ local b=${1:-0} s=0 u=(B KiB MiB GiB TiB); while ((b>=1024 && s<${#u[@]}-1)); do b=$((b/1024)); ((s++)); done; echo "$b ${u[$s]}"; }
inc_bytes(){ local add=$1; exec 200>"$LOCK_FILE"; flock -w 10 200; local have=0; [[ -s "$STATE_FILE" ]] && have=$(cat "$STATE_FILE"); echo $((have+add)) > "$STATE_FILE"; flock -u 200; }

pick_urls_by_area(){
  if [[ "${AREA:-A}" =~ ^[Aa]$ ]]; then
    URLS=("https://speed.cloudflare.com/__down")   # 用 bytes= 控制块大小
  else
    URLS=(
      "https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
      "https://wirelesscdn-download.xuexi.cn/publish/xuexi_android/latest/xuexi_android_10002068.apk"
    )
  fi
}

# ---------- 配置 ----------
write_conf(){
  cat > "$CONF_FILE" <<EOC
LIMIT_GB=$LIMIT_GB
INTERVAL_MINUTES=$INTERVAL_MINUTES
THREADS=$THREADS
AREA=$AREA
CHUNK_MB=$CHUNK_MB
EOC
}

load_conf(){
  if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
  fi
  pick_urls_by_area
}

ensure_conf_noninteractive(){
  if [[ ! -f "$CONF_FILE" ]]; then
    echo "[FATAL] 未找到配置文件：$CONF_FILE"
    echo "        先运行：bash Gotraffic.sh config   或   bash Gotraffic.sh set limit=... interval=... threads=... area=A|B [chunk=...]"
    exit 1
  fi
}

# ---------- 修改参数 ----------
cmd_config(){
  echo "=== GoTraffic ${VERSION} 参数设置 ==="
  read -rp "请输入要消耗的流量 (GiB): " LIMIT_GB
  read -rp "请输入间隔时间 (分钟): " INTERVAL_MINUTES
  read -rp "请输入线程数量 (1-32): " THREADS
  ((THREADS<1)) && THREADS=1; ((THREADS>32)) && THREADS=32
  echo "请选择下载源："; echo "  A) 国外 (Cloudflare)"; echo "  B) 国内 (QQ / 学习强国)"
  read -rp "请输入选择 (A/B): " AREA
  [[ -z "${AREA:-}" ]] && AREA="A"
  read -rp "可选：每块下载大小(MB，默认50): " CHUNK_MB_IN || true
  [[ -n "${CHUNK_MB_IN:-}" ]] && CHUNK_MB="$CHUNK_MB_IN"
  pick_urls_by_area
  write_conf
  log "[配置已保存] $CONF_FILE"
  cmd_show
}

cmd_set(){
  load_conf
  local kv
  for kv in "$@"; do
    case "$kv" in
      limit=*|LIMIT_GB=*)           LIMIT_GB="${kv#*=}";;
      interval=*|INTERVAL_MINUTES=*)INTERVAL_MINUTES="${kv#*=}";;
      threads=*|THREADS=*)          THREADS="${kv#*=}";;
      area=*|AREA=*)                AREA="${kv#*=}";;
      chunk=*|CHUNK_MB=*)           CHUNK_MB="${kv#*=}";;
      *) echo "忽略未知参数：$kv";;
    esac
  done
  ((THREADS<1)) && THREADS=1
  ((THREADS>32)) && THREADS=32
  [[ -z "${AREA:-}" ]] && AREA="A"
  [[ -z "${CHUNK_MB:-}" ]] && CHUNK_MB=50
  pick_urls_by_area
  write_conf
  log "[OK] 已更新配置："
  cmd_show
}

cmd_show(){
  load_conf
  echo "--------- 当前配置 ---------"
  echo "版本         : $VERSION"
  echo "流量 (GiB)   : $LIMIT_GB"
  echo "间隔 (分钟)  : $INTERVAL_MINUTES"
  echo "线程数       : $THREADS"
  echo "节点区域     : $AREA   (A=国外 Cloudflare, B=国内)"
  echo "分块大小(MB) : $CHUNK_MB"
  echo "配置文件     : $CONF_FILE"
  echo "日志文件     : $LOG_FILE"
  echo "脚本目录     : $SCRIPT_DIR"
  echo "---------------------------"
}

# ---------- 下载核心 ----------
consume_window(){
  local target=$((LIMIT_GB*1024*1024*1024))
  local CHUNK_BYTES=$((CHUNK_MB*1024*1024))
  echo 0 > "$STATE_FILE"
  log "[`date '+%F %T'`] 本轮开始：目标 ${LIMIT_GB} GiB，线程 $THREADS，源：${AREA}，分块 ${CHUNK_MB}MB"

  worker(){
    while :; do
      local used=$(cat "$STATE_FILE"); ((used>=target)) && break
      local base=${URLS[$RANDOM % ${#URLS[@]}]}
      local sz=0
      if [[ "${AREA:-A}" =~ ^[Aa]$ ]]; then
        sz=$(curl -H "User-Agent: ${UA}" -k -L --http1.1 \
              --max-time 300 --connect-timeout 10 --retry 2 --retry-delay 2 \
              --fail --silent --show-error --output /dev/null --write-out '%{size_download}' \
              "${base}?bytes=${CHUNK_BYTES}" || echo 0)
      else
        sz=$(curl -H "User-Agent: ${UA}" -k -L --range 0-$((CHUNK_BYTES-1)) --http1.1 \
              --max-time 300 --connect-timeout 10 --retry 2 --retry-delay 2 \
              --fail --silent --show-error --output /dev/null --write-out '%{size_download}' \
              "$base" || echo 0)
      fi
      [[ "$sz" =~ ^[0-9]+$ && $sz -gt 0 ]] && inc_bytes "$sz" || sleep 1
    done
  }

  for ((i=1;i<=THREADS;i++)); do worker & done

  while :; do
    local used=$(cat "$STATE_FILE")
    log "[`date '+%T'`] 进度: $(bytes_to_human "$used") / $(bytes_to_human "$target")"
    ((used>=target)) && break
    sleep 5
  done

  log "[`date '+%F %T'`] 本轮完成"
}

main_loop(){
  ensure_conf_noninteractive
  load_conf
  while :; do
    consume_window
    log "[`date '+%F %T'`] 休息 ${INTERVAL_MINUTES} 分钟..."
    sleep $((INTERVAL_MINUTES*60))
  done
}

# ---------- systemd ----------
install_systemd(){
  # 服务用非交互入口 service-run，避免 systemd 下被卡住
  cat > "$SERVICE" <<EOF
[Unit]
Description=GoTraffic Bandwidth Consumer (local dir)
After=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH service-run
WorkingDirectory=$SCRIPT_DIR
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

  systemctl daemon-reload
  systemctl enable --now gotraffic.timer
  echo "[OK] systemd 已安装：gotraffic.service / gotraffic.timer"
}

remove_systemd(){
  systemctl stop gotraffic.timer gotraffic.service 2>/dev/null || true
  systemctl disable gotraffic.timer 2>/dev/null || true
  rm -f "$SERVICE" "$TIMER"
  systemctl daemon-reload
  echo "[OK] 已移除 systemd 单元"
}

# ---------- 入口 ----------
case "${1:-}" in
  # 前台调试
  run-foreground)
    echo "🚀 GoTraffic ${VERSION}（前台调试）..."
    main_loop
    ;;

  # 新：run 自动后台（systemd）
  run)
    # 若无配置，先交互配置一次
    if [[ ! -f "$CONF_FILE" && -t 0 ]]; then
      cmd_config
    fi
    # 装/更新 systemd 并立即启动服务
    install_systemd
    systemctl start gotraffic.service
    systemctl --no-pager status gotraffic.service | sed -n '1,12p'
    echo
    echo "✅ 已在后台以 systemd 运行"
    echo "▶ 查看日志：bash $SCRIPT_PATH log"
    echo "▶ 查看状态：bash $SCRIPT_PATH status"
    echo "▶ 修改参数：bash $SCRIPT_PATH set limit=10 interval=10 threads=8 area=A"
    ;;

  # systemd 入口（非交互）
  service-run)
    echo "🚀 GoTraffic ${VERSION}（systemd）启动..."
    main_loop
    ;;

  log)        tail -f "$LOG_FILE" ;;
  version)    echo "$VERSION" ;;
  config)     cmd_config ;;
  set)        shift || true; cmd_set "$@" ;;
  show)       cmd_show ;;
  install-systemd) install_systemd ;;
  remove-systemd)  remove_systemd ;;
  start)      systemctl start gotraffic.timer gotraffic.service || true; echo "gotraffic started" ;;
  stop)       systemctl stop gotraffic.timer gotraffic.service  || true; echo "gotraffic stopped" ;;
  status)     systemctl --no-pager status gotraffic.timer gotraffic.service ;;
  uninstall)
    remove_systemd
    rm -f "$SCRIPT_DIR/gotraffic."{log,state,lock,conf} 2>/dev/null || true
    rm -f "$SCRIPT_PATH" 2>/dev/null || true
    echo "已卸载 GoTraffic ${VERSION}"
    ;;
  *)
    echo "用法: bash $(basename "$0") {run|run-foreground|start|stop|status|log|version|uninstall|config|set|show|install-systemd|remove-systemd}"
    ;;
esac
