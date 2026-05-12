#!/usr/bin/env bash
# carrox_vps_check.sh - VPS 综合体检（虚拟化指纹 / 超开 / 三网回程 / 磁盘 / 解锁）
# License: MIT
# Repo: https://github.com/AiCarrox/carrox-vps-check
# 用法:
#   bash carrox_vps_check.sh                # 一键全测（非 root 请在前面加 sudo）
#   bash <(curl -sL https://raw.githubusercontent.com/AiCarrox/carrox-vps-check/main/carrox_vps_check.sh)
# 输出:
#   屏幕    : 实时进度
#   日志    : <results>/<host>_check_<ts>.log     (含详细过程)
#   报告    : <results>/<host>_check_<ts>.txt     (整洁结论)

set -u
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

VERSION="v1.0.0"
HOST_TAG="${HOSTNAME:-unknown}"
TS="$(date +%Y%m%d_%H%M)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"

# 报告目录优先级: 同仓 results/  →  ./results  →  $HOME/vps_check_results
if [ -d "${SCRIPT_DIR}/../../results" ] && [ -w "${SCRIPT_DIR}/../../results" ]; then
    OUT_DIR="$(cd "${SCRIPT_DIR}/../../results" && pwd)"
elif [ -w "$(pwd)" ]; then
    OUT_DIR="$(pwd)/results"
else
    OUT_DIR="$HOME/vps_check_results"
fi
mkdir -p "$OUT_DIR" || OUT_DIR="/tmp"

LOG_FILE="${OUT_DIR}/${HOST_TAG}_check_${TS}.log"
RPT_FILE="${OUT_DIR}/${HOST_TAG}_check_${TS}.txt"
HTML_FILE="${OUT_DIR}/${HOST_TAG}_check_${TS}.html"
: > "$LOG_FILE"
: > "$RPT_FILE"

# ============== 输出工具 ==============
# step  : 屏幕进度 + 日志
# log   : 仅日志
# rpt   : 仅写最终报告（不上屏）
step()  { local m="[$(date +%H:%M:%S)] $*"; echo "$m"; echo "$m" >> "$LOG_FILE"; }
log()   { echo "$@" >> "$LOG_FILE"; }
rpt()   { echo "$@" >> "$RPT_FILE"; }
rline() { rpt "----------------------------------------------------------------"; }
rsect() { rpt ""; rpt "================================================================"; rpt "$*"; rpt "================================================================"; }
rkv()   { printf "%-22s %s\n" "$1" "$2" >> "$RPT_FILE"; }
rate()  {
    # rate <good|ok|warn|bad> <text>
    case "$1" in
        good) echo "[🟢 良好] $2" ;;
        ok)   echo "[🟢 正常] $2" ;;
        fair) echo "[🟡 一般] $2" ;;
        warn) echo "[🟠 偏弱] $2" ;;
        bad)  echo "[🔴 较差] $2" ;;
        info) echo "[ℹ️ 信息] $2" ;;
        *) echo "$2" ;;
    esac
}

# ============== 报告头 ==============
rpt "################################################################"
rpt "                 VPS Quality Check Report  ${VERSION}"
rpt "                 https://github.com/AiCarrox/carrox-vps-check"
rpt "       报告时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
rpt "       主机    ：${HOST_TAG}"
rpt "################################################################"

echo "================================================================"
echo "       VPS Quality Check  ${VERSION}   主机: ${HOST_TAG}"
echo "       开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"

#######################################
# §0 准备
#######################################
step "§0 依赖检查与准备"

if [ "$(id -u)" -ne 0 ]; then
    step "  ⚠️  非 root 运行，部分采集（dmidecode/dmesg）可能受限"
fi

NEED=(sysbench fio mtr-tiny dnsutils whois pciutils dmidecode util-linux procps net-tools sysstat ethtool curl jq)
MISSING=()
for pkg in "${NEED[@]}"; do
    case "$pkg" in
        mtr-tiny) cmd=mtr ;;
        dnsutils) cmd=dig ;;
        util-linux) cmd=lsblk ;;
        procps) cmd=vmstat ;;
        net-tools) cmd=ifconfig ;;
        sysstat) cmd=mpstat ;;
        pciutils) cmd=lspci ;;
        *) cmd="$pkg" ;;
    esac
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$pkg")
done

if [ "${#MISSING[@]}" -gt 0 ] && command -v apt-get >/dev/null 2>&1; then
    step "  缺失依赖: ${MISSING[*]}，开始静默安装..."
    apt-get update -qq >>"$LOG_FILE" 2>&1
    apt-get install -y -qq "${MISSING[@]}" >>"$LOG_FILE" 2>&1 || step "  ⚠️ 部分依赖安装失败"
fi

# 低内存机器自加临时 swap（仅 sysbench 用，结束自动卸载）
SWAP_TOTAL=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo)
TMP_SWAP=""
if [ "${SWAP_TOTAL:-0}" -lt 524288 ] && [ "${MEM_TOTAL:-0}" -lt 2097152 ]; then
    TMP_SWAP=/tmp/.vps_check_swap
    if fallocate -l 1G "$TMP_SWAP" 2>/dev/null && chmod 600 "$TMP_SWAP" \
        && mkswap "$TMP_SWAP" >/dev/null 2>&1 && swapon "$TMP_SWAP" 2>/dev/null; then
        step "  已挂载 1G 临时 swap（脚本结束自动卸载）"
    else
        TMP_SWAP=""
    fi
fi
trap '[ -n "${TMP_SWAP:-}" ] && swapoff "$TMP_SWAP" 2>/dev/null; [ -n "${TMP_SWAP:-}" ] && rm -f "$TMP_SWAP"' EXIT

#######################################
# §1 虚拟化与硬件指纹
#######################################
step "§1 虚拟化与硬件指纹"
rsect "§1 虚拟化与硬件指纹"
rpt "目的：识别虚拟化技术栈、设备厂商和 BIOS，判断本机是物理机/容器/KVM等。"

VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"
case "$VIRT" in
    none)              VIRT_RATE=$(rate good "未检测到虚拟化层（疑似物理机）") ;;
    kvm|qemu)          VIRT_RATE=$(rate ok   "完整 KVM/QEMU 虚拟化") ;;
    vmware|microsoft|xen|hyperv) VIRT_RATE=$(rate ok "传统 hypervisor: $VIRT") ;;
    lxc|openvz|docker) VIRT_RATE=$(rate warn "容器型，共享内核（隔离弱）") ;;
    *)                 VIRT_RATE=$(rate info "$VIRT") ;;
esac
rkv "虚拟化类型:" "$VIRT_RATE"
[ -e /dev/kvm ] && rkv "/dev/kvm:" "$(rate good "存在（可嵌套虚拟化）")" \
                || rkv "/dev/kvm:" "$(rate info "不存在")"

if grep -q hypervisor /proc/cpuinfo; then
    rkv "hypervisor flag:" "$(rate info "在虚拟机内")"
else
    rkv "hypervisor flag:" "$(rate good "未检测到（疑似物理机）")"
fi

# DMI 指纹
DMI_SYS_VEN=""; DMI_SYS_PROD=""; DMI_BIOS_VEN=""; DMI_BIOS_VER=""
if command -v dmidecode >/dev/null 2>&1; then
    DMI_SYS_VEN=$(dmidecode -s system-manufacturer 2>/dev/null | head -1)
    DMI_SYS_PROD=$(dmidecode -s system-product-name 2>/dev/null | head -1)
    DMI_BIOS_VEN=$(dmidecode -s bios-vendor 2>/dev/null | head -1)
    DMI_BIOS_VER=$(dmidecode -s bios-version 2>/dev/null | head -1)
