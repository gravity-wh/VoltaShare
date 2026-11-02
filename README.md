# VoltaShare

一台 **X99 + Xeon E5-2698B v3 + 1× Tesla V100 16GB** 的 Linux 单机，几个人同学共用。
这个仓库放的是**共用约定 + 解决冲突的脚本**，不存放代码和数据。

> **当前真实状态（2026-11-02）**
> 只买到 **1 张 V100 16GB（PCIe，SM70）**。原计划里的 3060 **还没买**，所以本文档里所有"cuda:0 / cuda:1 分卡"的方案**全部作废**，改用单卡时分复用。

---

## 0. 一句话结论

单卡 16G 没有硬件切分手段，能做的只有两件事：

1. **时间上排队**（串行锁 + 预约），不让人同时抢同一块卡；
2. **环境上隔离**（每人一个 Linux 账号 + 各自 conda/容器），不让 `pip install -U` 互相炸。

其它花活（MIG、k8s、显存硬配额）在这台机器上不存在或性价比极低。

---

## 1. 实际硬件

| 项 | 值 | 备注 |
|---|---|---|
| CPU | Xeon E5-2698B v3 | X99 平台，PCIe 3.0 |
| GPU | **Tesla V100 16GB × 1** | Volta，compute capability **7.0（SM70）** |
| 显存 | 16 GB HBM2 | 不是 32G 版，这是硬顶 |
| 系统 | Linux | 发行版待记录 |
| 内存 / 磁盘 | **TODO** | 装机后补，直接决定能跑多大模型 |

> 若以后再加一张卡（3060 或其他），需要**重写第 4 节的分配规则**：跨架构（SM70 + SM86）混跑不能做 TP，只能各跑各的任务。

---

## 2. 单卡带来的四条硬约束（比任何方案都重要）

**① 不能"分卡"，只能"分时"。**
"stu1 用 cuda:0、stu2 用 cuda:1" 这种约定在单卡上不成立。两个人同时 `CUDA_VISIBLE_DEVICES=0` 起进程，结果是**两个进程共享 16G 显存**，谁先吃满谁把对方 OOM 掉。

**② V100 不支持 MIG，没有硬件切分。**
MIG 是 A100 之后才有的能力，Volta 世代没有。别在这上面花时间。

**③ 16 GB 显存是真正的天花板。**
7B 模型 fp16 权重就是 ~14 GB，加载完只剩 1~2 GB 给 KV cache，稍微长一点的上下文直接 OOM。**16G 上跑 7B，只有量化一条路。**

**④ SM70 的软件生态正在退场。**
- FlashAttention 2/3 要求 **SM80+**，V100 用不了，vLLM 只能退回 xformers backend，吞吐差一截；
- V100 **没有原生 bf16**（Ampere 才有），必须用 fp16，`--dtype bfloat16` 会变慢或报错；
- AWQ 的 CUDA kernel 要求 **SM75+**，V100 上经常直接起不来；GPTQ 能跑但走慢速 kernel（Marlin 要 SM80+）；
- **CUDA 12.x 是 Volta 的最后一条主线**，不要跟到 13（以 NVIDIA 官方兼容表为准）。

结论：**`pip install -U vllm` 一把梭在这张卡上是必炸的**，版本必须锁死并写进镜像。

---

## 3. 会遇到的问题清单（按单卡重排）

| 问题 | 具体表现 | 严重度 |
|---|---|---|
| 环境冲突 | 不同人要不同 CUDA / PyTorch / vLLM，全局 conda 互相覆盖；一次 `--upgrade` 炸掉别人的环境 | ★★★ |
| 显存抢占 | 单卡 16G，一个人占满另一个人直接 `CUDA out of memory`；**比双卡时更尖锐** | ★★★ |
| 进程不释放 | SSH 断开 / 终端关掉，进程变孤儿继续占显存，卡"看起来在用但没人认领" | ★★★ |
| 一崩全崩 | 任何进程触发 GPU 驱动异常，**整卡所有服务全挂**，包括别人的 | ★★★ |
| 端口冲突 | vLLM / ollama 默认 8000，两人同时起就撞 | ★★ |
| 权限与磁盘 | 共用账号互删文件；模型权重几十 G 随手丢，盘满无人认领 | ★★ |
| 作业生命周期 | 没有排队、没有超时回收，跑完不退、长期霸卡 | ★★ |

⚠️ **必须提前和同学对齐**：容器、venv、Linux 账号、Slurm **都隔离不了 NVIDIA 驱动内核模块**。只要一个人的程序把驱动搞挂，所有人一起断。这是单机 NVIDIA GPU 的固有缺陷，不是配置问题。

