#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - 配置文件管理
# 分块上传用于 WebUI：避免超长命令行与引号问题
# ============================================================

nc_cfg_valid() {
    case "$1" in
        singbox|mihomo|substore) return 0 ;;
        *) return 1 ;;
    esac
}

nc_cfg_path() {
    case "$1" in
        singbox)  printf '%s' "$NC_SB_CONFIG" ;;
        mihomo)   printf '%s' "$NC_MH_CONFIG" ;;
        substore) printf '%s' "$NC_SUB_ENV" ;;
    esac
}

nc_cfg_label() {
    case "$1" in
        singbox)  printf 'sing-box (config.json)' ;;
        mihomo)   printf 'mihomo (config.yaml)' ;;
        substore) printf 'Sub-Store (sub_store.env)' ;;
    esac
}

nc_cfg_tmp()   { printf '%s/upload.%s' "$NC_TMP" "$1"; }
nc_cfg_idx()   { printf '%s/upload.%s.idx' "$NC_TMP" "$1"; }

# 校验任意文件；返回 0=通过 1=失败 2=缺少内核无法校验
nc_cfg_validate_file() {
    local _file _msg _out _rc _target
    _target=$1
    _file=$2
    [ -f "$_file" ] || { nc_err "文件不存在"; return 1; }

    case "$_target" in
        singbox)
            [ -x "$NC_SB_BIN" ] || { nc_warn "未安装 sing-box，跳过配置校验"; return 2; }
            _out=$("$NC_SB_BIN" check -D "$NC_SB" -c "$_file" 2>&1)
            ;;
        mihomo)
            [ -x "$NC_MH_BIN" ] || { nc_warn "未安装 mihomo，跳过配置校验"; return 2; }
            _out=$("$NC_MH_BIN" -t -d "$NC_MH" -f "$_file" 2>&1)
            ;;
        substore)
            _out=$(sh -n "$_file" 2>&1)
            ;;
        *)
            nc_err "未知配置目标"
            return 1
            ;;
    esac
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        return 0
    fi
    _msg=$(printf '%s' "$_out" | head -n 4 | tr '\n' ' ' | tr -d '\r')
    nc_err "校验失败: ${_msg:-未知错误}"
    return 1
}

nc_cfg_get() {
    local _path _target
    _target=$1
    nc_cfg_valid "$_target" || { nc_err "未知配置目标: $_target"; return 2; }
    _path=$(nc_cfg_path "$_target")
    [ -f "$_path" ] && cat "$_path" 2>/dev/null
    return 0
}

nc_cfg_reset() {
    local _target
    _target=$1
    nc_cfg_valid "$_target" || { nc_err "未知配置目标: $_target"; return 2; }
    rm -f "$(nc_cfg_tmp "$_target")" "$(nc_cfg_idx "$_target")" 2>/dev/null
    return 0
}

# 分块写入临时文件；index 从 0 开始
nc_cfg_put() {
    local _b64 _chunk _expected _idxf _index _next _target _tmp
    _target=$1
    _index=$2
    _b64=$3
    nc_cfg_valid "$_target" || { nc_err "未知配置目标: $_target"; return 2; }
    case "$_index" in
        *[!0-9]*|"") nc_err "分块序号必须是数字"; return 2 ;;
    esac

    _tmp=$(nc_cfg_tmp "$_target")
    _idxf=$(nc_cfg_idx "$_target")
    mkdir -p "$NC_TMP" 2>/dev/null

    if [ "$_index" = "0" ]; then
        rm -f "$_tmp" "$_idxf" 2>/dev/null
        : >"$_tmp"
        echo 1 >"$_idxf"
    else
        [ -f "$_idxf" ] || { nc_err "上传会话不存在，请重新开始"; return 1; }
        _expected=$(cat "$_idxf" 2>/dev/null | tr -d ' \r\n')
        if [ "$_index" != "$_expected" ]; then
            nc_err "分块顺序错误 (期望 $_expected，收到 $_index)"
            return 1
        fi
    fi

    _chunk="$NC_TMP/chunk.$_target.$$"
    if ! printf '%s' "$_b64" | nc_b64decode >"$_chunk" 2>/dev/null; then
        nc_err "Base64 解码失败"
        rm -f "$_chunk"
        return 1
    fi
    cat "$_chunk" >>"$_tmp" 2>/dev/null
    rm -f "$_chunk" 2>/dev/null
    chmod 600 "$_tmp" 2>/dev/null

    _next=$((_index + 1))
    echo "$_next" >"$_idxf"
    printf 'chunk %s ok\n' "$_index"
    return 0
}