fi
rkv "厂商:"   "${DMI_SYS_VEN:-N/A}"
rkv "产品:"   "${DMI_SYS_PROD:-N/A}"
rkv "BIOS:"   "${DMI_BIOS_VEN:-N/A} ${DMI_BIOS_VER:-}"

# 块设备/网卡驱动
BLK=$(lsblk -d -o NAME,TRAN 2>/dev/null | awk 'NR>1 && $1!~/^loop/{print $1"("$2")"}' | tr '\n' ' ')
rkv "块设备:" "${BLK:-N/A}"
NIC_DRV=""
for nic in $(ls /sys/class/net 2>/dev/null | grep -vE '^lo$|docker|veth|br-'); do
    drv=$(ethtool -i "$nic" 2>/dev/null | awk -F': ' '/^driver/{print $2}')
    NIC_DRV="${NIC_DRV}${nic}=${drv:-?} "
done
rkv "网卡驱动:" "${NIC_DRV:-N/A}"

# 详情写日志
{
    echo "--- dmidecode -t system ---"
    dmidecode -t system 2>/dev/null
    echo "--- lspci virtio/虚拟设备 ---"
    lspci 2>/dev/null | grep -iE 'virtio|red hat|qemu|vmware|hyper-v|xen'
    echo "--- /sys/class/dmi/id ---"
    for f in sys_vendor product_name product_version board_vendor board_name bios_vendor bios_version; do
        [ -r "/sys/class/dmi/id/$f" ] && echo "$f: $(cat /sys/class/dmi/id/$f)"
    done
} >>"$LOG_FILE" 2>&1

#######################################
# §2 系统与硬件
#######################################
step "§2 系统与硬件信息"
rsect "§2 系统与硬件"
rpt "目的：列出操作系统、CPU、内存、磁盘、网卡等基础规格。"

OS_NAME=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "unknown")
rkv "操作系统:" "$OS_NAME $(uname -r)"
rkv "架构:"     "$(uname -m)"
rkv "运行时间:" "$(uptime -p 2>/dev/null || echo unknown)"
rkv "负载:"     "$(awk '{print $1, $2, $3}' /proc/loadavg)"

# CPU
CPU_MODEL=$(awk -F: '/^model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')
CPU_PHYS=$(awk '/^physical id/{print $4}' /proc/cpuinfo | sort -u | wc -l)
[ "$CPU_PHYS" -lt 1 ] && CPU_PHYS=1
CPU_LOG=$(grep -c ^processor /proc/cpuinfo)
CPU_MHZ=$(awk -F: '/^cpu MHz/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')
rkv "CPU:"        "$CPU_MODEL"
rkv "核心:"       "${CPU_PHYS} 物理 / ${CPU_LOG} 逻辑 @ ${CPU_MHZ} MHz"
FLAGS=$(awk '/^flags/{print; exit}' /proc/cpuinfo)
INSN=""
for f in vmx svm aes avx2 bmi2 ept npt; do
    if echo "$FLAGS" | grep -qw "$f"; then INSN="${INSN}✔${f} "; else INSN="${INSN}✘${f} "; fi
done
rkv "指令集:" "$INSN"

# 内存
MEM_GB=$(awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
MEM_AVAIL=$(awk '/MemAvailable/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
SWAP_GB=$(awk '/SwapTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo)
rkv "内存:"   "${MEM_GB} GB 总 / ${MEM_AVAIL} GB 可用"
rkv "Swap:"   "${SWAP_GB} GB"

# 磁盘
ROOT_INFO=$(df -hT / 2>/dev/null | awk 'NR==2{printf "%s 总 / %s 已用(%s) / %s 可用 [%s]", $3,$4,$6,$5,$2}')
rkv "根分区:" "$ROOT_INFO"
DISK_LIST=$(lsblk -d -o NAME,SIZE,ROTA,MODEL 2>/dev/null | awk 'NR>1 && $1!~/^loop/{rota=($3==1?"HDD":"SSD"); printf "%s=%s(%s) ", $1,$2,rota}')
rkv "物理盘:" "$DISK_LIST"

# 网卡链路速率
NIC_SPEED=""
for nic in $(ls /sys/class/net 2>/dev/null | grep -vE '^lo$|docker|veth|br-'); do
    spd=$(ethtool "$nic" 2>/dev/null | awk -F': ' '/Speed/{print $2}' | tr -d '!' | head -1)
    [ -z "$spd" ] || [ "$spd" = "Unknown" ] && spd="未知(虚拟化常态)"
    NIC_SPEED="${NIC_SPEED}${nic}=${spd} "
done
rkv "网卡速率:" "${NIC_SPEED:-N/A}"

# GPU
GPU=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | sed 's/^[^ ]* //')
rkv "GPU:"      "${GPU:-N/A}"

# 关键 sysctl
TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
case "$TCP_CC" in
    bbr|bbr2) CC_RATE=$(rate good "$TCP_CC") ;;
    cubic)    CC_RATE=$(rate fair "$TCP_CC（建议切 BBR）") ;;
    *)        CC_RATE=$(rate info "${TCP_CC:-未知}") ;;
esac
rkv "TCP 拥塞控制:" "$CC_RATE / qdisc=$QDISC"

#######################################
# §3 超开金标准
#######################################
step "§3 超开检测（CPU steal 60s + KSM + Balloon + 内存带宽）"
rsect "§3 资源超开检测"
rpt "目的：判断 CPU、内存是否被宿主机超开。"
rpt "  - CPU steal: 累计/实时被宿主抢走的 CPU 时间占比"
rpt "  - KSM       : 宿主是否在做内存去重（开=可能超开）"
rpt "  - Balloon   : 宿主是否能动态回收 VPS 内存"
rpt "  - 内存带宽  : 同型号 CPU 横向比较，跌幅大=母鸡负载重"

# (a) 累计 steal
read -r _ u n s i io ir sft st _ < /proc/stat
TOTAL=$((u+n+s+i+io+ir+sft+st))
if [ "$TOTAL" -gt 0 ]; then
    CUM_STEAL=$(awk "BEGIN{printf \"%.3f\", $st/$TOTAL*100}")
else
    CUM_STEAL=0
fi
CUM_INT=${CUM_STEAL%.*}
[[ "$CUM_INT" =~ ^[0-9]+$ ]] || CUM_INT=0
if   [ "$CUM_INT" -lt 1 ]; then CS_RATE=$(rate good "${CUM_STEAL}%（自启动以来）")
elif [ "$CUM_INT" -lt 5 ]; then CS_RATE=$(rate fair "${CUM_STEAL}%（自启动以来）")
elif [ "$CUM_INT" -lt 10 ];then CS_RATE=$(rate warn "${CUM_STEAL}%（自启动以来）")
else                            CS_RATE=$(rate bad  "${CUM_STEAL}%（自启动以来）")
fi
rkv "累计 CPU steal:" "$CS_RATE"

