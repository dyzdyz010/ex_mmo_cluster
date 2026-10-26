# M2a 评审任务：页表与连续写回（m2a-page-store.md v1）

只读评审：不改代码、不改设计稿、不提交、不对 Docker 容器或数据库做任何操作，不运行服务或基准。唯一写入为你的评审报告。

## 对象
- 设计稿：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-24-world-region-paging\m2a-page-store.md`
- 父稿（approved v4，含进度日志与 M0/M1 实测）：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-24-world-region-paging.md`
- 状态与持久化调研：同目录 `recon-state-persistence.md`（行号对应旧源码 b9b305f4，以当前 master `acb401e7` 为准）
- 源码：`apps/voxel_region/lib/voxel_region/`（重点 `world.ex`、`world/log.ex`、`overlay_log.ex`、`world/payloads.ex`、`world/canonical.ex`、`world/edits.ex`、
  `world/tools.ex`、`world/prefabs.ex`、`world/parcel.ex`、`world/gm.ex`、`world/coarse_rebuild.ex`、`world/catalogs.ex`、`world/thermal.ex`）、
  `apps/data_service/lib/data_service/voxel/overlay_log_store.ex`
- 约束：`D:\hemifuture\ex_mmo_cluster\AGENTS.md`、`D:\hemifuture\Voxim\Docs\Testing.md`

## 用户前提
- 如园等存量世界数据必须保护：迁移只在隔离库验证，源库只读。
- 资源占用要平滑、无不可控尖峰；内存不够可以扩，不以现生产内存为终点。
- 用户已同意 M2 先做“页表 + 连续写回”，并要求设计先经评审。

## 请回答
按设计稿 §9 的六个问题逐条回答。每条结论标【严重】【中】【轻】，给证据（稿内章节 + 源码 file:line）；推断标“推断”。
特别请用源码核实：是否存在不经 `Log.append_log/3` 改动真值的路径；`Payloads.payload_bytes` 物化一个区域实际读取哪些状态字段（决定“页输入”闭包）；
多版本页方案在崩溃、并发提交、Replica / 订阅补发下是否保持 I1–I3。

## 输出
写到指定文件（中文，按六个问题分节），末尾 10 行以内总评：能否按稿开工；若不能，最少要改哪几处。
