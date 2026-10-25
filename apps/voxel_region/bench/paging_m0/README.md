# paging_m0 — 区域分页 M0 规模与尖峰基准（只测试 / Test-only）

决策稿：[`docs/10-active/voxel-authority/2026-10-24-world-region-paging.md`](../../../../docs/10-active/voxel-authority/2026-10-24-world-region-paging.md) 的 M0。
本目录不进任何发布产物，只服务 M0（以及 M1、M3 之后的复测）。

## 组成

| 文件 | 职责 |
|---|---|
| `m0.py` | Windows 原生部署控制端：`start` / `stop` / `status` / `rpc` / `osmon`。部署目录内私有 `m0-env.json`（含测试密钥，不提交）给出节点名、cookie、调度器数、隔离 PG 与全部运行时环境变量 |
| `boot.exs` | 启动组合：正式迁移 + 除 `gate_server` 外的全部应用（quicer 只在 Linux 构建；M0 不接客户端） |
| `probe.ex` | 节点内采样器 `VoxelRegion.Bench.M0Probe`：每秒节点内存 / World 堆与 mailbox / 调度器利用率；`:sys.install` 计 World 每条消息的回合时长；system_monitor long_gc / long_schedule；`DataService.Repo` 查询的池等待与执行时长；`field_heap/0` 字段级堆 |
| `load.ex` | 负载驱动 `VoxelRegion.Bench.M0Load`：N 个活跃窗口，各 = 一个经 `canonical_snapshot_and_subscribe` 的订阅者 + 一个经作者入口 `apply_edits` 交替放 / 挖的编辑者；`activity` 每窗口加水与热源，`circuit` 每窗口加热电石 8 格环与热源 |
| `run_m0.py` | 一轮编排：还原隔离库 → 启动 → 空闲段 → 逐级 N 窗口 → 收集证据 → 停机；`--activity` / `--circuit` 活动负载，`--spacing` 窗口间距（< 186 m 为重叠） |
| `install_copy.py` | 冷内容份数轴：经 `World.parcel_install` 把同一份如园装到远处（key 带 tag，幂等） |
| `summarize.py` | 把 `M0Probe.snapshot()` 摘成可读表 |
| `compare.py` | 多轮 run 目录的冷内容份数对比表（启动、空闲字段堆、各级吞吐 / 延迟 / 阶段、World long_gc、OS 峰值） |
| `reinstall.py` | 同页反复安装轴：同一份如园按原位再装 N 遍，每遍后重启量冷启动与空闲字段堆（`--skip` 跳过不能原位重装的批次） |

## 数据与隔离

- 世界数据只来自 `D:/hemifuture/Backups/ruyuan-20261024/` 的 dump，还原到隔离 PG（容器 `voxim-pg-paging1024`）。
  如园源世界与演练副本全部只读（见 kickoff“如园保护”），本目录脚本不连接它们。
- 生成缓存目录是演练副本 `world/` 的复制品，归本部署所有；parcel 导出件从备份 tar 解出。
- 证据写到 Voxim `Saved/Playtest/paging-20261024/runs/<run>/`。

## 已知适用范围

- 负载走作者入口 `apply_edits`：覆盖 World 几何提交尾部（规约、后像、结构、碰撞、日志、扇出），不覆盖玩家工具会话、限速与扣料。
- 开发机是 Windows 原生 OTP 29 / Elixir 1.20；演练副本镜像是 Linux OTP 27，两者内存分配器与 GC 行为不同，绝对内存值不可直接对比。
- RPC 只调用一次、失败不重试；探针与负载都是注册名幂等进程，并自带截止时间。