# (b) 实时 steal 60s
step "  vmstat 1 60 实时采样..."
VMSTAT_OUT=$(vmstat 1 60 2>/dev/null | tail -n +4)
RT_STEAL_AVG=$(echo "$VMSTAT_OUT" | awk '$1 ~ /^[0-9]+$/ {sum+=$17+0; n++} END{if(n)printf "%.2f", sum/n; else print 0}')
RT_STEAL_MAX=$(echo "$VMSTAT_OUT" | awk 'BEGIN{m=0} $1 ~ /^[0-9]+$/ {if($17+0>m)m=$17+0} END{printf "%d", m}')
RT_CS_AVG=$(echo   "$VMSTAT_OUT" | awk '$1 ~ /^[0-9]+$/ {sum+=$12+0; n++} END{if(n)printf "%.0f", sum/n; else print 0}')
[[ "$RT_STEAL_MAX" =~ ^[0-9]+$ ]] || RT_STEAL_MAX=0

if   [ "$RT_STEAL_MAX" -lt 2 ];  then RT_RATE=$(rate good "均值 ${RT_STEAL_AVG}% 峰值 ${RT_STEAL_MAX}%")
elif [ "$RT_STEAL_MAX" -lt 5 ];  then RT_RATE=$(rate fair "均值 ${RT_STEAL_AVG}% 峰值 ${RT_STEAL_MAX}%")
elif [ "$RT_STEAL_MAX" -lt 10 ]; then RT_RATE=$(rate warn "均值 ${RT_STEAL_AVG}% 峰值 ${RT_STEAL_MAX}%")
else                                  RT_RATE=$(rate bad  "均值 ${RT_STEAL_AVG}% 峰值 ${RT_STEAL_MAX}%")
fi
rkv "实时 CPU steal:" "$RT_RATE"

if   [ "$RT_CS_AVG" -lt 5000 ];  then CS_R=$(rate good "${RT_CS_AVG} cs/s（宿主负载轻）")
elif [ "$RT_CS_AVG" -lt 20000 ]; then CS_R=$(rate fair "${RT_CS_AVG} cs/s")
elif [ "$RT_CS_AVG" -lt 50000 ]; then CS_R=$(rate warn "${RT_CS_AVG} cs/s（宿主多租户密集）")
else                                  CS_R=$(rate bad  "${RT_CS_AVG} cs/s（宿主负载很重）")
fi
rkv "上下文切换:" "$CS_R"

# (c) KSM
KSM_RUN=0; KSM_SHARING=0
if [ -r /sys/kernel/mm/ksm/run ]; then
    KSM_RUN=$(cat /sys/kernel/mm/ksm/run 2>/dev/null)
    KSM_SHARING=$(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null)
fi
if [ "$KSM_RUN" = "1" ]; then
    rkv "KSM 内存去重:" "$(rate warn "已启用，sharing=${KSM_SHARING} 页（宿主在做去重）")"
else
    rkv "KSM 内存去重:" "$(rate good "未启用")"
fi

# (d) Balloon
BALLOON_PCI=$(lspci 2>/dev/null | grep -i balloon | head -1)
if [ -n "$BALLOON_PCI" ]; then
    BAL_INFLATE=$(awk '/balloon_inflate/{print $2}' /proc/vmstat 2>/dev/null)
    if [ "${BAL_INFLATE:-0}" -gt 0 ]; then
        rkv "内存气球:" "$(rate warn "设备存在且 inflate=${BAL_INFLATE}（宿主曾回收内存）")"
    else
        rkv "内存气球:" "$(rate fair "设备存在但未触发（宿主可随时回收）")"
    fi
else
    rkv "内存气球:" "$(rate good "未检测到 balloon 设备")"
fi

# (e) 内存带宽
step "  sysbench memory 5+5s..."
MEM_R_VAL=0; MEM_W_VAL=0
if command -v sysbench >/dev/null 2>&1; then
    MEM_R_RAW=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=read  --time=5 run 2>/dev/null)
    MEM_W_RAW=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=write --time=5 run 2>/dev/null)
    MEM_R_VAL=$(echo "$MEM_R_RAW" | awk '/MiB\/sec/{gsub(/[()]/,""); print $4; exit}')
    MEM_W_VAL=$(echo "$MEM_W_RAW" | awk '/MiB\/sec/{gsub(/[()]/,""); print $4; exit}')
fi
MEM_R_INT=${MEM_R_VAL%.*}
[[ "$MEM_R_INT" =~ ^[0-9]+$ ]] || MEM_R_INT=0
if   [ "$MEM_R_INT" -gt 30000 ]; then MR=$(rate good "${MEM_R_VAL} MiB/s")
elif [ "$MEM_R_INT" -gt 15000 ]; then MR=$(rate ok   "${MEM_R_VAL} MiB/s")
elif [ "$MEM_R_INT" -gt 8000 ];  then MR=$(rate fair "${MEM_R_VAL} MiB/s")
elif [ "$MEM_R_INT" -gt 3000 ];  then MR=$(rate warn "${MEM_R_VAL} MiB/s（疑似母鸡负载重）")
else                                  MR=$(rate bad  "${MEM_R_VAL} MiB/s")
fi
rkv "内存读带宽:" "$MR"
MEM_W_INT=${MEM_W_VAL%.*}
[[ "$MEM_W_INT" =~ ^[0-9]+$ ]] || MEM_W_INT=0
if   [ "$MEM_W_INT" -gt 20000 ]; then MW=$(rate good "${MEM_W_VAL} MiB/s")
elif [ "$MEM_W_INT" -gt 10000 ]; then MW=$(rate ok   "${MEM_W_VAL} MiB/s")
elif [ "$MEM_W_INT" -gt 5000 ];  then MW=$(rate fair "${MEM_W_VAL} MiB/s")
elif [ "$MEM_W_INT" -gt 2000 ];  then MW=$(rate warn "${MEM_W_VAL} MiB/s（疑似宿主负载重）")
else                                  MW=$(rate bad  "${MEM_W_VAL} MiB/s")
fi
rkv "内存写带宽:" "$MW"

#######################################
# §4 邻居与宿主负载
#######################################
step "§4 邻居与宿主负载"
rsect "§4 邻居与宿主负载"
rpt "目的：从网卡丢包、OOM 历史、同 C 段邻居存活率判断宿主机繁忙度。"

# 网卡丢包率
DROP_INFO=""
for nic in $(ls /sys/class/net 2>/dev/null | grep -vE '^lo$|docker|veth|br-'); do
    rxd=$(cat /sys/class/net/$nic/statistics/rx_dropped 2>/dev/null || echo 0)
    rx=$(cat /sys/class/net/$nic/statistics/rx_packets 2>/dev/null || echo 0)
    if [ "$rx" -gt 0 ]; then
        ratio=$(awk "BEGIN{printf \"%.4f\", $rxd/$rx*100}")
    else ratio=0
    fi
    DROP_INFO="${DROP_INFO}${nic}: ${rxd}/${rx} (${ratio}%)  "
done
RX_RATIO_INT=$(echo "$DROP_INFO" | grep -oE '\([0-9]+' | head -1 | tr -d '(')
RX_RATIO_INT=${RX_RATIO_INT:-0}
if   [ "$RX_RATIO_INT" -lt 1 ]; then DR=$(rate good "$DROP_INFO")
elif [ "$RX_RATIO_INT" -lt 5 ]; then DR=$(rate fair "$DROP_INFO")
else                                 DR=$(rate warn "$DROP_INFO（vSwitch 抗压偏弱）")
fi
rkv "网卡丢包:" "$DR"

# OOM 历史
OOM_CNT=$(dmesg 2>/dev/null | grep -iE 'killed process|out of memory' | wc -l)
if [ "$OOM_CNT" -eq 0 ]; then
    rkv "OOM 历史:" "$(rate good "0 次")"
