#!/usr/bin/env bash
# gpu-run.sh — GPU 任务统一入口。单卡场景下用它把任务串起来，避免两个人同时抢卡。
#
# 用法：
#   ./gpu-run.sh --note "跑 qwen2.5-7b 评测，约 1h" -- python eval.py
#   ./gpu-run.sh -- python train.py            # note 可省略
#
# 行为：
#   - 卡空 → 立刻执行，并登记"谁 / 什么任务 / 何时开始"
#   - 卡忙 → 打印当前持有者，阻塞排队，拿到锁后自动开始
#   - 退出（正常/异常/Ctrl+C）→ 自动释放锁与登记
#
# 可用环境变量：
#   VOLTA_LOCK  锁文件路径，默认 /tmp/volta-gpu.lock
#   VOLTA_LOG   使用记录，默认 /tmp/volta-gpu-usage.log
set -euo pipefail

LOCK="${VOLTA_LOCK:-/tmp/volta-gpu.lock}"
INFO="${LOCK}.owner"
LOG="${VOLTA_LOG:-/tmp/volta-gpu-usage.log}"

note=""
if [ "${1:-}" = "--note" ]; then
    note="${2:-}"
    shift 2 || true
fi
[ "${1:-}" = "--" ] && shift

if [ $# -eq 0 ]; then
    echo "用法: $(basename "$0") [--note \"说明\"] -- <命令> [参数...]" >&2
    exit 2
fi

# flock 来自 util-linux，绝大多数发行版自带；万一没有（极简镜像/busybox），
# 退化为直接执行，至少别让脚本卡在一个看不懂的报错上。
if ! command -v flock >/dev/null 2>&1; then
    echo "[gpu-run] 警告：系统缺少 flock（util-linux），无法串行排队，直接执行。" >&2
    echo "[gpu-run] 请让管理员安装：apt install util-linux" >&2
    exec "$@"
fi

exec 9>"$LOCK"

if ! flock -n 9; then
    echo "[gpu-run] GPU 已被占用，进入排队。当前持有者："
    if [ -s "$INFO" ]; then
        sed 's/^/          /' "$INFO"
    else
        echo "          (无登记信息，可能是别人直接用 flock 或根本没走本脚本)"
    fi
    echo "[gpu-run] 等待中…（Ctrl+C 可放弃排队）"
    started_wait=$SECONDS
    flock 9
    echo "[gpu-run] 已拿到卡，等待了 $((SECONDS - started_wait)) 秒。"
fi

record="$(printf '%-10s %-14s %s  %s' \
    "$(whoami)" "$(hostname)" "$(date '+%F %T')" "${note:-无说明}")"
printf '%s  cmd=%s\n' "$record" "$*" | tee -a "$LOG" >"$INFO"

cleanup() {
    rm -f "$INFO"
}
trap cleanup EXIT INT TERM

echo "[gpu-run] 开始: $*"
echo "[gpu-run] 提醒: 显存是 16G 共享的，记得设 CUDA_VISIBLE_DEVICES=0 并控住用量。"
echo

set +e
"$@"
rc=$?
set -e

echo
if [ "$rc" -ne 0 ]; then
    echo "[gpu-run] 命令退出码 $rc。若怀疑显存泄漏，运行 ./gpu-who.sh 确认没有残留进程。"
else
    echo "[gpu-run] 完成。"
fi
exit "$rc"
