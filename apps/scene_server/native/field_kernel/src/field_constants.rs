//! Field 物理常量的**唯一真相源**(single source of truth)。
//!
//! 这一组电导/电势/介质击穿/温度扩散权重常量,曾经在 Rust 四个 kernel
//! (`conduction_path.rs` / `discharge_path.rs` / `electric_potential.rs` /
//! `temperature_diffusion.rs`)与 Elixir 四个模块
//! (`ElectricField` / `Kernels.ConductionPathKernel` / `Kernels.ElectricDischargeKernel`
//! / `TemperatureField`)各写一份,人工同步极易漂移 —— 一旦 `.ex` fallback 与
//! `.rs` native 用了不同的权重,同一条施法请求在两条路径上会算出不同的场结果。
//!
//! 现在两侧都从本文件取数:
//!   * Rust 端:本模块被 `lib.rs` 以 `mod field_constants;` 引入,四个 kernel
//!     直接 `use crate::field_constants::*;`,不再各自 `const`。
//!   * Elixir 端:`SceneServer.Voxel.Field.Constants` 在**编译期**解析本文件的
//!     `pub const NAME: TYPE = VALUE;` 行,把每个常量烘焙成模块属性,供
//!     fallback 路径在 NIF 不可用时仍然得到与 native 完全一致的数值。
//!
//! ## 维护纪律(防漂移门禁)
//!   * 只在本文件改动物理常量的**数值**;改完两侧自动同步,无需手工改 `.ex`。
//!   * 每条 `pub const NAME: TYPE = VALUE;` 必须独占一行,VALUE 是十进制字面量
//!     (允许 `_` 分组、可选小数、可选前导负号),以便 Elixir 编译期正则解析。
//!   * `field_constants_parity_test.exs` 会断言 Elixir 解析结果与各 kernel 实际
//!     使用值逐一一致;新增/改名常量请同步该测试与下游 `use`。
//!
//! 注意:本文件**只**承载在 Elixir 与 Rust 之间双份维护的物理权重常量。
//! 纯 Rust 内部的网格编码常量(`FACE_*` / `FACE_COUNT` 等)不在此处,它们没有
//! Elixir 副本,不存在漂移面。

// ---- 电导 / 电势 step-cost 共享权重 ----------------------------------------
// 被 conduction_path.rs / electric_potential.rs(Rust)与
// ElectricField / ConductionPathKernel(Elixir)共享。

/// 未投影 cell 的默认电导率(西门子归一值)。
pub const DEFAULT_CONDUCTIVITY: f64 = 0.0;
/// 未投影 cell 的默认介电强度。
pub const DEFAULT_DIELECTRIC_STRENGTH: f64 = 3.0;
/// 电导率下限,避免 resistance cost 除零。
pub const MIN_CONDUCTIVITY: f64 = 0.001;
/// resistance step cost 权重:cost ∝ RESISTANCE_WEIGHT / conductivity。
pub const RESISTANCE_WEIGHT: f64 = 4.0;
/// 介质击穿 step cost 权重。
pub const BREAKDOWN_WEIGHT: f64 = 0.25;
/// 已有 ionization 对导电 step cost 的折减权重。
pub const IONIZATION_BONUS_WEIGHT: f64 = 0.01;
/// 单步 step cost 下限,避免负/零成本破坏 Dijkstra 单调性。
pub const MIN_STEP_COST: f64 = 0.05;

// ---- ionization tick 演化 ---------------------------------------------------
// 被 electric_potential.rs(Rust)与 ElectricField(Elixir)共享。

/// `|potential|` 超过该阈值时本 tick 累积 ionization,否则衰减。
pub const IONIZATION_THRESHOLD: f64 = 50.0;
/// 超阈值时每 tick 的 ionization 增量。
pub const IONIZATION_GROWTH: f64 = 5.0;
/// 未超阈值时每 tick 的 ionization 衰减量。
pub const IONIZATION_DECAY: f64 = 1.0;
/// ionization 上限(0..255)。
pub const IONIZATION_MAX: f64 = 255.0;

// ---- 介质击穿放电 step-cost 权重 -------------------------------------------
// 被 discharge_path.rs(Rust)与 ElectricDischargeKernel(Elixir)共享。

/// 放电路径中导电 cell 的成本权重。
pub const CONDUCTIVE_COST_WEIGHT: f64 = 0.5;
/// 放电路径中介质 cell 的成本权重。
pub const DIELECTRIC_COST_WEIGHT: f64 = 1.0;
/// ionization 对有效击穿阈值的折减权重。
pub const IONIZATION_THRESHOLD_WEIGHT: f64 = 0.05;
/// ionization 对放电 step cost 的折减权重。
pub const IONIZATION_COST_WEIGHT: f64 = 0.01;

// ---- 温度扩散 ---------------------------------------------------------------
// 被 temperature_diffusion.rs(Rust)与 TemperatureField(Elixir)共享。

/// 显式扩散稳定性上限:α 被 clamp 到该值。
pub const TEMPERATURE_ALPHA_MAX: f64 = 0.5;
/// fixed-32 定点 → 浮点的换算比例。
pub const FIXED32_SCALE: f64 = 65_536.0;
/// 缺省导热系数(fixed-32 原始整数)。
pub const DEFAULT_TC_RAW: i64 = 6_554;
/// 缺省密度(fixed-32 原始整数)。
pub const DEFAULT_DENSITY_RAW: i64 = 65_536;
/// 缺省比热容(fixed-32 原始整数)。
pub const DEFAULT_SPECIFIC_HEAT_CAPACITY_RAW: i64 = 65_536_000;
/// 密度浮点下限,避免热扩散率除零。
pub const MIN_DENSITY_FLOAT: f64 = 0.001;
/// 比热容浮点下限,避免热扩散率除零。
pub const MIN_SPECIFIC_HEAT_CAPACITY_FLOAT: f64 = 0.001;

// ---- 数值容差 ---------------------------------------------------------------

/// Dijkstra 松弛比较容差。被 conduction_path.rs / discharge_path.rs(Rust)与
/// ConductionPathKernel / ElectricDischargeKernel(Elixir,`@epsilon`)共享。
pub const EPSILON: f64 = 0.000001;
/// 电势传播 settle 比较容差。被 electric_potential.rs(Rust)与
/// ElectricField(Elixir,bfs_propagate 的 settle 比较)共享。
pub const STALE_EPSILON: f64 = 0.001;
