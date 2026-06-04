#!/bin/sh

# ======================= 配置区 =======================
USERNAME="YOUR_ACCOUNT"
PASSWORD="YOUR_PASSWORD"
INTERFACES="wan"

PROBE_TARGET="2.2.2.2"
AUTH_HOST="10.5.0.11"

MAX_RETRIES=3
RETRY_DELAY=2
SLEEP_TIME=3
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
# ======================================================

. /lib/functions/network.sh

# --- 日志模块 ---
C_RESET='\033[0m'
C_INFO='\033[36m'
C_WARN='\033[33m'
C_ERR='\033[31m'
C_SUCC='\033[32m'
C_DEBUG='\033[90m'

DEBUG_MODE="false"
FORCE_CHECK="false"

log_sys() {
    if [ "$DEBUG_MODE" != "true" ]; then 
        logger -t CampusLogin "[$1] $2"
    fi
}
log_info()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${C_INFO}[INFO]${C_RESET} $1"; log_sys "INFO" "$1"; }
log_succ()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${C_SUCC}[SUCC]${C_RESET} $1"; log_sys "SUCC" "$1"; }
log_warn()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${C_WARN}[WARN]${C_RESET} $1"; log_sys "WARN" "$1"; }
log_err()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${C_ERR}[ERR]${C_RESET}  $1"; log_sys "ERR" "$1"; }
log_debug() { [ "$DEBUG_MODE" = "true" ] && echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${C_DEBUG}[DEBUG]${C_RESET} $1"; }


# --- 核心功能函数 ---

# 显示帮助
show_help() {
    echo "用法: $0 [-d] [-h] [接口1 接口2 ...]"
    echo "选项:"
    echo "  -d    开启调试模式 (输出详细日志并强制探测)"
    echo "  -h    显示此帮助信息"
    exit 0
}

# 解析命令行参数
parse_args() {
    while getopts "dh" opt; do
        case "$opt" in
            d) DEBUG_MODE="true"; FORCE_CHECK="true" ;;
            h) show_help ;;
            \?) echo "无效选项。请使用 -h 查看帮助。"; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    [ $# -gt 0 ] && INTERFACES="$*"
}

# 添加探测所需的单向路由
setup_routes() {
    local dev=$1
    local gw=$2
    if [ -n "$gw" ]; then
        ip route add "$PROBE_TARGET" via "$gw" dev "$dev" >/dev/null 2>&1
        ip route add "$AUTH_HOST" via "$gw" dev "$dev" >/dev/null 2>&1
    fi
}

# 清理探测遗留的路由
cleanup_routes() {
    local dev=$1
    local gw=$2
    if [ -n "$gw" ]; then
        ip route del "$PROBE_TARGET" via "$gw" dev "$dev" >/dev/null 2>&1
        ip route del "$AUTH_HOST" via "$gw" dev "$dev" >/dev/null 2>&1
    fi
}

# 获取并校验网卡物理信息
# 说明: 基于 Shell 特性，提取的数据存入全局变量 CURRENT_DEV, CURRENT_IP, CURRENT_GW，以便外层复用
get_interface_info() {
    local iface="$1"
    
    CURRENT_DEV=$(ifstatus "$iface" | jsonfilter -e '@.l3_device' 2>/dev/null)
    [ -z "$CURRENT_DEV" ] && CURRENT_DEV=$(ifstatus "$iface" | jsonfilter -e '@.device' 2>/dev/null)
    CURRENT_IP=$(ifstatus "$iface" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    CURRENT_GW=$(ifstatus "$iface" | jsonfilter -e '@["route"][0].nexthop' 2>/dev/null)

    if [ -z "$CURRENT_DEV" ] || [ -z "$CURRENT_IP" ]; then
        log_warn "[$iface] 接口未就绪 (缺少物理设备或IP)，跳过"
        return 1
    fi
    log_info "[$iface] 物理设备就绪 ($CURRENT_DEV | $CURRENT_IP | GW: ${CURRENT_GW:-未知})"
    return 0
}

# 检查接口多播在线状态
check_mwan_online() {
    local iface="$1"
    if [ "$FORCE_CHECK" = "false" ] && echo "$MWAN_STATUS" | grep -q "interface $iface is online"; then
        log_succ "[$iface] mwan3 显示已在线，跳过认证"
        return 0
    fi
    return 1
}

# 执行实际的登录请求
# 返回值: 0 表示无需重试(成功或不可逆失败)，1 表示需继续重试
perform_login() {
    local iface="$1"
    local dev="$2"
    local ip="$3"
    local raw_url="$4"

    local wlanuserip=$(echo "$raw_url" | grep -o 'wlanuserip=[^&]*' | cut -d= -f2)
    local wlanacname=$(echo "$raw_url" | grep -o 'wlanacname=[^&]*' | cut -d= -f2)
    local mac=$(echo "$raw_url" | grep -o 'mac=[^&]*' | cut -d= -f2)
    local vlan=$(echo "$raw_url" | grep -o 'vlan=[^&]*' | cut -d= -f2)
    
    [ -z "$wlanuserip" ] && wlanuserip=$ip

    if [ -z "$mac" ] || [ -z "$wlanacname" ]; then
        log_err "[$iface] 缺少关键参数 (MAC/ACName)，无法构造登录请求"
        return 1
    fi

    local mac_encoded=$(echo "$mac" | sed 's/:/%3A/g')
    local auth_api="http://${AUTH_HOST}/quickauth.do"
    local params="userid=${USERNAME}&passwd=${PASSWORD}&wlanuserip=${wlanuserip}&wlanacname=${wlanacname}&mac=${mac_encoded}&vlan=${vlan}&version=0"
    
    log_info "[$iface] 发送快速认证请求 (MAC: $mac)..."
    
    local curl_args="-s -L --connect-timeout 3 --interface $dev -A \"$UA\""
    local login_json=$(eval curl $curl_args "\"${auth_api}?${params}\"")
    
    local res_code=$(echo "$login_json" | jsonfilter -e '@.code' 2>/dev/null)
    local res_msg=$(echo "$login_json" | jsonfilter -e '@.message' 2>/dev/null)

    log_debug "[$iface] 服务器响应: $login_json"

    case "$res_code" in
        "0")
            log_succ "[$iface] 认证成功！"
            return 0
            ;;
        "1")
            log_warn "[$iface] 失败: 不在上网时段 ($res_msg)"
            return 0 # 不在时段属于逻辑限制，重试无意义，跳过该接口
            ;;
        "7")
            log_err "[$iface] 致命错误: 账号或密码错误 ($res_msg)"
            log_err "请检查脚本配置。为防止账号被锁定，将退出脚本。"
            exit 1 # 密码错误非常危险，直接终止脚本运行
            ;;
        *)
            if [ -z "$res_code" ]; then
                log_err "[$iface] 认证异常: 响应体为空或非JSON格式"
            else
                log_err "[$iface] 认证失败 (Code: $res_code): $res_msg"
            fi
            return 1 # 未知错误或网络波动，允许重试
            ;;
    esac
}

