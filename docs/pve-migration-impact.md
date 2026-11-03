# VS-PVE-001 — 从单 Linux 宿主到 PVE 的迁移影响评估

> 状态：待评审提案。此文档对照仓库 `main` 分支现行规范（VS-MSD-001 v1.0，2026-11-02）及两份脚本进行差异分析；不表示已采用或部署。

## 决策范围

当前 VoltaShare 文档的基座：单 Linux 宿主、3–5 个 Linux 用户、共用一张 V100 16GB；通过 `flock` 串行执行、统一 Linux 文件系统保存权重和数据。新提案：一台 PVE 宿主，三台 VM（Windows 10、Ubuntu、fnOS），默认 Windows 和 Ubuntu 同时在线且 V100 在 Ubuntu；切到独占模式时由管理员按流程停止计算 VM，重分配 54GiB RAM 和 V100，fnOS 常驻。

两者**技术假设不兼容**：VM 级别的 VFIO 独占不能靠 Linux 客体内的 `flock` 完成协调，Windows 客体也不受 Linux 的 `sudoers`、`conda`、`gpustat` 规则约束。若决定采纳，必须为管理体系出新版本，不可只把资源数字写进原表。

## 主要差异和需要修改的制度

| 主题 | 现行 VS-MSD-001 / 使用规约 | VS-PVE-001 提案 | 必须采取的措施 |
|---|---|---|---|
| 计算环境 | 单 Linux 操作系统，多用户独立 conda | Win10 / Ubuntu 两套计算 VM | 规范分开，增加 VM 管理员和用户角色 |
| GPU 互斥 | `scripts/gpu-run.sh` 以 `/tmp/volta-gpu.lock` 串行 Linux 任务 | V100 VFIO 整卡只交给一台运行中的 VM | PVE 宿主级仲裁、预约、优雅关机检查；旧脚本只保留 Ubuntu 内部用途 |
| GPU 观测 | `gpu-who.sh`、`nvidia-smi` 在单宿主运行 | `nvidia-smi` 只能在 V100 所属计算 VM 看到设备 | 增加 PVE 设备归属监测和当前 VM 内使用者记录 |
| 资源分配 | cgroup / Linux 用户进程配额 | VM 定额（18/36/2 或 54/2 GiB）与宿主 CPU 调度 | 按模式管理 QEMU 内存、CPU 权重及准入 |
| 管理权限 | Linux 账号 / sudoers 白名单 | PVE Web/API 管理权限、Windows/Linux 客体权限 | 分离管理员与普通用户，不给使用者 PVE root 或宿主设备写权限 |
| 存储 | `/srv/share/models`、数据集/缓存与用户配额 | Windows NVMe1、PVE+Ubuntu+fnOS 系统 NVMe2、fnOS 数据 500GB HDD | 重做配额/目录设计；原 500GB 模型池、1TB 数据集预算已超出现有磁盘 |
| 服务 | 原 Linux 宿主上的推理服务 | 服务分散在对应 VM，可能随模式切换停止 | 统一登记访问地址、服务健康检查、停机通知 |
| 备份 | 原 Linux 用户目录/共享目录 | 原生 Windows SSD、PVE VM 虚拟盘、直映 HDD | 单独定义三类备份与恢复方式；PVE 备份不自动覆盖全部直映盘 |
| 可用性 | 单 Linux 驱动故障导致 GPU 不可用 | GPU reset 失败可能需重启 PVE，fnOS 会中断 | 验证 reset，修改 fnOS SLA 和恢复目标 |

## 现有脚本的真实能力边界

`gpu-run.sh` 使用本地 `/tmp/volta-gpu.lock` 和 `flock`。它对同一 Linux 用户空间内**主动遵循脚本**的任务有效；不能锁住另一台 VM 上的同一张 PCIe 设备。脚本在缺少 `flock` 时会警告后直接运行命令，这种 fail-open 行为不应复制到 PVE 级 GPU 切换代码。

`gpu-who.sh` 依赖 `gpustat` 或 `nvidia-smi`。PVE 把显卡交给 VFIO 后，宿主通常没有客体的 CUDA 进程表；Windows 独占期间 Ubuntu 的 `gpu-who.sh` 无法看到 Windows 内的任务。

这些脚本与现有 Linux 管理规范**暂不修改**；只有在 PVE 方案通过审批后，才按新权限边界设计替代或补充工具。

## 推荐采纳流程

1. 决定采纳 PVE 还是保留原单 Linux 多账号方案，记入架构决策记录（ADR）。
2. 若采纳，在 `docs/management-framework.md` 中新增版本和决策，更新 `docs/usage-rules.md`，明确现有 Linux 规则仅适用于 Ubuntu VM。
3. 为 PVE 增设受控模式切换流程：申请、任务完成确认、管理员批准、关闭受影响 VM、检测设备归属、重设内存、启动、验收及日志。
4. 备份两块 NVMe 和 HDD，实测 BIOS VT-d / IOMMU 分组、AMD 亮机卡及 V100 复位能力，再执行任何重装或整盘映射。
5. 重新审定配额及数据存放：Windows NVMe1 的 60GB Qwen + MiniMax H3 权重版本必须严格核对；不保证 V100 16GB + 54GiB RAM 能运行全部模型。fnOS 的 500GB HDD 是数据盘而非异地备份。
6. 发布 PVE 运行规约，完成跨 VM GPU 切换和 fnOS 在线测试，再将新架构从“候选”升级为“已部署”。

## 设计验收门限

- 双人模式：Win10 18GiB + Ubuntu 36GiB + fnOS 2GiB；宿主及 QEMU 至少按 8GiB 预算并观察实际占用；V100 仅属 Ubuntu。
- Windows/Ubuntu 单人模式：被服务方约 54GiB 内存和 V100，另一台计算 VM 关机；fnOS 保留 2GiB，宿主余量不下降至不安全水平。
- 设备复位：连续多次 Ubuntu → Windows → Ubuntu 直通切换，记录是否需要重启宿主；失败不得宣称 NAS 无中断。
- 磁盘：两个 256GB NVMe 单独验算空闲空间；fnOS HDD 数据在未确认备份之前不初始化。
- 管理：没有经授权的用户确认，不自动关闭另一人的计算任务；所有切换可追踪、可中止。
