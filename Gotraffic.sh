#!/usr/bin/env bash
# GoTraffic - 下行带宽消耗工具
# 版本: v1.2.3
# 用法: bash Gotraffic.sh {run|run-foreground|start|stop|status|log|version|uninstall|config|set|show|install-systemd|remove-systemd|help}

set -Eeuo pipefail

VERSION="v1.2.3"
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
STATE_FILE="$SCRIPT_DIR/gotraffic.state"
LOCK_FILE="$SCRIPT_DIR/gotraffic.lock"
LOG_FILE="$SCRIPT_DIR/gotraffic.log"
CONF_FILE="$SCRIPT_DIR/gotraffic.conf"
SERVICE="/etc/systemd/system/gotraffic.service"
TIMER="/etc/systemd/system/gotraffic.timer"

# 默认参数（可通过 config/set 修改）
LIMIT_GB=5
INTERVAL_MINUTES=30
THREADS=2
AREA="A"     # A=国外(Cloudflare)，B=国内(QQ/学习强国)
CHUNK_MB=50  # 每次请求的分块大小(MB)
URLS=()

UA="gotraffic/${VERSION}"

log(){ echo -e "${1:-}" | tee -a "$LOG_FILE"; }
bytes_to_human(){ local b=${1:-0} s=0 u=(B KiB MiB GiB TiB); while ((b>=1024 && s<${#u[@]}-1)); do b=$((b/1024)); ((s++)); done; echo "$b ${u[$s]}"; }
inc_bytes(){ local add=$1; exec 200>"$LOCK_FILE"; flock -w 10 200; local have=0; [[ -s "$STATE_FILE" ]] && have=$(cat "$STATE_FILE"); echo $((have+add)) > "$STATE_FILE"; flock -u 200; }

pick_urls_by_area(){
  if [[ "${AREA:-A}" =~ ^[Aa]$ ]]; then
    URLS=("https://speed.cloudflare.com/__down")  # 通过 ?bytes= 控制大小
  else
    URLS=(
      "https://dldir1.qq.com/qqfile/qq/PCQQ9.7.17/QQ9.7.17.29225.exe"
      "https://wirelesscdn-download.xuexi.cn/publish/xuexi_android/latest/xuexi_android_10002068.apk"
    )
  fi
}

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
  if [[ -f "$CONF_FILE" ]]; then source "$CONF_FILE"; fi
  pick_urls_by_area
}

ensure_conf_noninteractive(){
  if [[ ! -f "$CONF_FILE" ]]; then
    echo "[错误] 未找到配置文件: $CONF_FILE"
    echo "      先执行: bash $(basename "$0") config   或   bash $(basename "$0") set limit=... interval=... threads=... area=A|B [chunk=...]"
    exit 1
  fi
}

# —— 配置相关 ——
cmd_config(){
  echo "== GoTraffic $VERSION 配置 =="
  read -rp "每轮消耗流量 (GiB): " LIMIT_GB
  read -rp "间隔时间 (分钟): " INTERVAL_MINUTES
  read -rp "线程数量 (1-32): " THREADS
  ((THREADS<1)) && THREADS=1; ((THREADS>32)) && THREADS=32
  echo "下载源: A) 国外(Cloudflare)  B) 国内(QQ/学习强国)"
  read -rp "请选择 (A/B): " AREA; [[ -z "${AREA:-}" ]] && AREA="A"
  read -rp "分块大小(MB，默认50): " CHIN || true
  [[ -n "${CHIN:-}" ]] && CHUNK_MB="$CHIN"
  pick_urls_by_area
  write_conf
  log "[已保存] $CONF_FILE"
  cmd_show
}

cmd_set(){
  load_conf
  local kv
  for kv in "$@"; do
    case "$kv" in
      limit=*|LIMIT_GB=*)            LIMIT_GB="${kv#*=}";;
      interval=*|INTERVAL_MINUTES=*) INTERVAL_MINUTES="${kv#*=}";;
      threads=*|THREADS=*)           THREADS="${kv#*=}";;
      area=*|AREA=*)                 AREA="${kv#*=}";;
      chunk=*|CHUNK_MB=*)            CHUNK_MB="${kv#*=}";;
      *) echo "忽略未知参数: $kv";;
    esac
  done
  ((THREADS<1)) && THREADS=1
  ((THREADS>32)) && THREADS=32
  [[ -z "${AREA:-}" ]] && AREA="A"
  [[ -z "${CHUNK_MB:-}" ]] && CHUNK_MB=50
  pick_urls_by_area
  write_conf
  log "[OK] 配置已更新"
  cmd_show
}

