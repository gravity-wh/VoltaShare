# VoltaShare 部署与验收清单

> 适用范围：两名核心计算用户的 PVE 候选架构；**采纳后需修订原有 VS-MSD-001 管理规范和使用规约**。  
> 状态：待评审、待备份、待实施。本清单配合 [PVE 技术部署方案](pve-architecture.md) 使用，禁止在无备份时直接进行清盘或硬盘初始化操作。

## Phase 0 — 硬件确认与数据保护

- [ ] 记录主板型号、BIOS、CPU 核心/线程、RAM、V100 PCI ID、AMD 显卡 PCI ID。
- [ ] 列出两块 NVMe 和一块 HDD 的厂商、序列号及稳定 `/dev/disk/by-id/` 路径。
- [ ] 检查 BIOS 中 VT-d / IOMMU、Above 4G Decoding 选项。
- [ ] 完整备份 NVMe 1 上的 Windows、NVMe 2 上的 Ubuntu、500 GB HDD 上的重要文件。
- [ ] 验证备份可以从另一台机器读取和恢复。
- [ ] 核对 Windows 原来的 UEFI/Legacy 引导及激活状态。

## Phase 1 — 安装 PVE

- [ ] 仅在确认备份后，选择 **NVMe 2** 安装 PVE。
- [ ] PVE 使用 ext4 + LVM-thin，计划宿主文件约 32 GiB、Swap 4 GiB。
- [ ] 配置固定管理 IP 和 `vmbr0`。
- [ ] 通过第二台设备访问 PVE Web 界面。
- [ ] 验证 VT-d/IOMMU 分组；不要盲目启用破坏隔离的 ACS override 或 unsafe interrupts。

## Phase 2 — 三台虚拟机

- [ ] VM 101 Ubuntu：`cpu: host`，32 vCPU，36 GiB RAM，120 GiB 起步虚拟磁盘。
- [ ] VM 100 Windows 10：`cpu: host`，32 vCPU，18 GiB RAM；NVMe 1 整盘映射；测试系统启动与 AMD 亮机卡输出。
- [ ] VM 102 fnOS：2 vCPU，2 GiB RAM，24–32 GiB SSD 系统磁盘；500 GB HDD 整盘数据映射。
- [ ] 只允许 fnOS 初始化明确授权的数据盘；已有 HDD 数据先确认导入/备份方式。
- [ ] 三台 VM 分配独立局域网 IP；fnOS 配置基础 SMB/NFS 服务。

## Phase 3 — V100 直通和模式切换

- [ ] 默认双人模式：V100 在 Ubuntu，Windows 使用 AMD 卡。
- [ ] Windows 独占模式：Ubuntu 正常关机；Windows 关机调整至 54 GiB RAM，获得 V100。
- [ ] Ubuntu 独占模式：Windows 关机；Ubuntu 关机调整至 54 GiB RAM，获得 V100。
- [ ] 检查每次切换前后的 PVE 设备归属、`nvidia-smi` 和 VM 状态。
- [ ] 至少完成三轮 V100 交替使用及重置验证。
- [ ] 切换期间核对 fnOS 始终可访问；记录任何需要重启 PVE 的情况。

## Phase 4 — 应用与存储验证

- [ ] Windows 保存约 60 GB Qwen 权重到 NVMe 1。
- [ ] 确认 MiniMax H3 使用的量化/优化权重**具体文件名、大小和授权许可**。
- [ ] 删除重复下载缓存/中间解包文件，定期观察 SSD 可用空间。
- [ ] Strata 在 V100 16GB / Windows 54 GiB 环境下完成加载和推理测试。
- [ ] MiniMax H3 单独验证是否与 Volta/CUDA 12 内核兼容；记录一次成功或失败测试。
- [ ] Ubuntu 跑一次 GPU 仿真，记录吞吐/时间与 V100 利用率。
- [ ] fnOS 在 HDD 上完成文件写入、读取和外部备份测试。

## Phase 5 — 自动化与运维

- [ ] 编写模式切换脚本，包含停止检测、设备归属检查、失败退出及日志。
- [ ] 为 Windows、Ubuntu 和 fnOS 配置监控及磁盘空间告警。
- [ ] 明确两位用户的 GPU 切换协调流程；不得强制终止对方未保存的工作。
- [ ] 制定 PVE 系统、Windows NVMe、Ubuntu VM、fnOS HDD 的独立备份计划。


## 上线前的管理联动

- [ ] 查阅仓库现有 `docs/management-framework.md`，识别原规范与 PVE 的制度冲突，形成更新版权限、预约、互斥、事故处理规则。
- [ ] 审阅已有 `scripts/` 的实际功能、危险命令和权限，避免覆盖或重复实现。
- [ ] 明确另外 1–3 名使用者通过什么方式共享服务（例如 SSH / 推理 API / NAS），及其容量和调度策略。
- [ ] 由管理员单独核准实际切换脚本；未通过验收前只手工按 SOP 操作。

## 与旧架构的冲突验收（必须通过）

- [ ] 解释 `docs/usage-rules.md` 的一人一个 Linux 账号、`gpu-run.sh`、`gpustat` 的适用范围：它们无法跨 Windows/Ubuntu VM 实现独占设备的切换。
- [ ] 将原规范中的 `/srv/share/models`、每用户 100GB 配额、500GB 共享权重和 1TB 数据集等容量假设改为与 **2×256GB NVMe + 500GB HDD** 相容的现实方案。
- [ ] 明确 Windows 用户退出独占模式会触发关机；只有相关用户同意并完成任务收尾才可发起切换。
- [ ] 审核 fnOS HDD 已有数据的导入与备份，不要把系统盘直通备份当作数据保护。
- [ ] 记录 V100 在两台 VM 间反复分配的实际 reset 结果；若必须重启宿主，修订 fnOS 可用性目标。
