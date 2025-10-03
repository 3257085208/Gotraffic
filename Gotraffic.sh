cat >/usr/local/bin/Gotr <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# 使用: 
#   Gotr <GiB> [<小时>]   # 设置每间隔要消耗的流量和间隔时长(小时)
#   Gotr now              # 立即运行一次
#   Gotr status           # 查看当前窗口用量/剩余
#   Gotr threads <N>      # 设置并发线程数
#   Gotr upload|download  # 切换模式(出站上传/入站下载)

need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || exec sudo -n "$0" "$@"; }
need_root

dropin='/etc/systemd/system/gotraffic.service.d'
core='/usr/local/bin/gotraffic-core.sh'
mkdir -p "$dropin"

usage(){ cat <<USAGE
用法:
  Gotr <GiB> [<小时>]
  Gotr now | status
  Gotr threads <N>
  Gotr upload | download
说明: 仅覆盖 LIMIT_INTERVAL_GB 与/或 INTERVAL_HOURS(小时)。其他保持不变。
USAGE
}

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

parse_gib(){ local x="$1"; x="${x%GiB}"; x="${x%G}"; x="${x%g}"; printf '%s\n' "${x%.*}"; }
parse_hours(){ local h="$1"; h="${h%h}"; h="${h%H}"; printf '%s\n' "${h%.*}"; }

case "${1:-}" in
  now) systemctl start gotraffic.service; exit 0;;
  status) "$core" status; exit 0;;
  threads)
    n="${2:-}"; [[ "$n" =~ ^[0-9]+$ ]] || { usage; exit 1; }
    set_env THREADS "$n"
    systemctl daemon-reload; systemctl restart gotraffic.timer
    echo "已设置 THREADS=$n 并重启定时器。"; exit 0;;
  upload|download)
    mode="$1"; set_env MODE "$mode"
    systemctl daemon-reload; systemctl restart gotraffic.timer
    echo "已切换 MODE=$mode"; exit 0;;
  ""|-h|--help) usage; exit 0;;
  *)
    if [[ "$1" =~ ^[0-9] ]]; then
      gib="$(parse_gib "$1")"
      if [ -n "${2:-}" ]; then
        hrs="$(parse_hours "$2")"
        set_env LIMIT_INTERVAL_GB "$gib"
        set_env INTERVAL_HOURS "$hrs"
        systemctl daemon-reload; systemctl restart gotraffic.timer
        echo "OK：每间隔消耗 ${gib} GiB，间隔时长 ${hrs} 小时。"
      else
        set_env LIMIT_INTERVAL_GB "$gib"
        systemctl daemon-reload; systemctl restart gotraffic.timer
        echo "OK：每间隔消耗 ${gib} GiB（时长保持不变）。"
      fi
      exit 0
    else
      usage; exit 1
    fi
  ;;
esac
EOF
chmod +x /usr/local/bin/Gotr
ln -sf /usr/local/bin/Gotr /usr/local/bin/gotr 2>/dev/null || true
echo "已安装：现在可以用 'Gotr' 或 'gotr' 了。"
