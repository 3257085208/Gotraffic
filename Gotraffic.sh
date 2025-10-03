#!/usr/bin/env bash
# ========================================
#   DLTraffic · Linux 下行带宽消耗工具
#   作者: ChatGPT（为 DaFuHao 定制）
#   版本: v1.0.0
#   日期: 2025-10-03
# ========================================

set -Eeuo pipefail

APP=dltraffic
VER="v1.0.0"
AUTHOR="ChatGPT"
DATE="2025-10-03"

# ------- 默认配置（首装会询问后写入 /etc/dltraffic/env） -------
: "${LIMIT_GB:=10}"            # 每窗口消耗 GiB
: "${INTERVAL_MINUTES:=30}"    # 窗口间隔（分钟）
: "${THREADS:=4}"              # 并发线程 1-32
: "${MODE:=download}"          # 仅下行
# ------- 路径 -------
PREFIX="/usr/local"
BIN_MAIN="${PREFIX}/bin/${APP}"
STATE_DIR="/run/${APP}"
ETC_DIR="/etc/${APP}"
ENV_FILE="${ETC_DIR}/env"
URLS_DL="${ETC_DIR}/urls.dl.txt"
LOG_FILE="/var/log/${APP}.log"
STATE_FILE="${STATE_DIR}/state.bytes"
LOCK_FILE="${STATE_DIR}/.lock"

SERVICE="/etc/systemd/system/${APP}.service"
TIMER="/etc/systemd/system/${APP}.timer"

# 快捷指令优先安装 'go'，如冲突退回 'got'
BIN_LINK_PRIMARY="/usr/local/bin/go"
BIN_LINK_FALLBACK="/usr/local/bin/got"

# ===== 工具函数 =====
say(){ echo -e "$*"; }
err(){ echo -e "\e[31m$*\e[0m" >&2; }
ok(){ echo -e "\e[32m$*\e[0m"; }
warn(){ echo -e "\e[33m$*\e[0m"; }

require_cmd(){
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少依赖：$1。请先安装，例如：apt -y install $1 或 yum -y install $1"
    exit 1
  }
}

