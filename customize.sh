#!/sbin/sh
# ============================================================
# Android Nakedcore - 安装脚本
# 兼容 Magisk / KernelSU / APatch；数据目录保持不变以便升级
# ============================================================

# 某些恢复环境可能没有 ui_print
if ! command -v ui_print >/dev/null 2>&1; then
    ui_print() { echo "$1"; }
fi

# 管理器会传入 MODPATH；直接执行时回退到脚本目录，便于调试
if [ -z "${MODPATH:-}" ]; then
    MODPATH=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
fi
if [ ! -f "$MODPATH/scripts/common.sh" ]; then
    ui_print "! 模块文件不完整: $MODPATH/scripts/common.sh"
    exit 1
fi

NC_MODDIR="$MODPATH"
export NC_MODDIR
# shellcheck source=scripts/common.sh
. "$MODPATH/scripts/common.sh"
# shellcheck source=scripts/substore.sh
. "$MODPATH/scripts/substore.sh"

ui_print "=========================================="
ui_print "   Android Nakedcore v3.0"
ui_print "   sing-box / mihomo / Sub-Store"
ui_print "=========================================="

# 兼容 v2：停止旧的队列守护，清理队列文件
pkill -f "nakedcore_daemon_loop" 2>/dev/null
rm -f "$NC_RUN/cmd.queue" 2>/dev/null

ui_print "- 初始化数据目录: $NC_DATA"
nc_init
nc_sub_ensure_env >/dev/null 2>&1

# 读取旧设置并补全新字段（保留 ACTIVE_CORE / AUTO_START 等旧值）
nc_load_settings
nc_save_settings

# 旧 env 缺少合并模式字段时补齐，保证 Sub-Store 以单端口工作
if [ -f "$NC_SUB_ENV" ]; then
    _host=$(nc_conf_get "$NC_SUB_ENV" SUB_STORE_BACKEND_API_HOST)
    [ -n "$_host" ] || _host="127.0.0.1"
    if ! grep -q '^[[:space:]]*SUB_STORE_BACKEND_MERGE=' "$NC_SUB_ENV" 2>/dev/null; then
        nc_sub_env_set_raw SUB_STORE_BACKEND_MERGE "true" >/dev/null 2>&1
        ui_print "- 已为旧配置补全 SUB_STORE_BACKEND_MERGE=true"
    fi
    if ! grep -q '^[[:space:]]*SUB_STORE_FRONTEND_HOST=' "$NC_SUB_ENV" 2>/dev/null; then
        nc_sub_env_set_raw SUB_STORE_FRONTEND_HOST "$_host" >/dev/null 2>&1
    fi
    if ! grep -q '^[[:space:]]*SUB_STORE_FRONTEND_PORT=' "$NC_SUB_ENV" 2>/dev/null; then
        nc_sub_env_set_raw SUB_STORE_FRONTEND_PORT "3001" >/dev/null 2>&1
    fi
fi

# 运行时副本：安装后即使尚未重启、模块仍在 modules_update，终端/WebUI 也能立即调用
ui_print "- 更新运行时副本: $NC_DATA/runtime"
rm -rf "$NC_DATA/runtime" 2>/dev/null
mkdir -p "$NC_DATA/runtime" 2>/dev/null
cp -f "$MODPATH/nakedcore" "$NC_DATA/runtime/nakedcore" 2>/dev/null
cp -rf "$MODPATH/scripts" "$NC_DATA/runtime/scripts" 2>/dev/null
cp -f "$MODPATH/module.prop" "$NC_DATA/runtime/module.prop" 2>/dev/null
chmod 755 "$NC_DATA/runtime/nakedcore" 2>/dev/null
chmod 755 "$NC_DATA/runtime"/scripts/*.sh 2>/dev/null

# 终端快捷方式：指向持久化运行时副本，不依赖 /system 挂载
for _p in /data/adb/ksu/bin /data/adb/ap/bin /data/adb/magisk; do
    [ -d "$_p" ] || continue
    rm -f "$_p/nakedcore" 2>/dev/null
    cat >"$_p/nakedcore" <<'WRAPPER'
#!/system/bin/sh
exec /data/adb/nakedcore/runtime/nakedcore "$@"
WRAPPER
    chmod 755 "$_p/nakedcore" 2>/dev/null
done

# 权限：脚本可执行，配置仅 root 可读
chmod 755 "$MODPATH/nakedcore" 2>/dev/null
chmod 755 "$MODPATH"/*.sh 2>/dev/null
chmod 755 "$MODPATH"/scripts/*.sh 2>/dev/null
chmod 600 "$NC_SETTINGS" "$NC_SUB_ENV" 2>/dev/null
chmod 700 "$NC_DATA" 2>/dev/null

ui_print "- 数据目录: $NC_DATA（升级会保留旧配置）"
ui_print "- 终端命令: nakedcore help"
ui_print "- 首次使用：打开模块 WebUI，在 [核心] 页安装/更新运行环境"
ui_print "- 安装完成，重启后按设置自动启动"
exit 0
