#!/bin/sh

# ======================= 配置区 =======================
# 账号配置
USERNAME="YOUR_ACCOUNT"
PASSWORD="YOUR_PASSWORD"

# 接口列表 (空格分隔)
INTERFACES="wan vwan1"

# 目标地址配置
# PROBE_TARGET: 用于触发认证的内网劫持IP
PROBE_TARGET="2.2.2.2"
# AUTH_HOST: 认证服务器IP (用于路由绑定)
AUTH_HOST="10.5.0.11"
# AC_IP: AC控制器IP (登录参数用)
AC_IP="10.5.0.12"

# 浏览器标识
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# 接口切换间隔 (秒)
SLEEP_TIME=3
# ======================================================

# 引入 OpenWrt 网络函数库
. /lib/functions/network.sh

# --- 日志函数 ---
log() {
    local MSG="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "$MSG"
    # 非调试模式下写入系统日志，避免填满存储
    if [ "$DEBUG_MODE" != "true" ]; then logger -t CampusLogin "$1"; fi
}

# --- 路由清理函数 (RAII 风格) ---
# 参数: $1=设备名(eth0), $2=网关IP
cleanup_routes() {
    local DEV=$1
    local GW=$2
    # 仅当网关存在时才尝试删除
    if [ -n "$GW" ]; then
        # 删除探测IP的路由
        ip route del "$PROBE_TARGET" via "$GW" dev "$DEV" >/dev/null 2>&1
        # 删除认证服务器的路由
        ip route del "$AUTH_HOST" via "$GW" dev "$DEV" >/dev/null 2>&1
    fi
}

# --- 脚本入口处理 ---
MODE="$1"       # 第一个参数: debug
TARGET_IF="$2"  # 第二个参数: 指定接口 (例如 vwan1)

DEBUG_MODE="false"
FORCE_CHECK="false"

if [ "$MODE" = "debug" ]; then
    DEBUG_MODE="true"
    FORCE_CHECK="true"
    log ">>> 调试模式已开启 (详细日志 + 强制检查) <<<"
fi

if [ -n "$TARGET_IF" ]; then
    INTERFACES="$TARGET_IF"
    log ">>> 单接口模式: 仅处理 [$TARGET_IF] <<<"
fi

# 捕获退出信号 (Ctrl+C)，确保路由被清理
trap 'echo "脚本中断，正在清理..."; exit 1' INT TERM

log "============ 开始认证流程 ============"

MWAN_STATUS=$(mwan3 status 2>/dev/null)