cmd_show(){
  load_conf
  echo "—— 当前配置 ——"
  echo "版本         : $VERSION"
  echo "流量 (GiB)   : $LIMIT_GB"
  echo "间隔 (分钟)  : $INTERVAL_MINUTES"
  echo "线程数       : $THREADS"
  echo "节点区域     : $AREA  (A=国外, B=国内)"
  echo "分块大小(MB) : $CHUNK_MB"
  echo "配置文件     : $CONF_FILE"
  echo "日志文件     : $LOG_FILE"
  echo "脚本目录     : $SCRIPT_DIR"
  echo "——————"
}

# —— 下载核心 ——
consume_window(){
  local target=$((LIMIT_GB*1024*1024*1024))
  local CHUNK_BYTES=$((CHUNK_MB*1024*1024))
  echo 0 > "$STATE_FILE"
  log "[`date '+%F %T'`] 本轮开始: ${LIMIT_GB}GiB  线程=$THREADS  区域=$AREA  分块=${CHUNK_MB}MB"

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

# —— systemd ——
install_systemd(){
  cat > "$SERVICE" <<EOF
[Unit]
Description=GoTraffic (local)
After=network-online.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH service-run
WorkingDirectory=$SCRIPT_DIR
Restart=always
EOF

  cat > "$TIMER" <<"EOF"
[Unit]
Description=GoTraffic auto start

[Timer]
OnBootSec=1min
Unit=gotraffic.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now gotraffic.timer
  echo "[OK] systemd 已安装"
}

remove_systemd(){
  systemctl stop gotraffic.timer gotraffic.service 2>/dev/null || true
  systemctl disable gotraffic.timer 2>/dev/null || true
  rm -f "$SERVICE" "$TIMER"
  systemctl daemon-reload
  echo "[OK] systemd 已移除"
}

# —— 帮助 & 用法（两处共用，保证一致）——
print_usage(){
  cat <<'USAGE'
状态命令说明:
  run                首次自动创建/更新 systemd，并在后台运行（退出SSH也继续）。
  run-foreground     前台调试运行（打印详细进度）。
  start              启动 systemd 定时器/服务（后台）。
  stop               停止 systemd 定时器/服务。
  status             查看 systemd 状态（是否在后台运行）。
  log                跟踪查看脚本日志（Ctrl+C 退出）。
  version            显示版本号。
  uninstall          卸载脚本：移除 systemd 单元并删除本目录内日志/状态/配置/脚本。

  config             交互式配置（流量GiB、间隔分钟、线程1-32、国内外、分块MB）。
  set k=v [...]      非交互更新配置（示例见下）。
  show               显示当前配置。
  install-systemd    手动安装 systemd 单元（指向当前目录脚本）。
  remove-systemd     手动移除 systemd 单元。
USAGE
}

cmd_help(){ print_usage; }

# —— 入口 ——
case "${1:-}" in
  run-foreground)
    echo "GoTraffic $VERSION（前台调试）"
    main_loop
    ;;
  run)
    if [[ ! -f "$CONF_FILE" && -t 0 ]]; then cmd_config; fi
    install_systemd
    systemctl start gotraffic.service
    systemctl --no-pager status gotraffic.service | sed -n '1,12p'
    echo "已在后台以 systemd 运行"
    ;;
  service-run)
    echo "GoTraffic $VERSION（systemd）"
    main_loop
    ;;
  log)        tail -f "$LOG_FILE" ;;
  version)    echo "$VERSION" ;;
  config)     cmd_config ;;
  set)        shift || true; cmd_set "$@" ;;
  show)       cmd_show ;;
  install-systemd) install_systemd ;;
  remove-systemd)  remove_systemd ;;
  start)      systemctl start gotraffic.timer gotraffic.service || true; echo "已启动" ;;
  stop)       systemctl stop  gotraffic.timer gotraffic.service || true; echo "已停止" ;;
  status)     systemctl --no-pager status gotraffic.timer gotraffic.service ;;
  uninstall)
    remove_systemd
    rm -f "$SCRIPT_DIR/gotraffic."{log,state,lock,conf} 2>/dev/null || true
    rm -f "$SCRIPT_PATH" 2>/dev/null || true
    echo "已卸载 $VERSION"
    ;;
  help|-h|--help)
    cmd_help
    ;;
  *)
    print_usage
    ;;
esac
