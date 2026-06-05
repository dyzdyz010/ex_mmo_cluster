mod conduction_path;
mod discharge_path;
mod electric_potential;
// field_constants:Field 物理权重常量的唯一真相源(Elixir/Rust 双端共享,见模块注释)。
mod field_constants;
mod grid;
mod temperature_diffusion;
mod types;

use rustler::Atom;

rustler::init!("Elixir.SceneServer.Native.FieldKernel");

rustler::atoms! {
    source_not_conductive,
    target_not_conductive,
    frontier_exhausted,
    unreachable,
    no_discharge_path,
}

// 调度约定(scene-rust-1):field_kernel 的全部 NIF 都是体素场上的图/网格算法
// (Dijkstra、BFS、温度扩散迭代、电势传播),输入规模由 macro grid 决定,
// 单次耗时极易 >1ms,且全部 CPU-bound、无 I/O,必须一律标 `schedule = "DirtyCpu"`,
// 否则会长时间占用 BEAM 普通调度器线程,破坏调度公平性与软实时性。

// find_conduction_path:BinaryHeap + HashMap 实现的 Dijkstra 最短导电路径搜索 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn find_conduction_path(
    entries: Vec<conduction_path::NativeEntry>,
    aabb: types::Aabb,
    source_macro_index: u16,
    target_macro_index: u16,
    source_value: f64,
    ionization_cells: Vec<conduction_path::IonizationCell>,
    max_frontier: u32,
) -> Result<Vec<u16>, Atom> {
    conduction_path::find_conduction_path(
        entries,
        aabb,
        source_macro_index,
        target_macro_index,
        source_value,
        ionization_cells,
        max_frontier,
    )
    .map_err(path_error_atom)
}

// find_discharge_path:在体素场上做放电路径搜索(图遍历) → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn find_discharge_path(
    cells: Vec<discharge_path::NativeCell>,
    aabb: types::Aabb,
    source_macro_index: u16,
    target_macro_index: u16,
    source_value: f64,
    ionization_cells: Vec<discharge_path::IonizationCell>,
    max_frontier: u32,
) -> Result<Vec<u16>, Atom> {
    discharge_path::find_discharge_path(
        cells,
        aabb,
        source_macro_index,
        target_macro_index,
        source_value,
        ionization_cells,
        max_frontier,
    )
    .map_err(discharge_path_error_atom)
}

// diffuse_temperature:逐 candidate 做邻居平均的温度扩散迭代,规模随候选集线性增长 → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn diffuse_temperature(
    cells: Vec<temperature_diffusion::TemperatureCell>,
    candidates: Vec<u16>,
    aabb: types::Aabb,
    thermal_properties: Vec<temperature_diffusion::ThermalProperties>,
    diffusion_seconds: f64,
    ambient_dt_seconds: f64,
    ambient_loss_per_second: f64,
    cell_size_meters: f64,
) -> Vec<temperature_diffusion::TemperatureCell> {
    temperature_diffusion::diffuse_temperature(
        cells,
        candidates,
        aabb,
        thermal_properties,
        diffusion_seconds,
        ambient_dt_seconds,
        ambient_loss_per_second,
        cell_size_meters,
    )
}

// propagate_electric_potential:在体素场上传播电势 + 计算电离(图传播 + BinaryHeap) → DirtyCpu。
#[rustler::nif(schedule = "DirtyCpu")]
fn propagate_electric_potential(
    sources: Vec<electric_potential::Source>,
    entries: Vec<electric_potential::NativeEntry>,
    aabb: types::Aabb,
    ionization_cells: Vec<electric_potential::IonizationCell>,
) -> electric_potential::ElectricPropagationResult {
    electric_potential::propagate_electric_potential(sources, entries, aabb, ionization_cells)
}

fn path_error_atom(error: conduction_path::PathError) -> Atom {
    match error {
        conduction_path::PathError::SourceNotConductive => source_not_conductive(),
        conduction_path::PathError::TargetNotConductive => target_not_conductive(),
        conduction_path::PathError::FrontierExhausted => frontier_exhausted(),
        conduction_path::PathError::Unreachable => unreachable(),
    }
}

fn discharge_path_error_atom(error: discharge_path::DischargePathError) -> Atom {
    match error {
        discharge_path::DischargePathError::FrontierExhausted => frontier_exhausted(),
        discharge_path::DischargePathError::NoDischargePath => no_discharge_path(),
    }
}