# 提交临时文件
nc_cfg_commit() {
    local _core _dir _force _path _target _tmp _vrc
    _target=$1
    _force=${2:-0}
    nc_cfg_valid "$_target" || { nc_err "未知配置目标: $_target"; return 2; }

    _tmp=$(nc_cfg_tmp "$_target")
    [ -f "$_tmp" ] || { nc_err "没有待提交的配置内容"; return 1; }
    if [ "$(nc_file_size "$_tmp")" -eq 0 ]; then
        nc_err "配置内容为空，已取消提交"
        return 1
    fi

    nc_cfg_validate_file "$_target" "$_tmp"
    _vrc=$?
    if [ "$_vrc" -eq 1 ] && [ "$_force" != "1" ]; then
        nc_err "配置校验未通过，已保留临时文件。可勾选“跳过校验”后重试"
        return 1
    fi
    [ "$_vrc" -eq 1 ] && nc_warn "配置校验未通过，按请求强制保存"

    _path=$(nc_cfg_path "$_target")
    _dir=$(dirname "$_path")
    mkdir -p "$_dir" 2>/dev/null
    [ -f "$_path" ] && cp -f "$_path" "$_path.bak" 2>/dev/null
    chmod 600 "$_tmp" 2>/dev/null
    mv -f "$_tmp" "$_path" 2>/dev/null || { nc_err "写入配置失败: $_path"; return 1; }
    chmod 600 "$_path" 2>/dev/null
    rm -f "$(nc_cfg_idx "$_target")" 2>/dev/null

    if [ "$_target" = "substore" ]; then
        nc_info "已保存 Sub-Store 环境变量（重启后生效）"
    else
        _core="$_target"
        [ "$_core" = "singbox" ] && _core="sing-box"
        rm -f "$(nc_core_check_file "$_core")" 2>/dev/null
        nc_info "已保存 $(nc_cfg_label "$_target")，请重启内核后生效"
    fi
    return 0
}

# 从远程/Sub-Store 拉取配置
nc_cfg_fetch() {
    local _b64target _b64url _core _fmt _force _path _sep _size _target _tmp _url _vrc
    _target=$1
    _b64url=$2
    _b64target=$3
    _force=${4:-0}
    nc_cfg_valid "$_target" || { nc_err "未知配置目标: $_target"; return 2; }

    _url=$(printf '%s' "$_b64url" | nc_b64decode 2>/dev/null | tr -d '\r\n')
    _fmt=$(printf '%s' "$_b64target" | nc_b64decode 2>/dev/null | tr -d '\r\n')
    case "$_url" in
        http://*|https://*) ;;
        *) nc_err "只支持 http/https 地址"; return 2 ;;
    esac
    if [ -n "$_fmt" ]; then
        case "$_fmt" in
            *[!A-Za-z0-9._-]*) nc_err "非法的转换目标"; return 2 ;;
        esac
        case "$_url" in
            *\?*) _sep='&' ;;
            *) _sep='?' ;;
        esac
        _url="${_url}${_sep}target=${_fmt}"
    fi

    _tmp="$NC_TMP/fetch.$_target.$$"
    rm -f "$_tmp" 2>/dev/null
    nc_info "拉取配置: $_url"
    # 远程配置通常很小；避免代理/直连任一方向卡 15 分钟
    NC_DL_MAX_TIME=45
    NC_DL_RETRY=1
    nc_download "$_url" "$_tmp" || { unset NC_DL_MAX_TIME NC_DL_RETRY; rm -f "$_tmp"; return 1; }
    unset NC_DL_MAX_TIME NC_DL_RETRY

    _size=$(nc_file_size "$_tmp")
    if [ "$_size" -lt 2 ]; then
        nc_err "拉取到的内容为空"
        rm -f "$_tmp"
        return 1
    fi
    nc_info "已下载 $(nc_human_size "$_size")"

    # 目标类型防呆：避免把 mihomo YAML 误存进 sing-box，反之亦然
    _first=$(head -c 512 "$_tmp" 2>/dev/null | tr -d '[:space:]' | cut -c1)
    case "$_target" in
        singbox)
            if [ "$_first" != "{" ]; then
                nc_err "内容不是 JSON（首字符: ${_first:-空}），看起来是 mihomo/YAML；请从 mihomo 卡片拉取"
                rm -f "$_tmp"
                return 1
            fi
            ;;
        mihomo)
            if [ "$_first" = "{" ]; then
                nc_err "内容看起来是 JSON；请从 sing-box 卡片拉取"
                rm -f "$_tmp"
                return 1
            fi
            ;;
    esac

    nc_cfg_validate_file "$_target" "$_tmp"
    _vrc=$?
    if [ "$_vrc" -eq 1 ] && [ "$_force" != "1" ]; then
        cp -f "$_tmp" "$(nc_cfg_tmp "$_target")" 2>/dev/null
        rm -f "$_tmp"
        nc_err "配置校验未通过。临时文件已保留，可强制保存"
        return 1
    fi
    [ "$_vrc" -eq 1 ] && nc_warn "配置校验未通过，按请求强制保存"

    _path=$(nc_cfg_path "$_target")
    mkdir -p "$(dirname "$_path")" 2>/dev/null
    [ -f "$_path" ] && cp -f "$_path" "$_path.bak" 2>/dev/null
    mv -f "$_tmp" "$_path" 2>/dev/null || { nc_err "写入配置失败"; rm -f "$_tmp"; return 1; }
    chmod 600 "$_path" 2>/dev/null

    if [ "$_target" = "substore" ]; then
        nc_info "已拉取 Sub-Store 环境变量（重启后生效）"
    else
        _core="$_target"
        [ "$_core" = "singbox" ] && _core="sing-box"
        if [ "$_vrc" -eq 0 ]; then
            nc_core_write_check "$_core" ok "拉取后校验通过"
        elif [ "$_vrc" -eq 1 ]; then
            nc_core_write_check "$_core" fail "配置校验未通过"
        else
            rm -f "$(nc_core_check_file "$_core")" 2>/dev/null
        fi
        nc_info "已拉取 $(nc_cfg_label "$_target")，请重启内核后生效"
    fi
    return 0
}

