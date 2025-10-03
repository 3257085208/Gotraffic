#!/usr/bin/env bash
# GoTraffic 一体化安装脚本
# 作者: DaFuHao
# 版本: v1.0.0 BETA
# 日期: 2025-10-03

set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"   # 脚本所在目录
LOG_FILE="$BASE_DIR/gotraffic.log"          # 日志在脚本同目录
STATE_FILE="$BASE_DIR/gotraffic.state"      # 状态文件同目录

echo "========================================"
echo "   GoTraffic 流量消耗工具"
echo "   作者: DaFuHao"
echo "   版本: v1.0.0 BETA"
echo "   日期: 2025年10月3日"
echo "========================================"

echo "=== GoTraffic 安装（分钟级额度）==="
read -rp "每个窗口要消耗多少流量（GiB）[10]: " LIMIT_GB; LIMIT_GB=${LIMIT_GB:-10}
read -rp "窗口间隔时长（分钟）[30]: " INTERVAL_MINUTES; INTERVAL_MINUTES=${INTERVAL_MINUTES:-30}

THREADS=2
MODE=download
URLS_DL=/etc/gotraffic/urls.dl.txt
URLS_UL=/etc/gotraffic/urls.ul.txt
CORE=/usr/local/bin/gotraffic-core.sh

mkdir -p /etc/gotraffic
touch "$STATE_FILE" "$LOG_FILE"

# ---------------- 核心脚本 ----------------
cat >"$CORE" <<EOF_CORE
#!/usr/bin/env bash
set -Eeuo pipefail

: "\${LIMIT_GB:=$LIMIT_GB}"
: "\${INTERVAL_MINUTES:=$INTERVAL_MINUTES}"
: "\${THREADS:=$THREADS}"
: "\${MODE:=$MODE}"
: "\${URLS_DL:=/etc/gotraffic/urls.dl.txt}"
: "\${URLS_UL:=/etc/gotraffic/urls.ul.txt}"
: "\${STATE_FILE:=$STATE_FILE}"
: "\${LOG_FILE:=$LOG_FILE}"
: "\${CHUNK_MIN_MB:=128}"
: "\${CHUNK_MAX_MB:=512}"

log(){ echo "[\$(date '+%F %T')] \$*" | tee -a "\$LOG_FILE"; }
bytes_gib(){ awk -v b="\$1" 'BEGIN{printf "%.2f GiB", b/1024/1024/1024}'; }

get_used(){ [ -f "\$STATE_FILE" ] && cat "\$STATE_FILE" || echo 0; }
write_used(){ echo "\$1" > "\$STATE_FILE"; }

pick_url(){ grep -v '^#' "\$1" | shuf -n1; }
rand_chunk(){ awk -v min="\$CHUNK_MIN_MB" -v max="\$CHUNK_MAX_MB" 'BEGIN{srand();print int((min+rand()*(max-min+1))*1024*1024)}'; }
prepare_url(){ local url="\$1" size="\$2"; echo "\${url//\{bytes\}/\$size}"; }

curl_dl(){ curl -L --silent --output /dev/null --write-out '%{size_download}\n' "\$1"; }
curl_ul(){ head -c "\$2" /dev/zero | curl -X POST --data-binary @- -s -o /dev/null --write-out '%{size_upload}\n' "\$1"; }

