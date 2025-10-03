#!/usr/bin/env bash
# GoTraffic 一体化安装/配置脚本
# 作者: DaFuHao
# 版本: v1.0.1 BETA
# 日期: 2025-10-03

set -Eeuo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$BASE_DIR/gotraffic.log"
STATE_FILE="$BASE_DIR/gotraffic.state"
URLS_DL=/etc/gotraffic/urls.dl.txt
URLS_UL=/etc/gotraffic/urls.ul.txt
CORE=/usr/local/bin/gotraffic-core.sh
SVC=gotraffic.service
TIMER=gotraffic.timer

banner(){
  echo "========================================"
  echo "   GoTraffic 流量消耗工具"
  echo "   作者: DaFuHao"
  echo "   版本: v1.0.1 BETA"
  echo "   日期: 2025年10月3日"
  echo "========================================"
}

ask_config(){
  read -rp "每个窗口要消耗多少流量 (GiB) [10]: " LIMIT_GB; LIMIT_GB=${LIMIT_GB:-10}
  read -rp "窗口间隔时长 (分钟) [30]: " INTERVAL_MINUTES; INTERVAL_MINUTES=${INTERVAL_MINUTES:-30}
  read -rp "并发线程数 (1-32) [2]: " THREADS; THREADS=${THREADS:-2}
  if (( THREADS < 1 || THREADS > 32 )); then
    echo "⚠️ 线程数必须在 1-32 之间，已重置为 2"
    THREADS=2
  fi
}

write_core(){
cat >"$CORE" <<EOF_CORE
#!/usr/bin/env bash
set -Eeuo pipefail
: "\${LIMIT_GB:=$LIMIT_GB}"
: "\${INTERVAL_MINUTES:=$INTERVAL_MINUTES}"
: "\${THREADS:=$THREADS}"
: "\${MODE:=download}"
: "\${URLS_DL:=$URLS_DL}"
: "\${URLS_UL:=$URLS_UL}"
: "\${STATE_FILE:=$STATE_FILE}"
: "\${LOG_FILE:=$LOG_FILE}"

log(){ echo "[\$(date '+%F %T')] \$*" | tee -a "\$LOG_FILE"; }
bytes_gib(){ awk -v b="\$1" 'BEGIN{printf "%.2f GiB", b/1024/1024/1024}'; }

get_used(){ [ -f "\$STATE_FILE" ] && cat "\$STATE_FILE" || echo 0; }
write_used(){ echo "\$1" > "\$STATE_FILE"; }

pick_url(){ grep -v '^#' "\$1" | shuf -n1; }

curl_dl(){ curl -L --silent --output /dev/null --write-out '%{size_download}\n' "\$1"; }
curl_ul(){ head -c 25000000 /dev/zero | curl -X POST --data-binary @- -s -o /dev/null --write-out '%{size_upload}\n' "\$1"; }

main(){
  local limit=\$((LIMIT_GB*1024*1024*1024))
  local used=\$(get_used)
  local left=\$((limit-used))
  (( left <= 0 )) && { log "额度已满"; exit 0; }

  local chunk=25000000   # 每次固定 25MB

  for ((i=1;i<=THREADS;i++)); do
    {
      if [ "\$MODE" = "download" ]; then
        url=\$(pick_url "\$URLS_DL"); got=\$(curl_dl "\$url")
      elif [ "\$MODE" = "upload" ]; then
        url=\$(pick_url "\$URLS_UL"); got=\$(curl_ul "\$url")
      else
        url=\$(pick_url "\$URLS_DL"); got1=\$(curl_dl "\$url")
        url=\$(pick_url "\$URLS_UL"); got2=\$(curl_ul "\$url")
        got=\$((got1+got2))
      fi
      echo "\$got" >> "\$LOG_FILE.tmp"
    } &
  done
  wait

  local got_total=0
  if [ -f "\$LOG_FILE.tmp" ]; then
    while read -r line; do got_total=\$((got_total+line)); done < "\$LOG_FILE.tmp"
    rm -f "\$LOG_FILE.tmp"
  fi

  used=\$((used+got_total))
  write_used "\$used"
  log "本轮消耗 \$(bytes_gib "\$got_total") | 累计 \$(bytes_gib "\$used")/\$(bytes_gib "\$limit")"
}
main "\$@"
EOF_CORE
chmod +x "$CORE"
}