bytes_to_human(){
  # 输入字节，输出友好单位
  local b=${1:-0}
  local scale=0
  local units=(B KiB MiB GiB TiB)
  while (( b >= 1024 && scale < ${#units[@]}-1 )); do
    b=$(( b/1024 ))
    ((scale++))
  done
  echo "$b ${units[$scale]}"
}

human_time(){
  # 秒转人类可读
  local s=${1:-0}
  local h=$((s/3600)) m=$(((s%3600)/60)) ss=$((s%60))
  printf "%02d:%02d:%02d" "$h" "$m" "$ss"
}

ensure_dirs(){
  sudo mkdir -p "$STATE_DIR" "$ETC_DIR"
  sudo touch "$LOG_FILE"
  sudo chown -R root:root "$STATE_DIR" "$ETC_DIR"
}

write_default_urls(){
  if [[ ! -s "$URLS_DL" ]]; then
    sudo tee "$URLS_DL" >/dev/null <<'EOF'
# 每行一个可直链下载地址（支持 http/https）。脚本会循环随机取用。
# 你可以替换为离你更近/更稳的测速源。
https://speed.hetzner.de/1GB.bin
https://speed.hetzner.de/10GB.bin
http://speedtest.tele2.net/1GB.zip
http://speedtest.tele2.net/10GB.zip
http://cachefly.cachefly.net/100mb.test
http://speedtest-sfo2.digitalocean.com/10gb.test
http://speedtest-sgp1.digitalocean.com/10gb.test
EOF
  fi
}

install_self(){
  ensure_dirs
  require_cmd curl

  # 写入主可执行文件
  sudo tee "$BIN_MAIN" >/dev/null <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail

APP=dltraffic
PREFIX="/usr/local"
STATE_DIR="/run/${APP}"
ETC_DIR="/etc/${APP}"
ENV_FILE="${ETC_DIR}/env"
URLS_DL="${ETC_DIR}/urls.dl.txt"
LOG_FILE="/var/log/${APP}.log"
STATE_FILE="${STATE_DIR}/state.bytes"
LOCK_FILE="${STATE_DIR}/.lock"

_service="dltraffic.service"
_timer="dltraffic.timer"

require_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "缺少依赖：$1"; exit 1; }; }
say(){ echo -e "$*"; }
err(){ echo -e "\e[31m$*\e[0m" >&2; }
ok(){ echo -e "\e[32m$*\e[0m"; }
warn(){ echo -e "\e[33m$*\e[0m"; }

load_env(){
  # shellcheck disable=SC1090
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
  : "${LIMIT_GB:=10}" "${INTERVAL_MINUTES:=30}" "${THREADS:=4}" "${MODE:=download}"
}

pick_url(){
  # 随机挑一条可用 URL
  shuf -n 1 "$URLS_DL"
}

inc_bytes(){
  local add=${1:-0}
  exec 200>"$LOCK_FILE"
  flock -w 10 200
  local have=0
  [[ -s "$STATE_FILE" ]] && have=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  printf '%s\n' $(( have + add )) > "$STATE_FILE"
  flock -u 200
}

bytes_to_human(){
  local b=${1:-0} scale=0; local units=(B KiB MiB GiB TiB)
  while (( b >= 1024 && scale < ${#units[@]}-1 )); do b=$(( b/1024 )); ((scale++)); done
  echo "$b ${units[$scale]}"
}

_run_once_window(){
  load_env
  mkdir -p "$STATE_DIR"
  : > "$STATE_FILE"

  local target_bytes=$(( LIMIT_GB * 1024 * 1024 * 1024 ))
  local start_ts=$(date +%s)

  say "[`date '+%F %T'`] 开始本窗口：目标 $(bytes_to_human "$target_bytes")，线程 $THREADS" | tee -a "$LOG_FILE"

  worker(){
    while :; do
      # 是否已达标
      local used=0
      [[ -s "$STATE_FILE" ]] && used=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
      (( used >= target_bytes )) && break

      local url
      url=$(pick_url)
      # 下载到 /dev/null，取 size_download 统计
      local sz
      sz=$(curl -L --max-time 3600 --connect-timeout 10 --retry 2 \
                 --retry-delay 2 --fail --silent --show-error \
                 --output /dev/null --write-out '%{size_download}' "$url" 2>>"$LOG_FILE" || echo 0)
      # 更新统计
      if [[ "$sz" =~ ^[0-9]+$ ]] && (( sz > 0 )); then
        inc_bytes "$sz"
      else
        echo "[`date '+%F %T'`] 线程$$ 下载失败或为0，源：$url" >>"$LOG_FILE"
        sleep 1
      fi
    done
  }

  # 启动并发
  local pids=()
  for ((i=1;i<=THREADS;i++)); do
    worker &
    pids+=($!)
    sleep 0.1
  done

  # 进度打印器
  progress(){
    while :; do
      local used=0
      [[ -s "$STATE_FILE" ]] && used=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
      echo "[`date '+%F %T'`] 进度：$(bytes_to_human "$used") / $(bytes_to_human "$target_bytes")" >>"$LOG_FILE"
      (( used >= target_bytes )) && break
      sleep 5
    done
  }
  progress &

  # 等并发结束
  for pid in "${pids[@]}"; do wait "$pid" || true; done

  local end_ts=$(date +%s)
  local used=0
  [[ -s "$STATE_FILE" ]] && used=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  echo "[`date '+%F %T'`] 本窗口完成：实际 $(bytes_to_human "$used")，耗时 $((end_ts-start_ts))s" | tee -a "$LOG_FILE"
}

_do_status(){
  load_env
  local next="未知"
  if systemctl list-timers --all | grep -q "$_timer"; then
    next=$(systemctl list-timers --all | awk '/'$_timer'/{print $2" "$3" "$4}')
  fi
  local used=0
  [[ -s "$STATE_FILE" ]] && used=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  echo "—— ${APP} 状态 ——"
  systemctl is-enabled "${_timer}" >/dev/null 2>&1 && echo "定时器: 已启用" || echo "定时器: 未启用"
  systemctl is-active "${_timer}" >/dev/null 2>&1 && echo "定时器活动: 运行中" || echo "定时器活动: 暂停"
  echo "下次运行：${next}"
  echo "配置：LIMIT_GB=${LIMIT_GB} GiB, INTERVAL_MINUTES=${INTERVAL_MINUTES} min, THREADS=${THREADS}"
  echo "本窗口已用：$(bytes_to_human "$used")"
  echo "日志：$LOG_FILE"
}

_do_config(){
  load_env
  read -rp "每窗口消耗多少(GiB) [${LIMIT_GB}]: " _g || true
  read -rp "窗口间隔(分钟) [${INTERVAL_MINUTES}]: " _m || true
  read -rp "并发线程(1-32) [${THREADS}]: " _t || true
  LIMIT_GB=${_g:-$LIMIT_GB}
  INTERVAL_MINUTES=${_m:-$INTERVAL_MINUTES}
  THREADS=${_t:-$THREADS}
  [[ "$THREADS" -lt 1 ]] && THREADS=1
  [[ "$THREADS" -gt 32 ]] && THREADS=32

  sudo mkdir -p "$ETC_DIR"
  sudo tee "$ENV_FILE" >/dev/null <<EOF
LIMIT_GB=${LIMIT_GB}
INTERVAL_MINUTES=${INTERVAL_MINUTES}
THREADS=${THREADS}
MODE=download
EOF
  echo "已写入配置：$ENV_FILE"

  # 重写 timer 以生效新的间隔
  sudo tee "/etc/systemd/system/${_timer}" >/dev/null <<EOF
[Unit]
Description=DLTraffic timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL_MINUTES}min
Unit=${_service}

[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl restart "${_timer}"
  ok "配置已更新并重载。"
}

case "${1:-}" in
  run-once) _run_once_window ;;
  now)      sudo systemctl start "${_service}"; ok "已触发立刻运行（本窗口）。" ;;
  pause)    sudo systemctl stop "${_timer}"; ok "已暂停（停止定时器）。" ;;
  resume)   sudo systemctl start "${_timer}"; ok "已恢复（启动定时器）。" ;;
  status)   _do_status ;;
  log)      tail -n 200 -f "$LOG_FILE" ;;
  config)   _do_config ;;
  urls)     ${EDITOR:-nano} "$URLS_DL" ;;
  uninstall)
    sudo systemctl stop "${_timer}" "${_service}" || true
    sudo systemctl disable "${_timer}" || true
    sudo rm -f "/etc/systemd/system/${_timer}" "/etc/systemd/system/${_service}"
    sudo systemctl daemon-reload
    sudo rm -f "$ENV_FILE" "$URLS_DL" "$STATE_FILE" "$LOCK_FILE"
    sudo rmdir "$ETC_DIR" 2>/dev/null || true
    sudo rm -f "$0" # 删除主程序（仅当从 /usr/local/bin/dltraffic 调用）
    ok "已卸载（服务/定时器/配置/主程序）。如有快捷指令请手动移除。"
    ;;
  *)
    cat <<USAGE
