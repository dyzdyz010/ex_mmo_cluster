# M2b（按需装页）代码评审任务（单轮）

只读评审：不改代码、不改文档、不提交、不运行 mix / 测试 / 服务（同一工作树正在跑基准，编译会干扰）、不对 Docker / 数据库做任何操作、不切换 git 分支。唯一写入为你的评审报告。

## 对象
- ex_mmo_cluster 工作树相对 HEAD `2931f09f` 的未提交改动（`git -C D:\hemifuture\ex_mmo_cluster diff HEAD -- apps` 与未跟踪的 `apps/voxel_region/lib/voxel_region/world/closure.ex`、`world/page_load.ex`、`test/page_on_demand_test.exs`、`apps/data_service/priv/repo/migrations/20261026000002_create_voxel_identity_locator.exs`、`bench/paging_m0/migrate.py`）。
- 计划与施工记录：`docs/10-active/voxel-authority/2026-10-24-world-region-paging/m2b-on-demand-pages.md`（§7 为偏差、实测与已接受偏差）。
- 设计依据：父稿 `docs/10-active/voxel-authority/2026-10-24-world-region-paging.md` P1、P4（不变量 I1–I5、装页令牌、读取闭包、pin 与依赖版本复核、启动与活动索引）；M2a 设计 `.../m2a-page-store.md`；拆分稿 approved v7 §5 e（粗层 `(level, L0 页)` 片段）。
- 约束：`D:\hemifuture\ex_mmo_cluster\AGENTS.md`、`D:\hemifuture\Voxim\AGENTS.md`、`D:\hemifuture\Voxim\Docs\Testing.md`。

## 请回答
1. **正确性**：按需装页后，任一入口（玩家编辑 / 工具 / prefab / GM / 施法 / 信标 / 身体 / 定时模拟 / 观察与窗口 / 区域取数 / 维护）会不会在缺页时把冷页当空气或成功、提交部分通量、或沿过期闭包提交；装页结果的接纳与迟到拒绝、同序队列（`PageLoad.order_key` / hold / release）是否保持同一 actor 顺序且不丢消息、不死锁。给具体时序反例。
2. **持久化与恢复**：身份定位表与页段同事务写入、日志格式由整表改为按键增量（旧格式显式失败）、粗层片段增量维护、启动只读头部 + 后缀 + 活动索引——重启后状态是否与 M2a 逐项等价；后缀很长或活动页非空时的恢复路径有无漏洞。
3. **测试合法性**：被改写的既有用例（见 m2b §7 依据）是否真因契约变化，有无弱化断言、改夹具避开失败；新增反例能否证伪（期望是否独立于被测算法）；`:sys.replace_state` 夹具是否只改驻留标记。
4. **工程约束**：是否有为未发生问题预建的分支 / 配置 / 框架；超时统一改 300 s 是否合理；是否引入第二真值或静默 fallback。
5. **结论**：能否提交；提交前必改（≤ 5 条），其余列入后续。

每条标【严重】【中】【轻】，给 file:line 证据，推断标“推断”。

## 输出
中文报告，末尾 8 行以内总评：
- Fable：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-24-world-region-paging\review-fable-m2b-code.md`
- Astra：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-24-world-region-paging\review-astra-m2b-code.md`