else
    rkv "OOM 历史:" "$(rate warn "${OOM_CNT} 次（内存紧张过）")"
fi

# 同 C 段邻居
MY_IP=$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | grep -v '^127' | head -1 | cut -d/ -f1)
if [ -n "$MY_IP" ]; then
    PREFIX=$(echo "$MY_IP" | cut -d. -f1-3)
    LASTOCT=$(echo "$MY_IP" | cut -d. -f4)
    ALIVE=0; TESTED=0
    for off in 1 33 66 99 132 165 198 231; do
        target="${PREFIX}.${off}"
        [ "$off" = "$LASTOCT" ] && continue
        TESTED=$((TESTED+1))
        ping -c 1 -W 1 "$target" >/dev/null 2>&1 && ALIVE=$((ALIVE+1))
    done
    if   [ "$ALIVE" -ge 6 ]; then NB=$(rate fair "${ALIVE}/${TESTED}（C 段较密集）")
    elif [ "$ALIVE" -ge 3 ]; then NB=$(rate ok   "${ALIVE}/${TESTED}")
    else                          NB=$(rate good "${ALIVE}/${TESTED}（防火墙过滤可能）")
    fi
    rkv "同 C 段存活:" "$NB"
fi

#######################################
# §5 嵌套虚拟化
#######################################
step "§5 嵌套虚拟化能力"
rsect "§5 嵌套虚拟化"
rpt "目的：判断本机能否再开 KVM 虚拟机（vmx/svm 暴露 + /dev/kvm 可用）。"

VMX_CNT=$(grep -cE '(vmx|svm)' /proc/cpuinfo)
if [ "$VMX_CNT" -gt 0 ] && [ -e /dev/kvm ]; then
    NEST_RATE=$(rate good "vmx/svm 在 ${VMX_CNT} 核暴露 + /dev/kvm 可用 → 可嵌套 KVM")
elif [ "$VMX_CNT" -gt 0 ]; then
    NEST_RATE=$(rate fair "CPU 暴露 vmx/svm 但 /dev/kvm 不存在 → 需加载 kvm 模块")
else
    NEST_RATE=$(rate warn "CPU 未暴露 vmx/svm → 仅可跑 QEMU 软件模拟（极慢）")
fi
rkv "嵌套能力:" "$NEST_RATE"

#######################################
# §6 综合等级
#######################################
step "§6 综合等级判定"
rsect "§6 综合等级"
rpt "评级标准:"
rpt "  L4 物理机    : 无虚拟化层"
rpt "  L3 专属母机  : KVM + 无超开 + 嵌套可用"
rpt "  L2 低密共享  : KVM + 资源健康"
rpt "  L1 普通共享  : KVM + 存在超开迹象"
rpt "  L0 容器虚拟  : LXC/OpenVZ"

LEVEL="L1"; LV_DESC=""
if [ "$VIRT" = "none" ]; then
    LEVEL="L4"; LV_DESC="未检测到虚拟化层，疑似真物理机"
elif [ "$VIRT" = "lxc" ] || [ "$VIRT" = "openvz" ] || [ "$VIRT" = "docker" ]; then
    LEVEL="L0"; LV_DESC="容器型虚拟化，与宿主共享内核"
else
    SCORE=0
    [ "$RT_STEAL_MAX" -lt 2 ] && SCORE=$((SCORE+2))
    [ "$KSM_RUN" = "0" ]      && SCORE=$((SCORE+1))
    [ -z "$BALLOON_PCI" ]     && SCORE=$((SCORE+1))
    [ "$VMX_CNT" -gt 0 ]      && SCORE=$((SCORE+1))
    if   [ "$SCORE" -ge 5 ]; then LEVEL="L3"; LV_DESC="资源充足且支持嵌套，疑似专属母机"
    elif [ "$SCORE" -ge 3 ]; then LEVEL="L2"; LV_DESC="低密度共享 KVM，资源健康"
    else                          LEVEL="L1"; LV_DESC="普通共享 KVM，存在超开或资源限制"
    fi
fi
rkv "综合评级:" "$(rate good "${LEVEL} - ${LV_DESC}")"
rline
rpt "  虚拟化:    $VIRT"
rpt "  CPU steal: 累计 ${CUM_STEAL}% / 实时峰值 ${RT_STEAL_MAX}%"
rpt "  KSM:       $([ "$KSM_RUN" = "1" ] && echo 已启用 || echo 未启用)"
rpt "  Balloon:   $([ -n "$BALLOON_PCI" ] && echo 设备存在 || echo 无)"
rpt "  嵌套 KVM:  $([ "$VMX_CNT" -gt 0 ] && [ -e /dev/kvm ] && echo 可用 || echo 不可用)"

#######################################
# §7 三网回程线路
#######################################
step "§7 三网回程探测（约 90 秒）"
rsect "§7 三网回程线路"
rpt "目的：识别到中国电信/联通/移动三网的去程经过哪些 AS（CN2/9929/CMIN2 等）。"
rpt "目标 IP 为各运营商骨干测速节点。"

declare -A ASN_CACHE
lookup_asn() {
    local ip="$1"
    [ -n "${ASN_CACHE[$ip]:-}" ] && { echo "${ASN_CACHE[$ip]}"; return; }
    local r
    r=$(timeout 3 whois -h whois.cymru.com " -v $ip" 2>/dev/null | tail -1 \
        | awk -F'|' '{gsub(/^ +| +$/,"",$1); printf "%s", $1}')
    ASN_CACHE[$ip]="$r"
    echo "$r"
}
asn_tag() {
    case "$1" in
        4809)  echo "CN2(GIA/GT)" ;;
        4134)  echo "电信163" ;;
        9929)  echo "联通9929" ;;
        4837)  echo "联通169" ;;
        10099) echo "联通海外" ;;
        58807) echo "移动CMIN2" ;;
        9808)  echo "移动CMI" ;;
        58453) echo "移动CMI-INT" ;;
        4847)  echo "电信北京" ;;
        4812)  echo "电信上海" ;;
        4808)  echo "联通北京" ;;
        140979) echo "联通上海" ;;
        17816)  echo "联通广东" ;;
        17621)  echo "联通上海" ;;
        17623)  echo "联通广东" ;;
        136958) echo "联通广东" ;;
        56048) echo "移动北京" ;;
        56040) echo "移动广东" ;;
        24400) echo "移动上海" ;;
        17676) echo "Softbank" ;;
        3257)  echo "GTT" ;;
        3356)  echo "Lumen" ;;
        2914)  echo "NTT" ;;
        174)   echo "Cogent" ;;
        6939)  echo "HE.net" ;;
        1299)  echo "Arelion" ;;
        *)     echo "" ;;
    esac
}

declare -A TARGETS=(
    [北京电信]=219.141.140.10
    [北京联通]=202.106.50.1
    [北京移动]=221.179.155.161
    [上海电信]=180.153.28.5
    [上海联通]=210.22.97.1
    [上海移动]=211.136.112.50
    [广州电信]=58.60.188.222
    [广州联通]=210.21.196.6
    [广州移动]=120.196.165.24
)