for IFACE in $INTERFACES; do
    log "-------------------------------------------------"
    
    # 1. 获取接口物理信息
    # ifstatus 和 jsonfilter 是 OpenWrt 特有的强大工具
    REAL_DEVICE=$(ifstatus "$IFACE" | jsonfilter -e '@.l3_device') 
    [ -z "$REAL_DEVICE" ] && REAL_DEVICE=$(ifstatus "$IFACE" | jsonfilter -e '@.device')
    IP_ADDR=$(ifstatus "$IFACE" | jsonfilter -e '@["ipv4-address"][0].address')
    GATEWAY=$(ifstatus "$IFACE" | jsonfilter -e '@["route"][0].nexthop')

    # 基础检查
    if [ -z "$REAL_DEVICE" ] || [ -z "$IP_ADDR" ]; then
        log "[$IFACE] -> 跳过: 接口未就绪 (无设备或无IP)。"
        continue
    fi

    log ">>> 接口: [$IFACE] (Dev: $REAL_DEVICE | IP: $IP_ADDR | GW: ${GATEWAY:-未知})"

    # 2. 判断是否在线 (利用 mwan3 状态作为快速筛选)
    # 如果是 debug 模式，则无视 mwan3 状态，强制跑一遍流程
    if [ "$FORCE_CHECK" = "false" ] && echo "$MWAN_STATUS" | grep -q "interface $IFACE is online"; then
        log "[$IFACE] -> mwan3 显示在线。跳过 (节省资源)。"
        continue
    fi

    # 3. 准备路由 (关键步骤)
    # 强制让 2.2.2.2 和 10.5.0.11 走当前接口的网关
    # 先尝试删除旧路由(防御性编程)，再添加新路由
    cleanup_routes "$REAL_DEVICE" "$GATEWAY"
    
    if [ -n "$GATEWAY" ]; then
        ip route add "$PROBE_TARGET" via "$GATEWAY" dev "$REAL_DEVICE" >/dev/null 2>&1
        ip route add "$AUTH_HOST" via "$GATEWAY" dev "$REAL_DEVICE" >/dev/null 2>&1
    fi

    # 4. 发起探测
    # -L: 跟随跳转 (虽然内网劫持通常直接返回HTML，但加上更保险)
    # --connect-timeout: 设置超时，防止卡死
    CURL_ARGS="-s -L --connect-timeout 3 --interface $REAL_DEVICE -A \"$UA\""
    
    # 如果是 debug 模式，加上 -v 打印握手头信息
    if [ "$DEBUG_MODE" = "true" ]; then
        log "    [DEBUG] 正向 $PROBE_TARGET 发起探测..."
        PROBE_RES=$(eval curl -v $CURL_ARGS "http://$PROBE_TARGET" 2>&1)
        echo "$PROBE_RES" | head -n 20 # 只打印前20行避免刷屏
    else
        PROBE_RES=$(eval curl $CURL_ARGS "http://$PROBE_TARGET" 2>&1)
    fi

    # 5. 分析探测结果
    # 逻辑：如果返回内容里包含 "portal.do" 或者 "location.replace"，说明被劫持了，需要登录
    if echo "$PROBE_RES" | grep -E -q "portal\.do|location\.replace"; then
        log "[$IFACE] -> 状态: [未登录] (检测到认证跳转)，准备提取参数..."

        # === 参数提取 (更健壮的正则) ===
        # 尝试从 HTML 中提取包含参数的那个长 URL
        # 匹配 http://...portal.do?... 后面非引号的字符
        RAW_URL=$(echo "$PROBE_RES" | grep -o "http://[^\"']*portal\.do?[^\"']*")
        
        if [ -z "$RAW_URL" ]; then
            log "[$IFACE] -> 错误: 无法从响应中提取跳转URL，可能网页结构已变。"
        else
            # 从 URL 中切割参数
            WLAN_USER_IP=$(echo "$RAW_URL" | grep -o 'wlanuserip=[^&]*' | cut -d= -f2)
            WLAN_AC_NAME=$(echo "$RAW_URL" | grep -o 'wlanacname=[^&]*' | cut -d= -f2)
            MAC=$(echo "$RAW_URL" | grep -o 'mac=[^&]*' | cut -d= -f2)
            VLAN=$(echo "$RAW_URL" | grep -o 'vlan=[^&]*' | cut -d= -f2)
            
            # 如果没取到 IP，兜底使用接口 IP
            [ -z "$WLAN_USER_IP" ] && WLAN_USER_IP=$IP_ADDR

            if [ -n "$MAC" ] && [ -n "$WLAN_AC_NAME" ]; then
                # 构造登录请求
                TIMESTAMP=$(date +%s%3N)
                UUID=$(cat /proc/sys/kernel/random/uuid)
                MAC_ENCODED=$(echo "$MAC" | sed 's/:/%3A/g')
                
                AUTH_API="http://${AUTH_HOST}/quickauth.do"
                PARAMS="userid=${USERNAME}&passwd=${PASSWORD}&wlanuserip=${WLAN_USER_IP}&wlanacname=${WLAN_AC_NAME}&wlanacIp=${AC_IP}&mac=${MAC_ENCODED}&vlan=${VLAN}&version=0&portalpageid=1&timestamp=${TIMESTAMP}&uuid=${UUID}"
                
                log "[$IFACE] -> 发送登录请求 (MAC: $MAC)..."
                
                LOGIN_JSON=$(eval curl $CURL_ARGS "${AUTH_API}?${PARAMS}")

                # === 结果解析 (处理不同状态码) ===
                RES_CODE=$(echo "$LOGIN_JSON" | jsonfilter -e '@.code')
                RES_MSG=$(echo "$LOGIN_JSON" | jsonfilter -e '@.message')

                if [ "$DEBUG_MODE" = "true" ]; then
                    echo "    [DEBUG] 服务器响应: $LOGIN_JSON"
                fi

                case "$RES_CODE" in
                    "0")
                        log "[$IFACE] -> >>> 认证成功! <<<"
                        ;;
                    "1")
                        log "[$IFACE] -> 失败: 不在上网时段 ($RES_MSG)"
                        # 这里可以考虑是否要 exit，或者只是跳过
                        ;;
                    "7")
                        log "[$IFACE] -> 严重失败: 账号或密码错误! ($RES_MSG)"
                        # 密码错通常意味着配置错了，继续重试可能会导致账号被锁
                        exit 1 
                        ;;
                    *)
                        if [ -z "$RES_CODE" ]; then
                            log "[$IFACE] -> 异常: 响应非JSON格式或为空。"
                        else
                            log "[$IFACE] -> 未知错误 (Code: $RES_CODE): $RES_MSG"
                        fi
                        ;;
                esac
            else
                log "[$IFACE] -> 错误: 关键参数(MAC/ACName)提取失败。"
            fi
        fi

    elif echo "$PROBE_RES" | grep -i -q "logout"; then
        log "[$IFACE] -> 状态: [已在线] (无需操作)。"
    else
        log "[$IFACE] -> 未知状态 (未检测到 Login 也未检测到 Logout)。"
        if [ "$DEBUG_MODE" = "true" ]; then
            echo "    [DEBUG] 响应内容: $PROBE_RES"
        fi
    fi

    # 6. 清理路由 (恢复原状)
    cleanup_routes "$REAL_DEVICE" "$GATEWAY"

    # 避免并发请求过快
    sleep $SLEEP_TIME
done

log "============ 结束 ============"