---

## 4. 方案梯度（按"什么时候该升级"排序）

### 方案 A：现在就用的（2~3 人，零额外组件）

1. **一人一个 Linux 账号，禁止共用 root**
   ```bash
   sudo useradd -m -s /bin/bash stu1
   sudo passwd stu1
   ```
   家目录天然隔离；共享的数据/模型放 `/srv/share`，用 ACL 控制成"可读、只有 owner 能删"：
   ```bash
   sudo mkdir -p /srv/share/{models,datasets}
   sudo setfacl -R -m g:share:rX -m d:g:share:rX /srv/share
   sudo chmod 2775 /srv/share/models
   ```

2. **每人一套自己的 conda，装在自家 `~` 下**
   不要装全局 conda。`~/miniconda3` 各一份，env 互不可见，`pip` 绝不会串。
   代价是磁盘重复（每份 PyTorch 约 3~5 GB），换来的是**永不互相炸环境**——值。

3. **单卡串行：用 `flock`，不要用"锁文件"**
   手写"抢卡前 touch 一个 lock 文件"有竞态（两人同时 touch 都成功）。用内核级 `flock`，天然原子：
   ```bash
   ./scripts/gpu-run.sh --note "跑 qwen2.5-7b 评测" -- python eval.py
   ```
   抢不到锁就自动阻塞排队，并打印当前持有者是谁、在跑什么。

4. **强制显式指定 device，禁止裸 `cuda`**
   单卡时也要写 `CUDA_VISIBLE_DEVICES=0`，避免有人装了多卡假设的代码在你机器上行为不确定。
   共享目录放一份 `.envrc` 或在 `~/.bashrc` 里统一导出。

5. **后台任务一律 tmux，禁止裸跑**
   `tmux new -s stu1`，SSH 断了进程还在。禁止 `nohup python` 后忘了它。

6. **端口分段固定**
   | 用户 | 端口段 |
   |---|---|
   | stu1 | 8000–8099 |
   | stu2 | 8100–8199 |
   | stu3 | 8200–8299 |
   起服务时 `--port` 显式指定，别用默认。

7. **监控用 `gpustat`**
   ```bash
   pip install --user gpustat
   ./scripts/gpu-who.sh        # 谁在跑、占多少显存、跑了多久
   ```

✅ 零额外组件，半小时能落地
❌ 排队靠自觉（锁可以被绕开：不通过 `gpu-run.sh` 直接跑就没锁）；没有显存限额；环境还是可能被自己搞坏

---

### 方案 B：环境开始乱了再上（3~5 人，可选）

Docker + `nvidia-container-toolkit`，把 vLLM / PyTorch 版本固化进镜像，环境可复现、`docker rm` 即销毁。

```bash
# 单卡：显式给 0 号卡，和 --gpus all 等价，但写明更不容易误改
docker run --gpus '"device=0"' --shm-size=8g -it --rm \
  -v /srv/share/models:/models:ro \
  -v /home/stu1/work:/work -w /work \
  voltashare/vllm:0.6.3-cu121 bash
```

**重要纠正**：`--memory` / `--cpus` 限制的是**内存和 CPU**，**Docker 无法限制 GPU 显存**。想要"每人最多用 8G 显存"，容器做不到，只能靠约定或进程级 `torch.cuda.set_per_process_memory_fraction()`。别指望容器解决抢显存。

✅ 环境一键复现，vLLM 版本锁死不再退化
❌ 镜像体积大（5~10 GB/个）；**仍然不隔离驱动**；**不解决排队**

---

### 方案 C：人多、抢卡严重时（单机 Slurm，可选）

Slurm 能给你真正的排队、优先级、超时自动回收。单卡配置要点：

`slurm.conf` 关键行：
```
GresTypes=gpu
NodeName=volta NodeAddr=127.0.0.1 CPUs=36 RealMemory=64000 Gres=gpu:v100:1 State=UNKNOWN
PartitionName=gpu Nodes=volta Default=YES MaxTime=12:00:00 State=UP
```
`gres.conf`：
```
Name=gpu File=/dev/nvidia0 Type=v100
```

作业脚本：
```bash
#SBATCH --gres=gpu:1
#SBATCH --time=02:00:00
#SBATCH --job-name=eval
```

**单卡的额外好处**：`gpu:1` 就是全部资源，Slurm 天然让任务串行，谁也别想同时占——这正是你要的时分复用。
**代价**：交互式调试（Jupyter、断点、边改边跑）体验明显变差；vLLM 常驻服务需要 `srun` 起或者干脆绕开 Slurm。多数小团队到 B 就够了。

---

### 方案 D：不做

