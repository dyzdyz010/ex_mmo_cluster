# 批量热内核

分类：Global system。Rustler 0.37.3 DirtyCpu 接收 World 冻结的节点与接触索引，
返回不可变温度、HP、余能与能量账；不保存世界、不发消息、不写数据库。
新活动种子出现时在当前不超过50 ms的稳定步末返回，让 World 更新六邻域后继续本批剩余步。
普通显热测试以现有 Elixir 单步公式为对照，相变测试以解析热量和 World 事件边界判定。
部署只更新本库，不改变世界生成器身份。

## 相变热账数值契约（2026-09-19）

相变焓消费每个稳定数值步已有的接触、有限源和环境净热量，温度由焓派生；
不能用舍入后的温差逆推焓，也不把残差补进环境账。World 继续独占材质替换和提交，
50ms 相变/前沿事件边界不变。依据
[Goldberg 的浮点运算分析](https://docs.oracle.com/cd/E19957-01/806-3568/ncg_goldberg.html)：
温度加微小增量后再相减会暴露已经丢失的低位，应消除不必要的数值往返。

Test-only 验证使用正常 `cargo test --manifest-path apps/voxel_region/native/voxim_thermal/Cargo.toml`：
纯内核直接构造有限源与相态输入，不启动数据库、World、网络或 UE；
真实冰物性277秒反例按解析输入功率乘时间验焓与供热账，保持 `1e-4 J` 门槛。
跨潜热端点与成对接触守恒用小型确定输入验证；NIF/World接缝复用正常
`mix test --no-start test/thermal_batch_test.exs test/phase_world_test.exs`。
这些检查不替代真实双客户端组合场景与共同窗口性能验收。

本次局部验证：正式 Rust 反例在旧数值路径残差 `-0.000259214663 J`，修复后
`-0.000011557364 J`，原 `1e-4 J` 门槛不变；上述 Cargo 入口3项通过，
Mix 入口42项通过、1项实时场景按既有标签排除。原始日志位于同级 Voxim
`Saved/TestingDesignFix/20260919/heat-fix/`。Windows NIF 已经正常 Rustler 构建；
Linux 部署仍须从本源码重新构建 NIF，不能复用旧 `.so`。

2026-09-17 组合性能修复：`advance` 对新热前沿立即返回；已激活的宏格域在同一0.5秒World提交内保留，批末再按实际温度／燃烧收缩，避免0.01K阈值两侧反复重建接触。数值稳定步长、同步持久化和无状态NIF边界不变；旧`batch`接口继续在双向活动变化时返回。参考SciPy `solve_ivp`的定向事件及PETSc的稀疏结构复用；实测、取舍、原始记录见同级Voxim的`Docs/R7/material-performance.md`。这项变更需匹配World与本NIF一同冷安装。

## 灰体辐射换热（2026-09-24，默认关闭）

`advance/7` 的第 7 个参数 `{半对, 对天空}` 由 World 从环境资产 `emissivity`、`view_range_cells`
派生：暴露面沿外法线看至多 `view_range_cells` 个宏格，首个命中的热节点构成面积 `A/2`、
因子 `ε/(2−ε)` 的半对，互逆两条视线合成等发射率无限平行板公式
`q = σA(T₁⁴−T₂⁴)/(2/ε−1)`；未命中或命中无热容量占用按 `εσA(T_amb⁴−T⁴)` 对天空并记入环境账。
每个半对自身反对称，宏/微格尺寸不同也守恒。依据：Incropera et al., *Fundamentals of Heat and
Mass Transfer*（7th ed.）§13.3 漫灰两表面封闭腔（表 13.3 无限平行板）及灰体对大环境的净辐射
（式 1.7）；把互见面近似为平行板、视距外视作天空是本项目的简化，设计与模型对比
（A 空气节点 / C 线性视线 / S 仅天空 / B 本方案）见同级 Voxim `Docs/R8/Design-decisions.md` §10。
线性环境换热保持原语义；辐射项存在时按段首温度线性化 `4σwT³` 重算稳定步长，
两表为空（`emissivity = 0`）时数值路径与引入辐射前逐位相同（`thermal_radiation_world_test`
用主线 79dde382 逐提交记录的摘要验证）。视线伙伴入候选域但不是种子，只有真实升温越过
容差才按既有前沿规则扩域；编辑落在视线缓存包围盒外扩视距内时整体丢弃视线缓存。