write_systemd(){
cat >/etc/systemd/system/$SVC <<EOF
[Unit]
Description=GoTraffic core
[Service]
Type=oneshot
Environment=LIMIT_GB=$LIMIT_GB
Environment=INTERVAL_MINUTES=$INTERVAL_MINUTES
Environment=THREADS=$THREADS
Environment=MODE=download
ExecStart=$CORE
EOF

cat >/etc/systemd/system/$TIMER <<EOF
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
systemctl enable --now $TIMER
}

write_gotr(){
cat >/usr/local/bin/gotr <<EOF_GOTR
#!/usr/bin/env bash
set -e
svc=$SVC
timer=$TIMER
core=$CORE
logfile="$LOG_FILE"
case "\$1" in
  d) systemctl set-environment MODE=download; echo "切换到下行模式";;
  u) systemctl set-environment MODE=upload; echo "切换到上行模式";;
  ud) systemctl set-environment MODE=ud; echo "切换到上下行模式";;
  now) systemctl start \$svc;;
  status)
    echo "--- 流量状态 ---"
    \$core
    echo "--- 定时器状态 ---"
    systemctl list-timers | grep gotraffic || true
    ;;
  log) tail -f "\$logfile";;
  stop)
    systemctl disable --now \$timer
    echo "GoTraffic 定时器已停止"
    ;;
  resume)
    systemctl enable --now \$timer
    echo "GoTraffic 定时器已恢复"
    ;;
  config)
    echo "=== 修改 GoTraffic 配置 ==="
    old_limit=\$(systemctl cat \$svc | grep 'Environment=LIMIT_GB' | cut -d= -f2)
    old_interval=\$(systemctl cat \$svc | grep 'Environment=INTERVAL_MINUTES' | cut -d= -f2)
    old_threads=\$(systemctl cat \$svc | grep 'Environment=THREADS' | cut -d= -f2)
    read -rp "新额度 (GiB, 当前=\$old_limit): " new_limit
    read -rp "新间隔 (分钟, 当前=\$old_interval): " new_interval
    read -rp "新线程数 (1-32, 当前=\$old_threads): " new_threads
    new_limit=\${new_limit:-\$old_limit}
    new_interval=\${new_interval:-\$old_interval}
    new_threads=\${new_threads:-\$old_threads}
    if (( new_threads < 1 || new_threads > 32 )); then
      echo "⚠️ 线程数必须在 1-32 之间，保持原值 \$old_threads"
      new_threads=\$old_threads
    fi
    sed -i "s|Environment=LIMIT_GB=.*|Environment=LIMIT_GB=\$new_limit|" /etc/systemd/system/\$svc
    sed -i "s|Environment=INTERVAL_MINUTES=.*|Environment=INTERVAL_MINUTES=\$new_interval|" /etc/systemd/system/\$svc
    sed -i "s|Environment=THREADS=.*|Environment=THREADS=\$new_threads|" /etc/systemd/system/\$svc
    systemctl daemon-reload
    systemctl restart \$timer
    echo "配置已更新 ✅ (额度=\$new_limit GiB, 间隔=\$new_interval 分钟, 线程=\$new_threads)"
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
    echo "  gotr config   修改已设置的额度/间隔/线程数"
    echo "  gotr uninstall 卸载 GoTraffic"
    ;;
esac
EOF_GOTR
chmod +x /usr/local/bin/gotr
}

main(){
  banner
  ask_config
  write_core
  [ -e "$URLS_DL" ] || echo "https://speed.cloudflare.com/__down?bytes=25000000" > "$URLS_DL"
  [ -e "$URLS_UL" ] || echo "# 上传 URL 填这里 (建议配置一个可接受 POST 的服务)" > "$URLS_UL"
  write_systemd
  write_gotr
  echo "安装完成 ✅"
  echo "日志文件: $LOG_FILE"
  echo "快捷命令: gotr d|u|ud|now|status|log|stop|resume|config|uninstall"
}

main