# 单个接口的探测与认证重试封装
do_probe_and_login() {
    local iface="$1"
    
    for attempt in $(seq 1 $MAX_RETRIES); do
        if [ "$attempt" -gt 1 ]; then
            log_warn "[$iface] 探测失败，正在进行重试 ($attempt/$MAX_RETRIES)..."
            sleep $RETRY_DELAY
        fi

        # 路由装载
        cleanup_routes "$CURRENT_DEV" "$CURRENT_GW"
        setup_routes "$CURRENT_DEV" "$CURRENT_GW"

        # 发起探测
        local curl_args="-s -L --connect-timeout 3 --interface $CURRENT_DEV -A \"$UA\""
        log_debug "[$iface] 正向 $PROBE_TARGET 发起探测..."
        
        local probe_res=$(eval curl $curl_args -w \"\\n%{url_effective}\" \"http://$PROBE_TARGET\" 2>&1)
        local final_url=$(echo "$probe_res" | tail -n 1)

        # 无论成功失败，探测完立刻清理，保持强壮性
        cleanup_routes "$CURRENT_DEV" "$CURRENT_GW"

        # 逻辑分发
        if echo "$probe_res" | grep -E -q "portal\.do|location\.replace"; then
            log_info "[$iface] 状态: [未登录]，准备提取参数并发起认证..."
            
            local raw_url=$(echo "$probe_res" | grep -o "http://[^\"']*portal\.do?[^\"']*")
            if [ -z "$raw_url" ]; then
                log_err "[$iface] 提取重定向URL失败，网页结构可能已改变"
                log_debug "[$iface] 探测到的原始响应: $probe_res"
                continue # 触发下一次重试
            fi
            
            log_debug "[$iface] 截获的认证跳转链接: $raw_url"
            
            # 交给登录函数处理
            perform_login "$iface" "$CURRENT_DEV" "$CURRENT_IP" "$raw_url"
            [ $? -eq 0 ] && break # 返回0表示成功或触发无需重试的异常，跳出循环
            
        elif echo "$probe_res" | grep -i -q "logout"; then
            log_succ "[$iface] 状态: [已在线] (无需重复认证)"
            if echo "$final_url" | grep -i -q "logout"; then
                log_debug "[$iface] 截获的登出跳转链接: $final_url"
            fi
            break
            
        else
            log_warn "[$iface] 未知网络状态，未检测到认证入口"
            log_debug "[$iface] 异常网页内容: $probe_res"
        fi
    done
}


# ========== 主程序流程 ==========

parse_args "$@"

[ "$DEBUG_MODE" = "true" ] && log_info "调试模式已开启 (强制探测并输出 Debug 日志)"
log_info "目标接口列表: $INTERFACES"

# 全局环境初始化
MWAN_STATUS=$(mwan3 status 2>/dev/null)
TOTAL_IFS=$(echo "$INTERFACES" | wc -w)
CURRENT_IF_INDEX=0

# 注册异常中断监听 (Ctrl+C 等)
trap 'echo -e "\n${C_WARN}脚本中断，正在清理路由...${C_RESET}"; cleanup_routes "$CURRENT_DEV" "$CURRENT_GW"; exit 1' INT TERM

log_info "开始执行认证流程..."

for IFACE in $INTERFACES; do
    CURRENT_IF_INDEX=$((CURRENT_IF_INDEX + 1))
    
    # 核心骨架 (短路求值逻辑)
    if get_interface_info "$IFACE"; then
        if ! check_mwan_online "$IFACE"; then
            do_probe_and_login "$IFACE"
        fi
    fi

    # 接口切换缓冲 (除最后一个接口外)
    if [ "$CURRENT_IF_INDEX" -lt "$TOTAL_IFS" ]; then
        sleep $SLEEP_TIME
    fi
done

log_info "认证流程全部结束"