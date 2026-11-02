#!/usr/bin/env bash
# gpu-who.sh — 只读。查看当前谁在占 GPU、占多少显存、跑了多久。
# 优先用 gpustat，没有则退回 nvidia-smi + ps。
set -u

if command -v gpustat >/dev/null 2>&1; then
    gpustat -cp --color
    echo
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "找不到 nvidia-smi：驱动没装好，或者 V100 没被识别。" >&2
    exit 1
fi

echo "== GPU 概览 =="
nvidia-smi \
    --query-gpu=index,name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu \
    --format=csv

echo
echo "== 占用进程 =="
pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | tr -d ' ')
if [ -z "$pids" ]; then
    echo "（当前没有进程占用 GPU）"
    exit 0
fi

printf '%-8s %-10s %-9s %-10s %s\n' PID USER 显存 已运行 命令
for pid in $pids; do
    [ -z "$pid" ] && continue
    user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
    etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    mem=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader 2>/dev/null \
          | awk -F', *' -v p="$pid" '$1==p {print $2}')
    cmd=$(ps -o args= -p "$pid" 2>/dev/null | cut -c1-100)
    printf '%-8s %-10s %-9s %-10s %s\n' \
        "$pid" "${user:-?}" "${mem:-?}" "${etime:-?}" "${cmd:-?}"
done

echo
echo "提示：某个 PID 的 USER 为空或命令是 python 但没人认领，多半是 SSH 断开后的孤儿进程。"
echo "      先在群里问一句，别直接 kill —— 可能是别人的常驻推理服务。"