ROUTE_TBL=""
for label in 北京电信 北京联通 北京移动 上海电信 上海联通 上海移动 广州电信 广州联通 广州移动; do
    target="${TARGETS[$label]}"
    step "  探测 $label ($target)"

    # 目标运营商
    case "$label" in
        *电信*) ISP=tel ;;
        *联通*) ISP=cu  ;;
        *移动*) ISP=cm  ;;
        *)      ISP=unknown ;;
    esac

    # RTT/丢包：用 ICMP ping 5 包（更稳定）；不通则回退用 mtr 的 Avg
    PING_OUT=$(timeout 10 ping -c 5 -W 2 -q "$target" 2>/dev/null)
    PING_LOSS=$(echo "$PING_OUT" | awk -F'[ %]' '/packet loss/{print $6}')
    PING_RTT=$(echo "$PING_OUT" | awk -F'[/ ]' '/rtt|round-trip/{for(i=1;i<=NF;i++) if($i~/^[0-9.]+$/){printf "%.1f", $(i+1); exit}}')
    [ -z "$PING_RTT" ] && PING_RTT=$(echo "$PING_OUT" | awk -F'/' '/rtt|round-trip/{printf "%.1f", $5}')

    # mtr 取路径
    MTR_OUT=$(timeout 30 mtr -n -r -c 5 -T -P 80 "$target" 2>/dev/null)
    [ -z "$MTR_OUT" ] && MTR_OUT=$(timeout 30 mtr -n -r -c 5 "$target" 2>/dev/null)
    log "===== $label $target ====="
    log "$PING_OUT"
    log "$MTR_OUT"

    if [ -z "$MTR_OUT" ] && [ -z "$PING_RTT" ]; then
        ROUTE_TBL="${ROUTE_TBL}${label}|--|失败|未知|$(rate warn "ping/mtr 均不通")"$'\n'
        continue
    fi

    HOPS=$(echo "$MTR_OUT" | awk 'NR>2 && $2 ~ /^[0-9]+\./{print $2}' | head -25)
    LAST_RTT="${PING_RTT:-$(echo "$MTR_OUT" | awk 'NR>2 && $2 ~ /^[0-9]+\./{rtt=$6} END{print rtt}')}"
    LAST_LOSS="${PING_LOSS:-$(echo "$MTR_OUT" | awk 'NR>2 && $2 ~ /^[0-9]+\./{loss=$3} END{print loss}')}"

    # 100% 丢包时 RTT 不可信
    LAST_LOSS="${LAST_LOSS:-0}"
    if [ "${LAST_LOSS%.*}" = "100" ] || [ -z "$LAST_RTT" ]; then
        LAST_RTT_DISP="N/A"
        RTT_INT=999
    else
        # 规整数字格式（去尾点）
        LAST_RTT="${LAST_RTT%.}"
        LAST_RTT_DISP="${LAST_RTT}ms"
        RTT_INT=${LAST_RTT%.*}
        [[ "$RTT_INT" =~ ^[0-9]+$ ]] || RTT_INT=999
    fi

    AS_PATH=""; LAST_ASN=""
    TEL_TAG=""; CU_TAG=""; CM_TAG=""; OTHER_TAG=""
    while IFS= read -r hopip; do
        [ -z "$hopip" ] && continue
        case "$hopip" in
            10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) continue ;;
        esac
        asn=$(lookup_asn "$hopip")
        [ -z "$asn" ] || [ "$asn" = "NA" ] && continue
        if [ "$asn" != "$LAST_ASN" ]; then
            AS_PATH="${AS_PATH}AS${asn}→"
            # 按运营商分桶；优质线路抢占优先级
            case "$asn" in
                4809)  TEL_TAG="CN2(GIA)" ;;
                4134)  [ "$TEL_TAG" != "CN2(GIA)" ] && TEL_TAG="电信163" ;;
                9929)  CU_TAG="联通9929" ;;
                4837)  [ "$CU_TAG" != "联通9929" ] && CU_TAG="联通169" ;;
                10099) [ -z "$CU_TAG" ] && CU_TAG="联通海外" ;;
                58807) CM_TAG="移动CMIN2" ;;
                58453) [ "$CM_TAG" != "移动CMIN2" ] && CM_TAG="移动CMI国际" ;;
                9808)  [ -z "$CM_TAG" ] && CM_TAG="移动CMI" ;;
                3257)  [ -z "$OTHER_TAG" ] && OTHER_TAG="GTT" ;;
                3356)  [ -z "$OTHER_TAG" ] && OTHER_TAG="Lumen" ;;
                2914)  [ -z "$OTHER_TAG" ] && OTHER_TAG="NTT" ;;
                174)   [ -z "$OTHER_TAG" ] && OTHER_TAG="Cogent" ;;
                17676) [ -z "$OTHER_TAG" ] && OTHER_TAG="Softbank" ;;
            esac
            LAST_ASN="$asn"
        fi
    done <<< "$HOPS"
    AS_PATH="${AS_PATH%→}"

    # 按目标运营商优选标签；不匹配则标"绕XX"
    case "$ISP" in
        tel)
            if   [ -n "$TEL_TAG" ]; then KEY_TAG="$TEL_TAG"
            elif [ -n "$CU_TAG" ];  then KEY_TAG="绕${CU_TAG}"
            elif [ -n "$CM_TAG" ];  then KEY_TAG="绕${CM_TAG}"
            else KEY_TAG="${OTHER_TAG:-未识别}"
            fi ;;
        cu)
            if   [ -n "$CU_TAG" ];  then KEY_TAG="$CU_TAG"
            elif [ -n "$TEL_TAG" ]; then KEY_TAG="绕${TEL_TAG}"
            elif [ -n "$CM_TAG" ];  then KEY_TAG="绕${CM_TAG}"
            else KEY_TAG="${OTHER_TAG:-未识别}"
            fi ;;
        cm)
            if   [ -n "$CM_TAG" ];  then KEY_TAG="$CM_TAG"
            elif [ -n "$CU_TAG" ];  then KEY_TAG="绕${CU_TAG}"
            elif [ -n "$TEL_TAG" ]; then KEY_TAG="绕${TEL_TAG}"
            else KEY_TAG="${OTHER_TAG:-未识别}"
            fi ;;
        *)  KEY_TAG="${OTHER_TAG:-未识别}" ;;
    esac

    # 延迟评级
    if   [ "$RTT_INT" -ge 999 ];  then RTT_RATE="🔴" RTT_TEXT="不通"
    elif [ "$RTT_INT" -lt 100 ]; then RTT_RATE="🟢" RTT_TEXT="良好"
    elif [ "$RTT_INT" -lt 180 ]; then RTT_RATE="🟢" RTT_TEXT="正常"
    elif [ "$RTT_INT" -lt 250 ]; then RTT_RATE="🟡" RTT_TEXT="一般"
    elif [ "$RTT_INT" -lt 350 ]; then RTT_RATE="🟠" RTT_TEXT="偏弱"
    else                              RTT_RATE="🔴" RTT_TEXT="较差"
    fi

    ROUTE_TBL="${ROUTE_TBL}${label}|${LAST_RTT_DISP} ${RTT_RATE} ${RTT_TEXT}|丢包${LAST_LOSS}%|${KEY_TAG}|${AS_PATH}"$'\n'
done

# 打印路由汇总（单行显眼）
rline
printf "%-10s %-22s %-12s %-12s %s\n" "目标" "RTT" "丢包" "线路类型" "AS路径" >> "$RPT_FILE"
rline
echo "$ROUTE_TBL" | awk -F'|' 'NF>=5{printf "%-10s %-22s %-12s %-12s %s\n", $1, $2, $3, $4, $5}' >> "$RPT_FILE"

