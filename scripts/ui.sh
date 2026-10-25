#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - 本地面板 UI
# Dashboard: sing-box/ui/dashboard
# Zashboard: mihomo/ui/zashboard
# ============================================================

nc_ui_valid() {
    case "$1" in
        dashboard|zashboard) return 0 ;;
        *) return 1 ;;
    esac
}

nc_ui_label() {
    case "$1" in
        dashboard) printf 'Dashboard' ;;
        zashboard) printf 'Zashboard' ;;
    esac
}

nc_ui_core_dir() {
    case "$1" in
        dashboard) printf '%s' "$NC_SB" ;;
        zashboard) printf '%s' "$NC_MH" ;;
    esac
}

nc_ui_path() {
    printf '%s/ui/%s' "$(nc_ui_core_dir "$1")" "$1"
}

nc_ui_url() {
    case "$1" in
        dashboard) printf '%s' 'https://codeload.github.com/SagerNet/sing-box-dashboard/zip/refs/heads/gh-pages' ;;
        zashboard) printf '%s' 'https://codeload.github.com/Zephyruso/zashboard/zip/refs/heads/gh-pages' ;;
    esac
}

nc_ui_status_json() {
    local _dash _dash_size _zash _zash_size
    _dash=false; _dash_size=0
    _zash=false; _zash_size=0
    if [ -f "$NC_SB/ui/dashboard/index.html" ]; then
        _dash=true
        _dash_size=$(nc_file_size "$NC_SB/ui/dashboard/index.html")
    fi
    if [ -f "$NC_MH/ui/zashboard/index.html" ]; then
        _zash=true
        _zash_size=$(nc_file_size "$NC_MH/ui/zashboard/index.html")
    fi
    printf '{"dashboard":{"installed":%s,"path":"%s","size":%s},"zashboard":{"installed":%s,"path":"%s","size":%s}}' \
        "$_dash" "$NC_SB/ui/dashboard" "$_dash_size" \
        "$_zash" "$NC_MH/ui/zashboard" "$_zash_size"
}

nc_ui_update() {
    local _dest _dir _index _label _parent _size _src _type _url _zip
    _type=$1
    nc_ui_valid "$_type" || { nc_err "用法: ui update <dashboard|zashboard>"; return 2; }
    _label=$(nc_ui_label "$_type")
    _url=$(nc_ui_url "$_type")
    _dest=$(nc_ui_path "$_type")
    _parent=$(dirname "$_dest")
    _zip="$NC_TMP/ui-$_type.$$.zip"
    _dir="$NC_TMP/ui-$_type.$$"

    rm -f "$_zip" 2>/dev/null
    rm -rf "$_dir" 2>/dev/null
    mkdir -p "$_dir" 2>/dev/null

    nc_info "下载 $_label 本地 UI..." 2>/dev/null || true
    nc_download "$_url" "$_zip" || { rm -f "$_zip"; rm -rf "$_dir"; nc_err "$_label 下载失败"; return 1; }
    _size=$(nc_file_size "$_zip")
    if [ "$_size" -lt 100000 ]; then
        nc_err "$_label 压缩包异常 (大小: $_size)"
        rm -f "$_zip"; rm -rf "$_dir"
        return 1
    fi
    nc_unzip "$_zip" "$_dir" || {
        nc_err "$_label 解压失败"
        rm -f "$_zip"; rm -rf "$_dir"
        return 1
    }
    rm -f "$_zip" 2>/dev/null

    _index=$(find "$_dir" -type f -name index.html 2>/dev/null | head -n 1)
    if [ -z "$_index" ]; then
        nc_err "$_label 包中未找到 index.html"
        rm -rf "$_dir"
        return 1
    fi
    _src=$(dirname "$_index")
    mkdir -p "$_parent" 2>/dev/null

    rm -rf "$_dest.old" 2>/dev/null
    [ -d "$_dest" ] && mv "$_dest" "$_dest.old" 2>/dev/null
    if ! mv "$_src" "$_dest" 2>/dev/null; then
        nc_err "$_label 部署失败"
        [ -d "$_dest.old" ] && mv "$_dest.old" "$_dest" 2>/dev/null
        rm -rf "$_dir"
        return 1
    fi
    chmod -R a+rX "$_dest" 2>/dev/null
    rm -rf "$_dir" "$_dest.old" 2>/dev/null

    nc_info "$_label 本地 UI 已部署: $_dest"
    printf '%s\n' "$_dest"
    return 0
}

nc_ui_delete() {
    local _dest _type
    _type=$1
    nc_ui_valid "$_type" || { nc_err "用法: ui delete <dashboard|zashboard>"; return 2; }
    _dest=$(nc_ui_path "$_type")
    if [ ! -d "$_dest" ]; then
        nc_info "$(nc_ui_label "$_type") 本地 UI 未安装"
        return 0
    fi
    rm -rf "$_dest" 2>/dev/null
    rmdir "$(dirname "$_dest")" 2>/dev/null
    nc_info "$(nc_ui_label "$_type") 本地 UI 已删除"
    return 0
}

nc_ui_clear_dir() {
    local _base _dir _entry _keep
    _dir=$1
    _keep=$2
    [ -d "$_dir" ] || return 0
    for _entry in "$_dir"/* "$_dir"/.[!.]* "$_dir"/..?*; do
        [ -e "$_entry" ] || continue
        _base=$(basename "$_entry")
        [ "$_base" = "$_keep" ] && continue
        rm -rf "$_entry" 2>/dev/null
    done
}

nc_ui_clear() {
    # 两个内核目录只保留配置文件，清掉 cache.db、ui/、rules/、.bak 等所有其余内容
    nc_ui_clear_dir "$NC_SB" "$(basename "$NC_SB_CONFIG")"
    nc_ui_clear_dir "$NC_MH" "$(basename "$NC_MH_CONFIG")"
    rm -rf "$NC_DATA/ui" 2>/dev/null
    rm -f "$NC_TMP"/ui-* 2>/dev/null
    nc_info "已清空内核目录缓存：sing-box 仅保留 config.json，mihomo 仅保留 config.yaml"
    return 0
}
