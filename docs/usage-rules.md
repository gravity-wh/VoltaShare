# 共用约定（贴群里那份）

机器：X99 + E5-2698B v3 + **1× Tesla V100 16GB**。
只有一张卡，16G 显存。请先读完再动手。

---

## 一、账号

1. **一人一个 Linux 账号**，不共用，不把密码给别人。
2. **禁止 `sudo` 装系统包**。需要装驱动、装 apt 包，先在群里说，由管理员统一操作。
3. 自己的东西放自己家目录。共享模型/数据集在 `/srv/share`，**只读**，不要往里写。

## 二、环境

4. **各自装自己的 conda**（`~/miniconda3`），不要用全局 Python，不要在系统 Python 里 `pip install`。
5. **禁止 `pip install --upgrade` / `pip install -U torch`**。这条是硬红线：一次升级能把所有人的 vLLM 一起搞死。
6. 这台机器的卡是 **V100（SM70）**，很多新库已经不支持它：
   - FlashAttention 2/3 → 用不了（需 SM80+）
   - bf16 → 没有原生支持，用 fp16
   - AWQ → 大概率起不来（需 SM75+）
   装东西前先想一下"这库还支不支持 Volta"，装不上不是环境坏了，是卡太老。

## 三、GPU（最重要）

7. **只有一张卡，必须串行**。跑任何吃 GPU 的任务，都用：
   ```bash
   ./scripts/gpu-run.sh --note "干什么，预计多久" -- python xxx.py
   ```
   抢不到就自动排队，会告诉你现在是谁在跑。**不要绕过它直接跑。**
8. **代码里显式写死卡号**：
   ```bash
   CUDA_VISIBLE_DEVICES=0 python xxx.py
   ```
   不要写"自动找空闲卡"的逻辑，也不要 `device_map="auto"` 放任它吃满显存。
9. **显存自己控住**。16G 是共享的，不要一上来就把 90% 吃干：
   ```python
   torch.cuda.set_per_process_memory_fraction(0.6, 0)   # 最多用 ~9.6G
   ```
10. **跑之前先看**：`./scripts/gpu-who.sh`。看到有人在跑还硬上，两个人的任务一起 OOM。

## 四、后台任务

11. **一律 tmux**：
    ```bash
    tmux new -s 你的名字      # 建
    # Ctrl+B 然后 D  → 断开但进程继续
    tmux attach -t 你的名字   # 回来
    ```
12. **跑完主动退出**。`Ctrl+C` 之外还要确认 `nvidia-smi` 里没有你的进程残留。
    发现别人的孤儿进程，先在群里问一句，别直接 kill。
13. 长任务自己记一下预计结束时间，超时要主动说。

## 五、端口

14. 按人分段，别用默认端口：

    | 谁 | 端口段 |
    |---|---|
    | stu1 | 8000–8099 |
    | stu2 | 8100–8199 |
    | stu3 | 8200–8299 |

    ```bash
    python -m vllm.entrypoints.openai.api_server --port 8000 ...
    ```

## 六、常驻服务要登记

15. vLLM / ollama 这类**长期占卡**的服务，必须在群里登记这四项：

    | 谁 | 模型 | 端口 | 预计结束 |
    |---|---|---|---|
    | stu1 | qwen2.5-7b-int4 | 8000 | 长期 |

    没登记就悄悄挂着霸卡，是最容易吵起来的事。

## 七、心理预期（提前对齐，别到时候互相怪）

16. **容器、conda、多账号都隔离不了 GPU 驱动。**
    任何人跑崩驱动 / 触发 GPU reset / 把机器跑挂，**所有人的任务会一起断**。
    这不是谁的配置没弄好，是单机 NVIDIA GPU 的固有缺陷。
17. 万一整机挂了：不要慌着互相甩锅，先看 `dmesg | tail -50` 有没有 `Xid` 报错，把日志留好再重启。

---

## 附：常用命令

```bash
./scripts/gpu-who.sh                     # 谁在占卡
./scripts/gpu-run.sh --note "..." -- ...  # 排队跑 GPU 任务
nvidia-smi                               # 基础查看
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv
tmux ls                                  # 我有哪些会话
```
