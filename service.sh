#!/system/bin/sh
# ============================================================
# Android Nakedcore - 开机启动
# 等待系统启动完成后按设置拉起内核 / Sub-Store
# ============================================================

MODDIR=${0%/*}
NC_MODDIR="$MODDIR"
export NC_MODDIR

# shellcheck source=scripts/common.sh
. "$MODDIR/scripts/common.sh"
# shellcheck source=scripts/substore.sh
. "$MODDIR/scripts/substore.sh"

mkdir -p "$NC_RUN" 2>/dev/null
# 启动日志轮转，避免无限增长
if [ -f "$NC_LOG_BOOT" ] && [ "$(nc_file_size "$NC_LOG_BOOT")" -gt 262144 ]; then
    mv -f "$NC_LOG_BOOT" "$NC_LOG_BOOT.1" 2>/dev/null
fi
# 把启动过程写入独立日志，方便排查
exec >>"$NC_LOG_BOOT" 2>&1
printf '\n===== Nakedcore boot %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S')"

nc_init

# 兼容 v2：停止旧的队列守护，避免两套机制同时运行
pkill -f "nakedcore_daemon_loop" 2>/dev/null
rm -f "$NC_RUN/cmd.queue" 2>/dev/null

# 模块被禁用时不启动
if [ -f "$MODDIR/disable" ]; then
    nc_info "模块已禁用，跳过开机启动"
    exit 0
fi

# 自愈：运行时副本/终端 wrapper 丢失时从模块目录恢复
if [ ! -f "$NC_DATA/runtime/nakedcore" ] && [ -f "$MODDIR/nakedcore" ]; then
    mkdir -p "$NC_DATA/runtime" 2>/dev/null
    cp -f "$MODDIR/nakedcore" "$NC_DATA/runtime/nakedcore" 2>/dev/null
    cp -rf "$MODDIR/scripts" "$NC_DATA/runtime/scripts" 2>/dev/null
    cp -f "$MODDIR/module.prop" "$NC_DATA/runtime/module.prop" 2>/dev/null
    chmod 755 "$NC_DATA/runtime/nakedcore" "$NC_DATA/runtime"/scripts/*.sh 2>/dev/null
    nc_info "已恢复运行时副本"
fi
for _p in /data/adb/ksu/bin /data/adb/ap/bin /data/adb/magisk; do
    [ -d "$_p" ] || continue
    [ -f "$_p/nakedcore" ] && continue
    cat >"$_p/nakedcore" <<'WRAPPER'
#!/system/bin/sh
exec /data/adb/nakedcore/runtime/nakedcore "$@"
WRAPPER
    chmod 755 "$_p/nakedcore" 2>/dev/null
done

# 等待系统完成启动
_i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_i" -lt 120 ]; do
    sleep 3
    _i=$((_i + 1))
done
# 给存储、网络和 SELinux 上下文一点时间
sleep 5

nc_info "开机启动: 激活内核=$NC_ACTIVE_CORE 内核自启=$NC_AUTO_START Sub-Store 自启=$NC_SUB_AUTO_START"

_wifi_allow=0
# 常驻网络守护必须从开机服务启动，不能只依赖 WebUI 进程；
# 否则退出 KernelSU 管理器后守护会被一起回收。
nc_info "网络守护启动: Wi-Fi=$NC_WIFI_GUARD 热点=$NC_HOTSPOT_ENABLED"
"$NC_SELF" wifi start >/dev/null 2>&1
if [ "$NC_WIFI_GUARD" = "true" ]; then
    if ! "$NC_SELF" wifi gate; then
        _wifi_allow=1
        nc_info "Wi-Fi 自动逻辑要求跳过内核开机自启"
    fi
fi

if [ "$NC_AUTO_START" = "true" ] && [ "$_wifi_allow" = "0" ]; then
    nc_info "启动内核: $NC_ACTIVE_CORE"
    NC_WIFI_SERVICE=1 "$NC_SELF" core start "$NC_ACTIVE_CORE"
    if [ $? -eq 0 ]; then
        nc_info "内核启动完成"
    else
        nc_err "内核启动失败，请打开 WebUI 查看配置/日志"
    fi
elif [ "$NC_AUTO_START" != "true" ]; then
    nc_info "内核开机自启已关闭"
fi

if [ "$NC_SUB_AUTO_START" = "true" ]; then
    _reason=$(nc_sub_health_reason)
    if [ "$_reason" = "正常" ]; then
        nc_info "启动 Sub-Store"
        "$NC_SELF" sub start
        if [ $? -eq 0 ]; then
            nc_info "Sub-Store 启动完成"
        else
            nc_err "Sub-Store 启动失败，请打开 WebUI 查看日志"
        fi
    else
        nc_err "Sub-Store 自启跳过: $_reason"
    fi
else
    nc_info "Sub-Store 开机自启已关闭"
fi

nc_info "开机启动流程结束"
exit 0