- **Kubernetes + GPU device plugin**：单机，overkill。
- **MIG**：V100 不支持。
- **"分卡"**：只有一张卡。

---

## 5. 16 GB 显存到底能跑什么

| 模型规模 | 精度 | 权重占用 | 可行性 |
|---|---|---|---|
| 1.5B | fp16 | ~3 GB | ✅ 轻松，KV 充裕 |
| 3B | fp16 | ~6 GB | ✅ 可行 |
| 7B | fp16 | **~14 GB** | ⚠️ 只剩 1~2 GB KV，短上下文勉强，稍长就 OOM |
| 7B | GPTQ-Int4 | ~4.5 GB | ✅ 可用，但走慢速 kernel，吞吐一般 |
| 7B | GGUF Q4_K_M | ~4.4 GB | ✅ **最稳**，走 llama.cpp |
| 14B | 4bit | ~8.5 GB | ⚠️ 能加载，上下文很短，别指望生产用 |

**框架建议**
- 只想稳定跑推理 → **llama.cpp（CUDA backend）**，对 SM70 最友好，坑最少；
- 需要 OpenAI 兼容 API + 并发 → **vLLM 锁老版本**（0.6.x 一线），且必须在小镜像里先验证 import 和首次推理能过，再让大家用；
- 千万不要在系统 Python 里 `pip install -U vllm`：它会把 torch/CUDA 一起抬到不支持 Volta 的版本。

> 单卡 16G 的现实最优解其实是：**一个人维护一个常驻推理服务占着卡，其他人都通过 `http://主机:端口/v1` 调 API**。加载一次模型几秒到几十秒，反复启停纯属浪费——这也是最省事的"时分复用"。

---

## 6. 使用约定（可直接发同学）

完整版见 [`docs/usage-rules.md`](docs/usage-rules.md)，核心六条：

1. 一人一号，不共用账号，不随便 `sudo`；
2. **只有一张卡**，跑 GPU 任务必须走 `scripts/gpu-run.sh`，让它排队；
3. 代码显式写 `CUDA_VISIBLE_DEVICES=0`，不写"自动选卡"；
4. 后台任务一律 tmux；跑完主动退出，别留孤儿进程；
5. 各自的 conda 放家目录，严禁 `pip install -U` 动别人的环境；
6. 常驻服务（vLLM/ollama）必须登记：谁、占卡、端口、预计结束时间。

---

## 7. V100 上机检查清单

到货后按这个顺序过一遍，能挡掉 80% 的"卡是坏的"误判：

- [ ] **BIOS**：`Above 4G Decoding = Enabled`（X99 平台必开，否则大显存卡可能不识别）
- [ ] **插槽**：插在直连 CPU 的 x16 槽，`nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current` 应为 `3 / 16`
- [ ] **供电**：V100 PCIe 版 250W，双 8pin；整机电源实际输出余量 ≥ 550W
- [ ] **散热**：涡轮卡，机箱要有前后贯通风道；`nvidia-smi -q -d TEMPERATURE` 空载应 < 45℃
- [ ] **识别**：`nvidia-smi -L` 输出 `GPU 0: Tesla V100-PCIE-16GB`
- [ ] **驱动**：`nvidia-smi` 正常出表；CUDA 版本 ≥ 12.0 但**不要 13**
- [ ] **压测**：`nvidia-smi -q -d PERFORMANCE` 观察是否降频（X99 供电/散热不足时 SM clock 会掉）
- [ ] **可选**：`sudo nvidia-smi -pm 1` 开持久模式，减少空载延迟

---

## 8. 仓库结构

```
README.md                 # 本文档：硬件现状 + 问题 + 方案梯度
docs/usage-rules.md       # 使用约定（发给同学的那份）
scripts/gpu-who.sh        # 谁在占卡、占多少、跑了多久（只读）
scripts/gpu-run.sh        # flock 串行锁，GPU 任务统一入口
```

使用：
```bash
chmod +x scripts/*.sh
./scripts/gpu-who.sh
./scripts/gpu-run.sh --note "说明" -- python train.py
```

脚本面向 Linux 服务器（需要 bash + util-linux 的 `flock`）。在 Windows / Git Bash 下没有 `flock`，`gpu-run.sh` 会打印警告并退化为直接执行，不排队。

---

## 9. 待定项

- [ ] 内存容量、数据盘容量（决定能放几个模型权重）
- [ ] 是否补第二张卡；若补，第 4 节的分配规则要重写
- [ ] 常驻服务选型（llama.cpp server / vLLM 老版本）与镜像固化
- [ ] 是否引入 Slurm（取决于抢卡矛盾有多严重）
