# 第二阶段拆分稿 v6 交叉评审任务

只读评审：不改代码、不改设计稿、不提交、不运行服务或测试、不对 Docker / 数据库做任何操作、不切换 git 分支。唯一写入为你的交叉报告。

## 对象
- 设计稿 v6（未提交，未因首轮评审改动；D14 已由用户定为 ①“同一窗口也进加载”）：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-26-voxel-authority-sharding.md`
- 首轮两份独立评审：同目录 `2026-10-24-world-region-paging/review-fable-sharding-v6.md`、`review-astra-sharding-v6.md`——请读**对方**那份，并对照自己那份
- 首轮简报与用户前提：`2026-10-24-world-region-paging/review-brief-sharding-v6.md`；源码与约束同首轮

## 请回答
1. 对方意见里你**不同意**或认为严重度有误的条目（给证据：稿内章节 + 源码 file:line）。
2. 对方发现而你遗漏的条目：是否成立；成立的话严重度。
3. 双方都发现的问题（如化身守卫与收尾写回、在途切点与停写占用、跟随建立的快照缝、合并时请求顺序与去重、D7-A″ 阻挡复活或漏挡、S_want 与 r_own 混淆、合并时施法 / 命中 / 瞬态）：给出**最小修法**（机制级，一两句），并判断该修法是否会让正常路径重新出现停步、编辑拒绝或冻结。
4. 哪些问题**只能**靠产品取舍解决（无法在不付玩家可见代价的前提下满足“边缘零停顿”），应进 §9 交用户拍板；写出选项与各自玩家可见影响。
5. 统筹补充两点，请判断是否须在批准方向稿前处理：(a) 所有权前置下每个 T1 仍由控制面计划，T1 速率随玩家移动与窗口前沿增长，控制面是否实质处在移动关键路径上；(b) 玩家走过后冷页不归还，长期探索下单分区所有权与覆盖行持续增长、分区倾斜，S4 之前是否可接受。
6. **合并清单**：给出一份批准前必改清单（不超过 8 条，按优先级），每条写明修法方向与归属（工程 / 交用户拍板）；以及可留到对应交付步的条目。
7. 结论：按合并清单修改后能否作为第二阶段方向稿批准。

每条标【严重】【中】【轻】，推断标“推断”。

## 输出
中文报告写到指定文件，末尾 10 行以内总评：
- Fable：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-24-world-region-paging\review-fable-sharding-v6-cross.md`
- Astra：`D:\hemifuture\ex_mmo_cluster\docs\10-active\voxel-authority\2026-10-24-world-region-paging\review-astra-sharding-v6-cross.md`