#######################################
# §8 磁盘性能
#######################################
step "§8 磁盘 fio（4 维 × 5s × 读写）"
rsect "§8 磁盘性能"
rpt "目的：测量随机/顺序读写吞吐与 IOPS。"

run_fio() {
    local name=$1 bs=$2 iod=$3 rw=$4
    fio --name="$name" --filename=test.fio --size=512M --bs="$bs" \
        --iodepth="$iod" --rw="$rw" --direct=1 --runtime=5 --time_based \
        --group_reporting 2>/dev/null \
      | awk -v rw="$rw" '
            /IOPS=/ {
                match($0, /IOPS=[0-9.kM]+/);  iops=substr($0, RSTART+5, RLENGTH-5)
                match($0, /BW=[0-9.]+[KMG]iB/); bw=substr($0, RSTART+3, RLENGTH-3)
                printf "%s|%s", iops, bw; exit
            }'
}
fio_eval() {
    # $1=测试名 $2="iops|bw" 评级阈值矩阵
    local name=$1 raw=$2
    local iops=${raw%%|*} bw=${raw##*|}
    local iops_n=$(echo "$iops" | sed 's/k/000/;s/M/000000/;s/\..*//')
    [[ "$iops_n" =~ ^[0-9]+$ ]] || iops_n=0
    local r=""
    case "$name" in
        rnd4k_q1)   [ $iops_n -gt 5000 ] && r=good || { [ $iops_n -gt 1000 ] && r=ok || { [ $iops_n -gt 300 ] && r=fair || r=warn; }; } ;;
        rnd4k_q32)  [ $iops_n -gt 30000 ] && r=good || { [ $iops_n -gt 8000 ] && r=ok || { [ $iops_n -gt 2000 ] && r=fair || r=warn; }; } ;;
        seq1m)      [ $iops_n -gt 800 ] && r=good || { [ $iops_n -gt 300 ] && r=ok || { [ $iops_n -gt 100 ] && r=fair || r=warn; }; } ;;
    esac
    rate "$r" "IOPS=${iops}  BW=${bw}"
}

if command -v fio >/dev/null 2>&1; then
    FIO_DIR=$(mktemp -d)
    cd "$FIO_DIR" || true
    for mode in "rnd4k_q1:4k:1" "rnd4k_q32:4k:32" "seq1m:1M:8"; do
        IFS=: read -r tname bs iod <<< "$mode"
        for op in read write; do
            res=$(run_fio "${tname}_${op}" "$bs" "$iod" "${op%write}${op}")
            # 修正 rw 名: read/randread/write/randwrite
            case "$tname" in
                rnd*)   rw="rand${op}" ;;
                seq*)   rw="${op}" ;;
            esac
            res=$(run_fio "${tname}_${op}" "$bs" "$iod" "$rw")
            label=$(echo "$tname" | sed 's/rnd4k_q1/随机4K Q1/; s/rnd4k_q32/随机4K Q32/; s/seq1m/顺序1M Q8/')
            opname=$([ "$op" = "read" ] && echo "读" || echo "写")
            rkv "${label} ${opname}:" "$(fio_eval "$tname" "$res")"
        done
    done
    rm -f test.fio
    cd - >/dev/null
    rmdir "$FIO_DIR" 2>/dev/null
else
    rkv "fio:" "$(rate warn "未安装")"
fi

#######################################
# §9 网络身份与解锁
#######################################
step "§9 IP 身份 / 黑名单 / AI 与流媒体解锁"
rsect "§9 网络身份"
rpt "目的：核查公网 IP 归属、25 端口、反向 DNS、Spamhaus 黑名单。"

PUB4=$(timeout 5 curl -fsS -4 ip.sb 2>/dev/null || timeout 5 curl -fsS -4 ifconfig.me 2>/dev/null)
PUB6=$(timeout 5 curl -fsS -6 ip.sb 2>/dev/null)
rkv "公网 IPv4:" "${PUB4:-N/A}"
rkv "公网 IPv6:" "${PUB6:-未配置}"

if [ -n "$PUB4" ]; then
    CYMRU=$(timeout 5 whois -h whois.cymru.com " -v $PUB4" 2>/dev/null | tail -1)
    ASN_NUM=$(echo "$CYMRU" | awk -F'|' '{gsub(/ /,"",$1); print $1}')
    PREFIX_CIDR=$(echo "$CYMRU" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
    COUNTRY=$(echo "$CYMRU" | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}')
    AS_NAME=$(echo "$CYMRU"  | awk -F'|' '{gsub(/^ +| +$/,"",$7); print $7}')
    rkv "ASN:"    "AS${ASN_NUM} ${AS_NAME}"
    rkv "Prefix:" "${PREFIX_CIDR}  [${COUNTRY}]"

    rdns=$(timeout 3 dig -x "$PUB4" +short 2>/dev/null | head -1)
    [ -n "$rdns" ] && rkv "反向 DNS:" "$(rate info "$rdns")" \
                  || rkv "反向 DNS:" "$(rate fair "未设置")"

    if timeout 5 bash -c "echo > /dev/tcp/smtp.gmail.com/25" 2>/dev/null; then
        rkv "25 端口出站:" "$(rate good "可达（可发邮件）")"
    else
        rkv "25 端口出站:" "$(rate fair "被阻断（云厂商常态）")"
    fi

    REV=$(echo "$PUB4" | awk -F. '{print $4"."$3"."$2"."$1}')
    sh_r=$(timeout 5 dig +short "${REV}.zen.spamhaus.org" 2>/dev/null)
    if echo "$sh_r" | grep -qE '^127\.0\.0\.[0-9]+$'; then
        rkv "Spamhaus 黑名单:" "$(rate bad "已列入: $(echo $sh_r | tr '\n' ' ')")"
    elif [ -n "$sh_r" ]; then
        rkv "Spamhaus 黑名单:" "$(rate fair "异常返回（DNS 限速/过滤，非真黑名单）")"
    else
        rkv "Spamhaus 黑名单:" "$(rate good "未列入")"
    fi
fi

# 解锁探测
rsect "§10 流媒体与 AI 平台可达性"
rpt "目的：HTTP 状态码 + 标志关键字快速判断常见服务能否访问。"
rpt "（200=正常返回，403/451=区域阻断，fail=连接失败；不等同于完整解锁）"

probe() {
    local name="${1:-}" url="${2:-}" expect_grep="${3:-}"
    local code body rate_kw
    body=$(timeout 8 curl -fsSL -o /dev/null --max-time 7 \
        -w "%{http_code}" -A "Mozilla/5.0" "$url" 2>/dev/null)
    code="$body"
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        rkv "$name:" "$(rate bad "连接失败")"
        return
    fi
    case "$code" in
        2*) rkv "$name:" "$(rate good "HTTP $code 可达")" ;;
        4*|5*) rkv "$name:" "$(rate warn "HTTP $code 受限")" ;;
        3*) rkv "$name:" "$(rate ok "HTTP $code 重定向")" ;;
        *)  rkv "$name:" "$(rate fair "HTTP $code")" ;;
    esac
}

