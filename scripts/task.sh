#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - 异步任务
# WebUI 触发耗时操作后轮询日志，不阻塞 WebView
# ============================================================

nc_task_dir() { printf '%s/%s' "$NC_TASKS" "$1"; }

nc_task_valid_id() {
    case "$1" in
        ""|*[!A-Za-z0-9-]*) return 1 ;;
        *) return 0 ;;
    esac
}

nc_task_clean() {
    local _d _n
    mkdir -p "$NC_TASKS" 2>/dev/null
    _n=0
    for _d in $(ls -1dt "$NC_TASKS"/* 2>/dev/null); do
        _n=$((_n + 1))
        [ "$_n" -gt 20 ] && rm -rf "$_d" 2>/dev/null
    done
}

nc_task_label() {
    case "$1 $2" in
        "core start"*)       printf '启动内核' ;;
        "core stop"*)        printf '停止内核' ;;
        "core restart"*)     printf '重启内核' ;;
        "core switch"*)      printf '切换内核' ;;
        "core update"*)      printf '更新内核' ;;
        "core rollback"*)    printf '回滚内核' ;;
        "sub update"*)       printf '更新 Sub-Store' ;;
        "sub restart"*)      printf '重启 Sub-Store' ;;
        "sub start"*)        printf '启动 Sub-Store' ;;
        "sub stop"*)         printf '停止 Sub-Store' ;;
        "sub regen-path"*)   printf '重新生成访问路径' ;;
        "cfg fetch"*)        printf '拉取配置' ;;
        "cfg export"*)       printf '导出配置' ;;
        "all update"*)       printf '一键更新' ;;
        "checkup"*)          printf '检查更新' ;;
        *)                   printf '执行任务' ;;
    esac
}

nc_task_start() {
    local _dir _id _run
    [ "$#" -gt 0 ] || { nc_err "缺少任务命令"; return 2; }
    nc_task_clean
    mkdir -p "$NC_TASKS" 2>/dev/null

    _id=$(nc_random_id)
    _dir=$(nc_task_dir "$_id")
    mkdir -p "$_dir" 2>/dev/null || return 1
    printf '%s\n' "$@" >"$_dir/args" 2>/dev/null
    printf 'queued\n' >"$_dir/status" 2>/dev/null
    nc_task_label "$@" >"$_dir/label" 2>/dev/null
    date +%s >"$_dir/started" 2>/dev/null
    printf '%s' "$_id" >"$NC_RUN/current_task" 2>/dev/null

    # task start 本身也可能由 WebUI 通过 ksu.exec 触发；worker 必须脱离进程树
    # 短任务可能在 1 秒内结束，因此这里不做“进程是否仍存活”的校验
    nc_spawn_detached "$_dir/boot.log" "$_dir/pid" "$NC_SELF" task _run "$_id"

    printf '{"id":"%s","state":"running","label":"%s"}\n' "$_id" "$(nc_task_label "$@")"
    return 0
}

nc_task_run() {
    local _dir _id _line _rc
    _id=$1
    nc_task_valid_id "$_id" || exit 2
    _dir=$(nc_task_dir "$_id")
    [ -d "$_dir" ] || exit 2

    printf 'running\n' >"$_dir/status" 2>/dev/null
    echo $$ >"$_dir/pid" 2>/dev/null
    date +%s >"$_dir/started" 2>/dev/null
    # worker 自身的日志与命令输出都进入任务日志
    exec >>"$_dir/log" 2>&1

    set --
    [ -f "$_dir/args" ] && while IFS= read -r _line; do
        set -- "$@" "$_line"
    done <"$_dir/args"

    nc_info "任务开始: $(cat "$_dir/label" 2>/dev/null)"
    "$NC_SELF" "$@" >>"$_dir/log" 2>&1
    _rc=$?

    if [ "$_rc" -eq 0 ]; then
        printf 'success\n' >"$_dir/status" 2>/dev/null
        nc_info "任务完成"
    else
        printf '%s\n' "$_rc" >"$_dir/status" 2>/dev/null
        nc_err "任务失败 (exit $_rc)"
    fi
    echo "$(nc_now)" >"$_dir/finished" 2>/dev/null
    printf '\n' >>"$_dir/log" 2>/dev/null
    if [ "$(cat "$NC_RUN/current_task" 2>/dev/null | tr -d ' \r\n')" = "$_id" ]; then
        rm -f "$NC_RUN/current_task" 2>/dev/null
    fi
    exit "$_rc"
}

nc_task_state() {
    local _dir _id _pid _st
    _id=$1
    _dir=$(nc_task_dir "$_id")
    _st=$(cat "$_dir/status" 2>/dev/null | tr -d ' \r\n')
    case "$_st" in
        queued|running)
            _pid=$(cat "$_dir/pid" 2>/dev/null | tr -d ' \r\n')
            if [ -n "$_pid" ] && nc_pid_alive "$_pid"; then
                printf 'running'
            else
                printf '137'
            fi
            ;;
        success|failed|cancelled|137)
            printf '%s' "$_st"
            ;;
        ""|*[!0-9]*)
            printf 'failed'
            ;;
        *)
            printf '%s' "$_st"
            ;;
    esac
}

nc_task_state_name() {
    case "$1" in
        running) printf 'running' ;;
        success|0) printf 'success' ;;
        cancelled) printf 'cancelled' ;;
        *) printf 'failed' ;;
    esac
}

nc_task_status() {
    local _code _dir _elapsed _finished _id _label _logf _name _now _size _started _state _tail
    _id=$1
    nc_task_valid_id "$_id" || { printf '{"error":"invalid id"}\n'; return 2; }
    _dir=$(nc_task_dir "$_id")
    [ -d "$_dir" ] || { printf '{"error":"not found"}\n'; return 1; }

    _state=$(nc_task_state "$_id")
    _name=$(nc_task_state_name "$_state")
    _code=""
    case "$_state" in
        success) _code=0 ;;
        running) _code="" ;;
        cancelled) _code=143 ;;
        137) _code=137 ;;
        *)
            case "$_state" in
                *[!0-9]*|"") _code=1 ;;
                *) _code="$_state" ;;
            esac
            ;;
    esac

    _logf="$_dir/log"
    _tail=""
    [ -f "$_logf" ] && _tail=$(tail -c 6000 "$_logf" 2>/dev/null | tr -d '\r')
    _size=$(nc_file_size "$_logf")
    _label=$(cat "$_dir/label" 2>/dev/null | tr -d '\r\n')
    _started=$(cat "$_dir/started" 2>/dev/null | tr -d ' \r\n')
    _finished=$(cat "$_dir/finished" 2>/dev/null | tr -d ' \r\n')
    _now=$(nc_now)
    _elapsed=0
    [ -n "$_started" ] && _elapsed=$((_now - _started))
    if [ "$_elapsed" -lt 0 ]; then _elapsed=0; fi

    printf '{"id":"%s","state":"%s","code":%s,"label":"%s","log":"%s","log_size":%s,"elapsed":%s,"finished":%s}\n' \
        "$_id" "$_name" "${_code:-null}" \
        "$_label" \
        "$(nc_json_escape "$_tail")" \
        "$_size" "$_elapsed" "${_finished:-0}"
    return 0
}

nc_task_current_id() {
    local _id _state
    # 快路径：task start 写入 current_task；没有就代表当前没有 UI 任务
    [ -f "$NC_RUN/current_task" ] || return 1
    IFS= read -r _id <"$NC_RUN/current_task" 2>/dev/null
    _id=${_id%?}
    if [ -n "$_id" ] && [ "$(nc_task_state "$_id")" = "running" ]; then
        printf '%s' "$_id"
        return 0
    fi
    rm -f "$NC_RUN/current_task" 2>/dev/null
    return 1
}

nc_task_current_json() {
    local _dir _id _label _started
    _id=$(nc_task_current_id) || { printf 'null'; return 0; }
    _dir=$(nc_task_dir "$_id")
    _label=$(cat "$_dir/label" 2>/dev/null | tr -d '\r\n')
    _started=$(cat "$_dir/started" 2>/dev/null | tr -d ' \r\n')
    printf '{"id":"%s","state":"running","label":"%s","started":%s}' \
        "$_id" "$_label" "${_started:-0}"
}

nc_task_last_json() {
    local _d _id _label _name _state
    _d=$(ls -1dt "$NC_TASKS"/* 2>/dev/null | head -n 1)
    [ -n "$_d" ] || { printf 'null'; return 0; }
    _id=$(basename "$_d")
    _state=$(nc_task_state "$_id")
    _name=$(nc_task_state_name "$_state")
    _label=$(cat "$_d/label" 2>/dev/null | tr -d '\r\n')
    printf '{"id":"%s","state":"%s","label":"%s"}' \
        "$_id" "$_name" "$_label"
}

nc_task_cancel() {
    local _dir _id _pid
    _id=$1
    nc_task_valid_id "$_id" || { nc_err "非法任务 ID"; return 2; }
    _dir=$(nc_task_dir "$_id")
    [ -d "$_dir" ] || { nc_err "任务不存在"; return 1; }
    _pid=$(cat "$_dir/pid" 2>/dev/null | tr -d ' \r\n')
    if [ -n "$_pid" ] && nc_pid_alive "$_pid"; then
        kill -TERM "$_pid" 2>/dev/null
        sleep 0.5 2>/dev/null || sleep 1
        nc_pid_alive "$_pid" && kill -KILL "$_pid" 2>/dev/null
    fi
    printf 'cancelled\n' >"$_dir/status" 2>/dev/null
    if [ "$(cat "$NC_RUN/current_task" 2>/dev/null | tr -d ' \r\n')" = "$_id" ]; then
        rm -f "$NC_RUN/current_task" 2>/dev/null
    fi
    nc_info "任务已取消"
    return 0
}

nc_task_log() {
    local _dir _id _lines
    _id=$1
    _lines=${2:-200}
    nc_task_valid_id "$_id" || return 2
    _dir=$(nc_task_dir "$_id")
    [ -f "$_dir/log" ] && tail -n "$_lines" "$_dir/log" 2>/dev/null
    return 0
}