main(){
  local limit=\$((LIMIT_GB*1024*1024*1024))
  local used=\$(get_used)
  local left=\$((limit-used))
  (( left <= 0 )) && { log "额度已满"; exit 0; }

  local chunk=\$(rand_chunk)
  (( chunk > left )) && chunk=\$left

  if [ "\$MODE" = "download" ]; then
    url=\$(pick_url "\$URLS_DL"); url=\$(prepare_url "\$url" "\$chunk"); got=\$(curl_dl "\$url")
  elif [ "\$MODE" = "upload" ]; then
    url=\$(pick_url "\$URLS_UL"); got=\$(curl_ul "\$url" "\$chunk")
  else
    url=\$(pick_url "\$URLS_DL"); url=\$(prepare_url "\$url" "\$chunk"); got1=\$(curl_dl "\$url")
    url=\$(pick_url "\$URLS_UL"); got2=\$(curl_ul "\$url" "\$chunk")
    got=\$((got1+got2))
  fi

  got=\${got%%.*}
  used=\$((used+got))
  write_used "\$used"
  log "消耗 \$(bytes_gib "\$got") | 累计 \$(bytes_gib "\$used")/\$(bytes_gib "\$limit")"
}
main "\$@"
EOF_CORE

chmod +x "$CORE"

# ---------------- URL 文件 ----------------
[ -e "$URLS_DL" ] || echo "https://speed.cloudflare.com/__down?bytes={bytes}" > "$URLS_DL"
[ -e "$URLS_UL" ] || echo "# 上传 URL 填这里" > "$URLS_UL"

# ---------------- systemd ----------------
cat >/etc/systemd/system/gotraffic.service <<EOF
[Unit]
Description=GoTraffic core
[Service]
Type=oneshot
Environment=LIMIT_GB=$LIMIT_GB
Environment=INTERVAL_MINUTES=$INTERVAL_MINUTES
Environment=THREADS=$THREADS
Environment=MODE=$MODE
ExecStart=$CORE
EOF

cat >/etc/systemd/system/gotraffic.timer <<EOF
[Unit]
Description=Run GoTraffic
[Timer]
OnBootSec=1m
OnUnitActiveSec=${INTERVAL_MINUTES}m
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now gotraffic.timer

# ---------------- 快捷命令 ----------------
cat >/usr/local/bin/gotr <<EOF_GOTR
#!/usr/bin/env bash
set -e
svc=gotraffic.service
timer=gotraffic.timer
core=/usr/local/bin/gotraffic-core.sh
logfile="$LOG_FILE"
case "\$1" in
  d) systemctl set-environment MODE=download; echo "切换到下行模式";;
  u) systemctl set-environment MODE=upload; echo "切换到上行模式";;
  ud) systemctl set-environment MODE=ud; echo "切换到上下行模式";;
  now) systemctl start \$svc;;
  status)
    \$core
    echo "systemd 定时器状态："
    systemctl list-timers | grep gotraffic || true
    ;;
  log)
    tail -f "\$logfile"
    ;;
  stop)
    systemctl disable --now \$timer
    echo "GoTraffic 定时器已停止"
    ;;
  resume)
    systemctl enable --now \$timer
    echo "GoTraffic 定时器已恢复"
    ;;
  uninstall)
    systemctl disable --now \$timer || true
    systemctl disable --now \$svc || true
    rm -f /etc/systemd/system/gotraffic.{service,timer}
    rm -f /usr/local/bin/gotraffic-core.sh /usr/local/bin/gotr
    rm -f "$LOG_FILE" "$STATE_FILE"
    systemctl daemon-reload
    echo "GoTraffic 已卸载"
    ;;
  *)
    echo "=== GoTraffic 快捷命令用法 ==="
    echo "  gotr d        切换到下行模式"
    echo "  gotr u        切换到上行模式"
    echo "  gotr ud       切换到上下行模式"
    echo "  gotr now      立即执行一次"
    echo "  gotr status   查看当前流量状态 & 定时器情况"
    echo "  gotr log      实时查看日志 (tail -f)"
    echo "  gotr stop     停止后台定时器"
    echo "  gotr resume   恢复后台定时器"
    echo "  gotr uninstall 卸载 GoTraffic"
    ;;
esac
EOF_GOTR

chmod +x /usr/local/bin/gotr

echo "安装完成 ✅"
echo "日志文件: $LOG_FILE"
echo "快捷命令: gotr d|u|ud|now|status|log|stop|resume|uninstall"