rline
rpt "AI 平台:"
# Cloudflare 前置的 AI 站点统一用 /cdn-cgi/trace（避开 WAF/Bot 防御误判）
probe "ChatGPT (OpenAI)"   "https://chat.openai.com/cdn-cgi/trace"
probe "Claude (Anthropic)" "https://claude.ai/cdn-cgi/trace"
probe "Gemini (Google)"    "https://gemini.google.com/"
probe "Perplexity"         "https://www.perplexity.ai/cdn-cgi/trace"
probe "Copilot (Microsoft)" "https://copilot.microsoft.com/cdn-cgi/trace"
probe "Mistral"            "https://chat.mistral.ai/cdn-cgi/trace"
probe "Grok (xAI)"         "https://grok.com/cdn-cgi/trace"
probe "DeepSeek"           "https://chat.deepseek.com/"
probe "Kimi (Moonshot)"    "https://kimi.moonshot.cn/"

rline
rpt "流媒体:"
probe "Netflix"      "https://www.netflix.com/title/81280792"
probe "Disney+"      "https://www.disneyplus.com/"
probe "YouTube"      "https://www.youtube.com/premium"
probe "TikTok"       "https://www.tiktok.com/"
probe "Spotify"      "https://www.spotify.com/"
probe "HBO Max"      "https://www.max.com/"
probe "Twitch"       "https://www.twitch.tv/"

#######################################
# §11 中国多地三网入境延迟（globalping API）
#######################################
step "§11 globalping 多省三网入境延迟（约 15 秒）"
rsect "§11 中国多地三网入境延迟（globalping）"
rpt "目的：从中国大陆各省 + 三网真实节点 ping 本机，模拟国内用户访问体验。"
rpt "数据源：globalping.io 公开探针（无需认证，250 次/小时配额）"

if [ -z "${PUB4:-}" ]; then
    rkv "globalping:" "$(rate fair "未取到公网 IP，跳过")"
elif ! command -v jq >/dev/null 2>&1; then
    apt-get install -y -qq jq >>"$LOG_FILE" 2>&1
fi

if [ -n "${PUB4:-}" ] && command -v jq >/dev/null 2>&1; then
    GP_API="https://api.globalping.io/v1/measurements"

    # 提交 CN 探针 ping，按 ASN 后处理分类电信/联通/移动/其他
    payload=$(jq -n --arg t "$PUB4" '{
        type:"ping", target:$t, limit:50,
        locations:[{country:"CN"}],
        measurementOptions:{packets:4}
    }')
    step "  提交 CN 探针 ping (limit=50)..."
    mid=$(curl -sS -X POST -H 'Content-Type: application/json' \
          --max-time 10 -d "$payload" "$GP_API" 2>/dev/null \
          | jq -r '.id // empty')

    if [ -z "$mid" ]; then
        rkv "globalping:" "$(rate warn "API 提交失败（检查网络/配额）")"
    else
        for _ in $(seq 1 20); do
            sleep 2
            status=$(curl -sS --max-time 6 "${GP_API}/${mid}" 2>/dev/null | jq -r '.status // empty')
            [ "$status" = "finished" ] && break
        done
        results=$(curl -sS --max-time 8 "${GP_API}/${mid}" 2>/dev/null)
        log "===== globalping CN ====="
        log "$results"

        # 解析为 city|asn|network|avg|loss
        rows=$(echo "$results" | jq -r '
            .results[] |
            "\(.probe.city // "?")|\(.probe.asn // 0)|\(.probe.network // "?")|\(.result.stats.avg // 0)|\(.result.stats.loss // 0)"
        ' 2>/dev/null)

        if [ -z "$rows" ]; then
            rkv "globalping:" "$(rate warn "无 CN 探针返回")"
        else
            classify_isp() {
                # 按 ASN 分类三网；其他归"其他"
                case "$1" in
                    4134|4812|4847|4811|17897|23650|23724|58563|58594|140330|17638) echo tel ;;
                    4837|4808|9929|17621|17816|17623|136958|140979) echo cu ;;
                    9808|56040|56048|24400|24444|24445|56041|9394) echo cm ;;
                    *) echo other ;;
                esac
            }
            isp_label() {
                case "$1" in
                    tel) echo "中国电信" ;;
                    cu)  echo "中国联通" ;;
                    cm)  echo "中国移动" ;;
                    *)   echo "其他/云" ;;
                esac
            }

            # 表头
            rpt ""
            printf "%-12s %-18s %-30s %-14s %s\n" \
                "运营商" "城市" "网络" "平均RTT" "丢包" >> "$RPT_FILE"
            rline

            declare -A SUM_AVG SUM_N
            declare -a ROW_BUFFER
            DROPPED=0
            while IFS='|' read -r city asn net rtt loss; do
                [ -z "$city" ] && continue
                # 跳过未返回有效 RTT 的探针（探测超时/丢包 100%）
                if [ -z "$rtt" ] || [ "$rtt" = "null" ] || [ "$rtt" = "0" ]; then
                    DROPPED=$((DROPPED+1))
                    continue
                fi
                isp=$(classify_isp "$asn")
                isp_cn=$(isp_label "$isp")
                rtt_int=${rtt%.*}
                [[ "$rtt_int" =~ ^[0-9]+$ ]] || rtt_int=0
                mark="🟢"
                [ "$rtt_int" -gt 80 ]  && mark="🟢"
                [ "$rtt_int" -gt 150 ] && mark="🟡"
                [ "$rtt_int" -gt 250 ] && mark="🟠"
                [ "$rtt_int" -gt 350 ] && mark="🔴"
                ROW_BUFFER+=("$(printf '%-12s %-18s %-30s %-14s %s' \
                    "$isp_cn" "$city" "$(echo "$net" | cut -c1-28)" \
                    "$(printf '%.1fms %s' "$rtt" "$mark")" "${loss}%")")
                SUM_AVG[$isp]=$(awk "BEGIN{printf \"%.2f\", ${SUM_AVG[$isp]:-0} + $rtt}")
                SUM_N[$isp]=$((${SUM_N[$isp]:-0}+1))
            done <<< "$rows"

            # 按运营商分组排序输出
            for isp in tel cu cm other; do
                for line in "${ROW_BUFFER[@]}"; do
                    case "$(isp_label $isp)" in
                        中国电信) [[ "$line" == 中国电信* ]] && echo "$line" >> "$RPT_FILE" ;;
                        中国联通) [[ "$line" == 中国联通* ]] && echo "$line" >> "$RPT_FILE" ;;
                        中国移动) [[ "$line" == 中国移动* ]] && echo "$line" >> "$RPT_FILE" ;;
                        其他/云) [[ "$line" == 其他/云* ]] && echo "$line" >> "$RPT_FILE" ;;
                    esac
                done
            done
            rline

            # 三网均值评级
            rpt "三网均值小结："
            for isp in tel cu cm other; do
                n=${SUM_N[$isp]:-0}
                [ "$n" -eq 0 ] && continue
                avg=$(awk "BEGIN{printf \"%.1f\", ${SUM_AVG[$isp]}/$n}")
                avg_int=${avg%.*}
                r=good
                [ "$avg_int" -gt 150 ] && r=fair
                [ "$avg_int" -gt 250 ] && r=warn
                [ "$avg_int" -gt 400 ] && r=bad
                rkv "$(isp_label $isp):" "$(rate $r "${avg} ms（${n} 探针）")"
            done
            [ "${DROPPED:-0}" -gt 0 ] && rpt "（已跳过 ${DROPPED} 个未返回有效 RTT 的探针）"
        fi
    fi
else
    rkv "globalping:" "$(rate fair "jq 未就绪，跳过本节")"
fi

#######################################
# 收尾：把报告 cat 到屏幕
#######################################
rsect "报告完成"
rkv "脚本版本:" "$VERSION"
rkv "结束时间:" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
rkv "报告文件:" "$RPT_FILE"
rkv "详细日志:" "$LOG_FILE"
rkv "HTML 报告:" "$HTML_FILE"

