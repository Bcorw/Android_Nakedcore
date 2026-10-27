#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - 连通性测试
# 通过当前系统网络 / TUN 检测常用服务是否可达，并记录延迟
# ============================================================

NC_CONN_RESULTS="$NC_RUN/connectivity.json"
NC_CONN_TIMEOUT="${NC_CONN_TIMEOUT:-6}"

nc_conn_ids() {
    printf '%s\n' \
        openai claude gemini grok openrouter poe suno perplexity \
        netflix disney youtube tiktok spotify \
        baidu bilibili wechat aliyun taobao \
        x telegram reddit discord \
        github cloudflare npm docker huggingface stackoverflow
}

# id|name|category|url|abbr|color
nc_conn_meta() {
    case "$1" in
        openai)      printf 'OpenAI|ai|https://api.openai.com/v1/models|OA|#10a37f' ;;
        claude)      printf 'Claude|ai|https://api.anthropic.com/v1/messages|C|#d97757' ;;
        gemini)      printf 'Gemini|ai|https://generativelanguage.googleapis.com/v1beta/models|G|#4285f4' ;;
        grok)        printf 'Grok|ai|https://api.x.ai/v1/models|X|#111111' ;;
        openrouter)  printf 'OpenRouter|ai|https://openrouter.ai/api/v1/models|OR|#6467f2' ;;
        poe)         printf 'Poe|ai|https://poe.com|P|#5d5cff' ;;
        suno)        printf 'Suno|ai|https://suno.com|S|#111111' ;;
        perplexity)  printf 'Perplexity|ai|https://www.perplexity.ai|P|#20808d' ;;
        netflix)     printf 'Netflix|stream|https://www.netflix.com|N|#e50914' ;;
        disney)      printf 'Disney+|stream|https://www.disneyplus.com|D|#113ccf' ;;
        youtube)     printf 'YouTube|stream|https://www.youtube.com|YT|#ff0033' ;;
        tiktok)      printf 'TikTok|stream|https://www.tiktok.com|TT|#111111' ;;
        spotify)     printf 'Spotify|stream|https://open.spotify.com|S|#1db954' ;;
        baidu)       printf '百度|cn|https://www.baidu.com|百|#2932e1' ;;
        bilibili)    printf '哔哩哔哩|cn|https://www.bilibili.com|B|#00aeec' ;;
        wechat)      printf '微信|cn|https://weixin.qq.com|微|#07c160' ;;
        aliyun)      printf '阿里云|cn|https://www.aliyun.com|阿|#ff6a00' ;;
        taobao)      printf '淘宝|cn|https://www.taobao.com|淘|#ff5000' ;;
        x)           printf 'X|community|https://x.com|X|#111111' ;;
        telegram)    printf 'Telegram|community|https://telegram.org|T|#229ed9' ;;
        reddit)      printf 'Reddit|community|https://www.reddit.com|R|#ff4500' ;;
        discord)     printf 'Discord|community|https://discord.com|D|#5865f2' ;;
        github)      printf 'GitHub|dev|https://github.com|GH|#24292f' ;;
        cloudflare)  printf 'Cloudflare|dev|https://www.cloudflare.com|CF|#f38020' ;;
        npm)         printf 'npm|dev|https://registry.npmjs.org|N|#cb3837' ;;
        docker)      printf 'Docker Hub|dev|https://hub.docker.com|D|#2496ed' ;;
        huggingface) printf 'Hugging Face|dev|https://huggingface.co|HF|#ffd21e' ;;
        stackoverflow) printf 'Stack Overflow|dev|https://stackoverflow.com|SO|#f48024' ;;
        *) return 1 ;;
    esac
}

nc_conn_valid() {
    nc_conn_meta "$1" >/dev/null 2>&1
}

# 出口地区，缓存 5 分钟
nc_conn_region() {
    local _cache _loc _now _ts
    _cache="$NC_RUN/connectivity_region"
    _now=$(date +%s)
    if [ -f "$_cache" ]; then
        IFS='|' read -r _ts _loc <"$_cache" 2>/dev/null
        case "$_ts" in *[!0-9]*|"") _ts=0 ;; esac
        if [ "$_loc" != "" ] && [ $((_now - _ts)) -lt 300 ]; then
            printf '%s' "$_loc"
            return 0
        fi
    fi
    _loc=""
    if [ -n "$NC_CURL" ]; then
        _loc=$("$NC_CURL" -sS --max-time 6 -A 'Nakedcore/3.3.3' \
            'https://www.cloudflare.com/cdn-cgi/trace' 2>/dev/null \
            | sed -n 's/^loc=//p' | head -n 1 | tr -d '\r\n')
    fi
    case "$_loc" in
        [A-Z][A-Z]) ;;
        *) _loc="" ;;
    esac
    printf '%s|%s\n' "$_now" "$_loc" >"$_cache" 2>/dev/null
    printf '%s' "$_loc"
}

