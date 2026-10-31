# 气候源owner与取样合同

新世界气候使用 `VoxelRegion.Climate.Source`：从已接纳生成store、world CV/kernel identity/八项配置与显式作者Kelvin参数构造不可变source。`GeneratedStore.climate_source/2`不生成页面，也不改manifest；错kernel或缺显式参数返回诊断错误。

`Climate.bind/2`把source接入内部环境配置，`at_many/2`按输入完整XYZ顺序通过一次DirtyCpu NIF取样；单点`at/2`沿同一路径。Rust `climate.rs`的`temperature_score`与ground分类共用；score阈值`.10/.22`只有一个定义，不在Elixir复写noise。作者参数为`cold_kelvin`、`warm_kelvin`、`sample_height_offset_m`（当前源v1明确为1）、`wind_mps`，没有Kelvin默认值。

绑定同身份幂等，不同身份明确返回 `:climate_source_identity_conflict`，不承担世界气候版本发布；变暖/换源必须经过World的cut与背景账接纳。Source只承诺数值合法：不可表示的整数转float在此唯一构造边界返回 `:invalid_climate_parameters`，不让下游重复复核；它不硬编码雪融点。默认冷雪preset由生成发布/World组合边界核对当前材料目录的相态物性与初始化候选，数值合法source不能替代初态接纳门禁。

新source的`region/2`恒为nil：温度差不是绝热边界。与旧非空`climate_zones`同时绑定会失败，避免温度与历史绝热区两套真值混用。现有旧资产行为保留，不能把它扩成新的空间设计基础。

source只使用构造时已接纳配置，worker/continuation不得重新读文件/Application.env；旧due自然步完成后由统一ready边界切换版本。source身份包含world CV、完整kernel/config及规范化作者参数；观察CLI应投影该摘要及显式作者参数，不能把内部tuple当JSON原样编码。

取样不是世界初态初始化。未记录材料按不同当地空气温度初始化仍可能传热，发布owner须主动构造和登记真实初始活动候选；不得按玩家访问/可见窗口激活，不得用温差切断接触。冷恢复保留既有焓、温度、数量、有限预算及source身份。

生产源码改变会改变worldgen kernel hash；旧pinned manifest不会静默接受新内核。新世界使用独占新descriptor。旧世界必须经过离线副本、明确cut/背景重基准账和独立候选manifest的迁移门禁，旧二进制/清单保持可用直至切换，绝不原地覆盖冻结发布字节。

最小测试：Rust `tests/climate_samples.rs`、`tests/climate_initialization.rs`；Elixir `test/climate_source_test.exs`与现有`climate_test.exs`。BEAM/NIF安装仅在统一编译窗口运行。完整设计、有限真实天然patch反证和迁移未完成边界见continuous-world-decision §5.5与临时activity初始化报告。

当前只提供新世界source构造与取样入口；不表示正式World接纳、初始活动登记或旧世界迁移已完成。
