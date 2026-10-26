# 第二阶段拆分稿评审任务（2026-10-26-voxel-authority-sharding.md v1）

只读评审：不改代码、不改设计稿、不提交、不运行服务或测试、不对 Docker / 数据库做任何操作。唯一写入为你的评审报告。

## 对象
- 设计稿：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-26-voxel-authority-sharding.md`
- 父稿（approved v4，含 Q1 已批准的模拟集语义、“第二阶段大纲”、进度日志与 M0–M2a 实测）：同目录 `2026-10-24-world-region-paging.md`
- M2a 设计：`2026-10-24-world-region-paging/m2a-page-store.md`；以往评审 `2026-10-24-world-region-paging/review-*.md`（第三轮对第二阶段大纲的意见）
- 源码：ex_mmo_cluster master + 工作树未提交的 M2a 改动（`apps/voxel_region`、`apps/scene_server`、`apps/world_server`、`apps/gate_server`、`apps/mmo_contracts`、`apps/data_service`）；客户端 `D:\hemifuture\Voxim\Source\Voxim\`
- 约束：`D:\hemifuture\ex_mmo_cluster\AGENTS.md`、`D:\hemifuture\Voxim\AGENTS.md`、`D:\hemifuture\Voxim\Docs\Testing.md`

## 用户前提（原话）
- “我们的服务器设计是scene负责不同区域的场景，可以拆分，只有世界级需要协调的内容才到world不是么？为什么现在重活都是world在干？”
- “体素真值从长远来看就是要和scene的边界对齐吧？”
- 资源占用平滑、无不可控尖峰；内存可扩，不以现生产内存为终点；如园等存量数据必须保护。

## 请回答
1. **方向**：“边界对齐、同址不同进程、页粒度单一分区表、World 只做全局协调”是否成立；稿中对用户初步立场的修订（World 协调迁移而非跨区事务、热 / 液体不走 halo、角色账写权随角色、保护区 / 信标改页数据、seq 块分配）是否正确。
2. **岛闭合**（§3.2）：在已批准 Q1 语义下“跨分区通量恒为零、无跨分区原子事务”的推导是否严密；找反例（电路、投射物、整件 HP、跨界预制件 / 树、地块安装、远程施法、拟态、身体接触、液体下落、GM 工具等），以及岛合并 / 迁移的停顿与可见性代价是否可接受。
3. **页所有权迁移协议**（§3.5、§4g、§4h）：owner_epoch、PG 决定点、迁移期间的读写与订阅、崩溃与网络分区下 I1–I5 是否成立。
4. **客户端顺序语义与协议**（§4c、D5）：近景保留协议 41 / 单一 seq 的论证；远景跨分区的改动面；客户端是否依赖 seq 连续（请在客户端源码中核实）。
5. **持久化、id 与全局账**（§4e、§4f、§3.4）：每分区切点 / 前缀与全局账的一致性；块分配 seq 的拒旧语义；角色账随角色迁移的原子性。
6. **交付顺序与前置**（§5、D8）：M2b / P6 提前、粗层页按 L0 页分片段的必要性与时机、每步能否在真实入口闭环；测量与验收定义是否足以证伪。
7. **结论**：能否作为第二阶段的方向稿批准；若不能，开工前最少要改哪几处（不超过 6 条）。

每条标【严重】【中】【轻】，给证据（稿内章节 + 源码 file:line；外部资料给 URL 与原句，找不到写“未核实”），推断标“推断”。

## 输出
中文报告写到指定文件，末尾 10 行以内总评。