# 输出单个服务的 JSON 结果；第二个参数可传入已探测的 region
nc_conn_probe_json() {
    local _abbr _cat _color _err _errmsg _http _id _label _lat _meta _name _oldifs _out _rc _region _region_arg _status _time _url
    _id=$1
    _region_arg=$2
    _meta=$(nc_conn_meta "$_id") || return 2
    _oldifs=$IFS
    IFS='|'
    set -- $_meta
    IFS=$_oldifs
    _name=$1; _cat=$2; _url=$3; _abbr=$4; _color=$5
    _region=$_region_arg
    [ -n "$_region" ] || _region=$(nc_conn_region)

    _http=0
    _time=0
    _errmsg=""
    _err="$NC_TMP/conn-err.$$.${_id}"
    if [ -n "$NC_CURL" ]; then
        _out=$("$NC_CURL" -L -sS -A 'Nakedcore/3.3.3 (Android)' \
            --connect-timeout 4 --max-time "$NC_CONN_TIMEOUT" \
            -o /dev/null -w '%{http_code} %{time_total}' "$_url" 2>"$_err")
        _rc=$?
        set -- $_out
        case "${1:-0}" in *[!0-9]*|"") _http=0 ;; *) _http=$1 ;; esac
        case "${2:-0}" in *[!0-9.]*|"") _time=0 ;; *) _time=$2 ;; esac
        # curl 的 http_code 可能是 000；JSON 里必须是 0
        _http=$(printf '%d' "$_http" 2>/dev/null) || _http=0
        case "$_http" in *[!0-9]*|"") _http=0 ;; esac
        if [ "$_rc" -ne 0 ] && [ "$_http" = "0" ]; then
            _errmsg=$(head -n 1 "$_err" 2>/dev/null | tr -d '\r' | cut -c1-180)
        fi
    else
        _errmsg="curl 不可用"
    fi
    rm -f "$_err" 2>/dev/null
    _lat=$(awk -v t="$_time" 'BEGIN { printf "%d", t * 1000 }' 2>/dev/null)
    case "$_lat" in *[!0-9]*|"") _lat=0 ;; esac

    case "$_cat" in
        stream)
            case "$_http" in
                2??|3??) _status="unlocked"; _label="已解锁" ;;
                401|403|451) _status="locked"; _label="未解锁" ;;
                *) _status="other"; _label="其他" ;;
            esac
            ;;
        *)
            case "$_http" in
                2??|3??|4??) _status="ok"; _label="已完成" ;;
                451) _status="locked"; _label="未解锁" ;;
                *) _status="other"; _label="其他" ;;
            esac
            ;;
    esac

    printf '{"id":"%s","status":"%s","label":"%s","http":%s,"latency_ms":%s,"region":"%s","error":"%s","tested_at":%s}' \
        "$(nc_json_escape "$_id")" "$_status" "$_label" "$_http" "$_lat" \
        "$(nc_json_escape "$_region")" "$(nc_json_escape "$_errmsg")" "$(nc_now)"
}

nc_conn_list_json() {
    local _abbr _cat _color _first _id _meta _name _oldifs _url
    _first=1
    printf '['
    for _id in $(nc_conn_ids); do
        _meta=$(nc_conn_meta "$_id") || continue
        _oldifs=$IFS
        IFS='|'
        set -- $_meta
        IFS=$_oldifs
        _name=$1; _cat=$2; _url=$3; _abbr=$4; _color=$5
        [ "$_first" = "1" ] || printf ','
        _first=0
        printf '{"id":"%s","name":"%s","category":"%s","url":"%s","abbr":"%s","color":"%s"}' \
            "$(nc_json_escape "$_id")" "$(nc_json_escape "$_name")" "$_cat" \
            "$(nc_json_escape "$_url")" "$(nc_json_escape "$_abbr")" "$(nc_json_escape "$_color")"
    done
    printf ']'
}

nc_conn_results_json() {
    if [ -s "$NC_CONN_RESULTS" ] && head -c 1 "$NC_CONN_RESULTS" 2>/dev/null | grep -q '{'; then
        cat "$NC_CONN_RESULTS"
    else
        printf '{"tested_at":0,"region":"","results":{}}'
    fi
}

nc_conn_test() {
    local _cat _file _first _id _n _region _tmp
    _region=$(nc_conn_region)
    _tmp="$NC_TMP/conn-$$"
    mkdir -p "$_tmp" 2>/dev/null
    _n=0
    for _id in $(nc_conn_ids); do
        _n=$((_n + 1))
        (nc_conn_probe_json "$_id" "$_region" >"$_tmp/$_id.json") &
        if [ $((_n % 4)) -eq 0 ]; then wait; fi
    done
    wait

    _file="$NC_CONN_RESULTS.tmp.$$"
    {
        printf '{"tested_at":%s,"region":"%s","results":{' "$(nc_now)" "$(nc_json_escape "$_region")"
        _first=1
        for _id in $(nc_conn_ids); do
            [ -s "$_tmp/$_id.json" ] || continue
            [ "$_first" = "1" ] || printf ','
            _first=0
            printf '"%s":' "$_id"
            cat "$_tmp/$_id.json"
        done
        printf '}}'
    } >"$_file" 2>/dev/null
    mv -f "$_file" "$NC_CONN_RESULTS" 2>/dev/null
    rm -rf "$_tmp" 2>/dev/null
    nc_info "连通性测试完成: $_n 个服务"
}