用法：
  ${APP} now        立刻跑一轮
  ${APP} pause      暂停（停止定时器）
  ${APP} resume     恢复（启动定时器）
  ${APP} status     查看状态
  ${APP} log        查看日志（尾随）
  ${APP} config     重新设置 LIMIT_GB / INTERVAL / THREADS
  ${APP} urls       编辑下载源列表
  ${APP} uninstall  卸载
USAGE
    ;;
esac
SH
  sudo chmod +x "$BIN_MAIN"

  # 创建 service
  sudo tee "$SERVICE" >/dev/null <<EOF
[Unit]
Description=DLTraffic one-shot downloader (consume downlink)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_MAIN run-once
Nice=10
LimitNOFILE=1048576
EOF

  # 创建 timer（基于当前 INTERVAL_MINUTES）
  sudo tee "$TIMER" >/dev/null <<EOF
[Unit]
Description=DLTraffic timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL_MINUTES}min
Unit=$(basename "$SERVICE")

[Install]
WantedBy=timers.target
EOF

  # 快捷指令：优先 go，如冲突则 got
  local_link="$BIN_LINK_PRIMARY"
  if command -v go >/dev/null 2>&1 && [[ "$(command -v go)" != "$BIN_LINK_PRIMARY" ]]; then
    warn "检测到系统已存在 \`go\`（可能是 Golang 工具链），将使用备用快捷指令：got"
    local_link="$BIN_LINK_FALLBACK"
  fi
  sudo tee "$local_link" >/dev/null <<WRAP
#!/usr/bin/env bash
exec "$BIN_MAIN" "\$@"
WRAP
  sudo chmod +x "$local_link"

  # 首次写入配置（如无）
  if [[ ! -f "$ENV_FILE" ]]; then
    configure_interactive
  fi

  # 启动
  sudo systemctl daemon-reload
  sudo systemctl enable "$(basename "$TIMER")" >/dev/null
  sudo systemctl start "$(basename "$TIMER")"
  ok "安装完成 ✅"
  echo "日志文件: $LOG_FILE"
  echo "下载源清单: $URLS_DL"
  echo "快捷指令: $(basename "$local_link") now|pause|resume|status|log|config|urls|uninstall"
}

configure_interactive(){
  say "========================================"
  say "   DLTraffic · 下行带宽消耗工具 $VER"
  say "   作者: $AUTHOR    日期: $DATE"
  say "========================================"
  read -rp "每窗口要消耗多少流量 (GiB) [${LIMIT_GB}]: " _g || true
  read -rp "窗口间隔时长 (分钟) [${INTERVAL_MINUTES}]: " _m || true
  read -rp "并发线程数 (1-32) [${THREADS}]: " _t || true

  LIMIT_GB=${_g:-$LIMIT_GB}
  INTERVAL_MINUTES=${_m:-$INTERVAL_MINUTES}
  THREADS=${_t:-$THREADS}
  [[ "$THREADS" -lt 1 ]] && THREADS=1
  [[ "$THREADS" -gt 32 ]] && THREADS=32

  sudo tee "$ENV_FILE" >/dev/null <<EOF
LIMIT_GB=${LIMIT_GB}
INTERVAL_MINUTES=${INTERVAL_MINUTES}
THREADS=${THREADS}
MODE=download
EOF
  write_default_urls
}

# ===== 主流程 =====
main(){
  # 交互安装 + 写入主程序 + systemd + 快捷指令
  install_self
  ok "[`date '+%F %T'`] 安装完成 ✅"
  echo "日志: $LOG_FILE"
  echo "快捷命令: go / got  （取决于环境是否已有 Golang 的 go）"
  echo "例：go status | go now | go pause | go resume | go config"
}

# 运行
main