step "§* 全部完成，输出报告"
echo ""
echo ""
cat "$RPT_FILE"

#######################################
# §* HTML 报告（带颜色高亮 + 一键复制纯文本）
#######################################
# 设计要点（重要）：
#   1. 报告内容只做一次 HTML 实体转义后写入 hidden <pre id="report-raw">；
#      不向其中插入任何 <span> / 样式 —— 这是「复制按钮」的纯文本来源。
#   2. JS 在浏览器里读 #report-raw 的 textContent，按行染色后写入可见 <pre id="report-rendered">。
#   3. 所以「显示彩色」和「复制纯文本」用的是两份相互独立的 DOM 节点，互不污染。

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

cat > "$HTML_FILE" <<HTML_HEAD
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VPS Check Report - ${HOST_TAG} - ${TS}</title>
<style>
  :root{
    --bg:#1e1e1e; --fg:#d4d4d4; --muted:#808080; --sep:#444;
    --good:#4ec9b0; --fair:#dcdcaa; --warn:#ce9178; --bad:#f48771;
    --info:#9cdcfe; --section:#c586c0; --kv:#569cd6;
  }
  *{box-sizing:border-box}
  body{margin:0;padding:24px;background:var(--bg);color:var(--fg);
    font-family:'Cascadia Mono','JetBrains Mono','Fira Code',Menlo,Consolas,'Courier New',monospace;
    font-size:14px;line-height:1.55}
  .wrap{max-width:1100px;margin:0 auto}
  header{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;
    padding-bottom:14px;border-bottom:1px solid var(--sep);margin-bottom:14px}
  header h1{margin:0;font-size:18px;font-weight:600}
  header .meta{color:var(--muted);font-size:12px}
  .toolbar{display:flex;gap:8px;margin:14px 0}
  button{background:#2d2d2d;color:var(--fg);border:1px solid var(--sep);
    padding:6px 14px;border-radius:4px;cursor:pointer;font:inherit}
  button:hover{background:#3a3a3a;border-color:#666}
  button.copied{background:#1f3d2c;border-color:var(--good);color:var(--good)}
  pre.report{background:#1e1e1e;padding:16px;border-radius:6px;border:1px solid var(--sep);
    white-space:pre;overflow-x:auto;margin:0;font-family:inherit;font-size:inherit;line-height:inherit}
  pre#report-raw{display:none}
  .ln-section{color:var(--section);font-weight:600}
  .ln-sep{color:var(--sep)}
  .seg-good{color:var(--good)}
  .seg-fair{color:var(--fair)}
  .seg-warn{color:var(--warn)}
  .seg-bad{color:var(--bad)}
  .seg-info{color:var(--info)}
  .seg-key{color:var(--kv)}
  footer{margin-top:24px;padding-top:14px;border-top:1px solid var(--sep);
    color:var(--muted);font-size:12px;text-align:center}
  footer a{color:var(--info);text-decoration:none}
  footer a:hover{text-decoration:underline}
  @media print{body{background:#fff;color:#000}pre.report{border:1px solid #ccc;background:#fff;color:#000}
    .toolbar{display:none}}
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1 id="title">VPS Quality Check Report</h1>
    <div class="meta" id="meta"></div>
  </header>
  <div class="toolbar">
    <button id="btn-copy" type="button">📋 复制报告内容</button>
    <button type="button" onclick="window.print()">🖨️ 打印 / 保存 PDF</button>
  </div>
  <pre id="report-raw" class="report">
HTML_HEAD

# 把 .txt 报告 HTML 实体转义后追加到 hidden <pre>。绝不插入任何样式标签。
html_escape < "$RPT_FILE" >> "$HTML_FILE"

cat >> "$HTML_FILE" <<'HTML_TAIL'
</pre>
  <pre id="report-rendered" class="report"></pre>
  <footer>
    Powered by <a href="https://github.com/AiCarrox/carrox-vps-check" target="_blank" rel="noopener">carrox-vps-check</a>
    · 单文件 bash · MIT License
  </footer>
</div>
<script>
(function () {
  // 去掉因 heredoc 排版引入的首尾空行
  var raw = document.getElementById('report-raw').textContent
    .replace(/^\n+/, '').replace(/\n+$/, '\n');

  // 提取 meta 显示在页眉
  var hostM = raw.match(/主机\s*[:：]\s*(.+)/);
  var timeM = raw.match(/报告时间\s*[:：]\s*(.+)/);
  var verM  = raw.match(/VPS Quality Check Report\s+(v[0-9.]+)/);
  if (verM) document.getElementById('title').textContent = 'VPS Quality Check Report ' + verM[1];
  var parts = [];
  if (hostM) parts.push('主机: ' + hostM[1].trim());
  if (timeM) parts.push(timeM[1].trim());
  document.getElementById('meta').textContent = parts.join(' · ');

  function escapeHtml(s) {
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  // 行级着色：先判分隔/标题，再按行内评级整行上色
  function colorize(line) {
    if (line === '') return '';
    if (/^[#=]{8,}$/.test(line)) return '<span class="ln-sep">' + escapeHtml(line) + '</span>';
    if (/^-{8,}$/.test(line))    return '<span class="ln-sep">' + escapeHtml(line) + '</span>';
    if (/^§\d/.test(line) || /^\s+VPS Quality Check Report/.test(line)) {
      return '<span class="ln-section">' + escapeHtml(line) + '</span>';
    }
    var cls = null;
    if (/\[🟢/.test(line))       cls = 'seg-good';
    else if (/\[🟡/.test(line))  cls = 'seg-fair';
    else if (/\[🟠/.test(line))  cls = 'seg-warn';
    else if (/\[🔴/.test(line))  cls = 'seg-bad';
    else if (/\[ℹ/.test(line))   cls = 'seg-info';
    var safe = escapeHtml(line);
    if (cls) return '<span class="' + cls + '">' + safe + '</span>';
    // 无评级行：把 KV key 染成蓝色（左对齐 22 字符 + 冒号）
    safe = safe.replace(/^(\s*[^\s:：][^:：]{0,40}?[:：])(\s)/, function (_, k, sp) {
      return '<span class="seg-key">' + k + '</span>' + sp;
    });
    return safe;
  }

  document.getElementById('report-rendered').innerHTML =
    raw.split('\n').map(colorize).join('\n');

  // 复制按钮：直接读 #report-raw.textContent —— 干净纯文本
  var btn = document.getElementById('btn-copy');
  function flash() {
    btn.textContent = '✓ 已复制';
    btn.classList.add('copied');
    setTimeout(function () {
      btn.textContent = '📋 复制报告内容';
      btn.classList.remove('copied');
    }, 2000);
  }
  function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed'; ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) {}
    document.body.removeChild(ta);
    if (ok) flash(); else alert('复制失败，请手动选择文本（Ctrl+A / Ctrl+C）');
  }
  btn.addEventListener('click', function () {
    var text = document.getElementById('report-raw').textContent
      .replace(/^\n+/, '').replace(/\n+$/, '\n');
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(flash, function () { fallbackCopy(text); });
    } else {
      fallbackCopy(text);
    }
  });
})();
</script>
</body>
</html>
HTML_TAIL

echo ""
echo "  📄 文本报告: $RPT_FILE"
echo "  🌐 HTML 报告: $HTML_FILE"
echo "  📋 详细日志: $LOG_FILE"