nc_cfg_check() {
    local _path _rc _target
    _target=$1
    nc_cfg_valid "$_target" || { nc_err "未知配置目标: $_target"; return 2; }
    _path=$(nc_cfg_path "$_target")
    [ -f "$_path" ] || { nc_err "配置文件不存在: $_path"; return 1; }
    nc_cfg_validate_file "$_target" "$_path"
    _rc=$?
    [ "$_rc" -eq 0 ] && nc_info "校验通过: $(nc_cfg_label "$_target")"
    return "$_rc"
}

nc_cfg_delete() {
    local _core _path _target
    _target=$1
    nc_cfg_valid "$_target" || { nc_err "未知配置目标: $_target"; return 2; }
    _path=$(nc_cfg_path "$_target")
    if [ ! -f "$_path" ]; then
        nc_info "配置文件不存在"
        return 0
    fi
    cp -f "$_path" "$_path.bak" 2>/dev/null
    rm -f "$_path" 2>/dev/null
    rm -f "$(nc_cfg_tmp "$_target")" "$(nc_cfg_idx "$_target")" 2>/dev/null

    if [ "$_target" = "substore" ]; then
        nc_sub_ensure_env
        nc_info "已重置 Sub-Store 环境变量为默认值"
    else
        _core="$_target"
        [ "$_core" = "singbox" ] && _core="sing-box"
        rm -f "$(nc_core_check_file "$_core")" 2>/dev/null
        nc_info "已删除 $(nc_cfg_label "$_target")（备份: $_path.bak）"
    fi
    return 0
}

nc_cfg_download() {
    local _dir _name _out _path _target
    _target=$1
    nc_cfg_valid "$_target" || { nc_err "未知配置目标: $_target"; return 2; }
    _path=$(nc_cfg_path "$_target")
    [ -f "$_path" ] || { nc_err "配置文件不存在"; return 1; }

    _dir="/sdcard/Download/Nakedcore"
    mkdir -p "$_dir" 2>/dev/null || _dir="$NC_BACKUP"
    mkdir -p "$_dir" 2>/dev/null
    _name=""
    case "$_target" in
        singbox)  _name="config-$(date +%Y%m%d-%H%M%S).json" ;;
        mihomo)   _name="config-$(date +%Y%m%d-%H%M%S).yaml" ;;
        substore) _name="sub_store-$(date +%Y%m%d-%H%M%S).env" ;;
    esac
    _out="$_dir/$_name"
    cp -f "$_path" "$_out" 2>/dev/null || { nc_err "导出失败: $_out"; return 1; }
    nc_info "已导出: $_out"
    printf '%s\n' "$_out"
    return 0
}

nc_cfg_export() {
    local _dir _out _p
    _dir="/sdcard/Download/Nakedcore"
    mkdir -p "$_dir" 2>/dev/null || _dir="$NC_BACKUP"
    mkdir -p "$_dir" 2>/dev/null
    _out="$_dir/nakedcore-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

    # 只收集存在的路径，避免 tar 因缺失文件返回非 0
    set --
    for _p in sing-box mihomo settings.conf sub-store/data sub-store/sub_store.env \
        sub-store/backend_version sub-store/frontend_version \
        bin/sing-box.version bin/mihomo.version bin/node_version; do
        [ -e "$NC_DATA/$_p" ] && set -- "$@" "$_p"
    done

    if [ "$#" -eq 0 ]; then
        nc_err "没有可导出的配置"
        return 1
    fi

    if ! tar -czf "$_out" -C "$NC_DATA" "$@" 2>/dev/null; then
        if [ -n "$NC_BUSYBOX" ]; then
            "$NC_BUSYBOX" tar -czf "$_out" -C "$NC_DATA" "$@" 2>/dev/null || {
                nc_err "打包失败"
                return 1
            }
        else
            nc_err "打包失败"
            return 1
        fi
    fi

    nc_info "配置已导出: $_out ($(nc_human_size "$(nc_file_size "$_out")"))"
    printf '%s\n' "$_out"
    return 0
}
