mod cell_sim;
mod conduction_path;
mod discharge_path;
mod electric_potential;
mod grid;
mod temperature_diffusion;
mod types;

use rustler::Atom;

rustler::init!("Elixir.SceneServer.Native.FieldKernel");

rustler::atoms! {
    ok,
    source_not_conductive,
    target_not_conductive,
    frontier_exhausted,
    unreachable,
    no_discharge_path,
}

// ---------------------------------------------------------------------------
// BND-1(梯队2 step2.7a):场层本体常驻 Rust ResourceArc<FieldLayerSim> 脚手架 NIF。
// 本步仅暴露 new/put/get/active_cells,未接 Elixir FieldLayer(原子 flip 在 2.7c)。
// ---------------------------------------------------------------------------

#[rustler::nif]
fn cell_sim_new(baseline: f64, threshold: f64, quantization: String) -> cell_sim::FieldLayerSimArc {
    cell_sim::new(baseline, threshold, cell_sim::parse_quant(&quantization))
}

#[rustler::nif]
fn cell_sim_put(sim: cell_sim::FieldLayerSimArc, macro_index: u16, value: f64) -> Atom {
    let mut state = cell_sim::lock(&sim);
    let baseline = state.baseline;
    state.put_delta(macro_index, value - baseline);
    ok()
}

#[rustler::nif]
fn cell_sim_get(sim: cell_sim::FieldLayerSimArc, macro_index: u16) -> f64 {
    let state = cell_sim::lock(&sim);
    state.baseline + state.get_delta(macro_index)
}

#[rustler::nif]
fn cell_sim_active_cells(
    sim: cell_sim::FieldLayerSimArc,
    aabb: types::Aabb,
    epsilon: f64,
) -> Vec<(u16, f64)> {
    let state = cell_sim::lock(&sim);
    cell_sim::active_cells(&state, aabb, epsilon)
}

// BND-1(梯队2 step2.7b):温度扩散句柄版——读 CellSim active 缓冲(旧)→ **复用**无状态
// `diffuse_temperature` stencil(逐位等价旧路径)→ 原地 apply(双缓冲:全算入 Vec 再 apply,
// 邻居读全取旧态)。数据不再每 tick 进出序列化(BND-1/NIF-3)。
#[rustler::nif]
fn diffuse_temperature_sim(
    sim: cell_sim::FieldLayerSimArc,
    candidates: Vec<u16>,
    aabb: types::Aabb,
    thermal_properties: Vec<temperature_diffusion::ThermalProperties>,
    diffusion_seconds: f64,
    ambient_dt_seconds: f64,
    ambient_loss_per_second: f64,
    cell_size_meters: f64,
) -> Atom {
    let mut state = cell_sim::lock(&sim);

    // read-old:取当前稀疏 delta 作 stencil 输入(邻居读全基于旧态)。
    let cells: Vec<temperature_diffusion::TemperatureCell> =
        state.values.iter().map(|(&k, &v)| (k, v)).collect();

    // 复用与旧 NIF 完全相同的 stencil 计算(保证逐位数值等价)。
    let new_deltas = temperature_diffusion::diffuse_temperature(
        cells,
        candidates,
        aabb,
        thermal_properties,
        diffusion_seconds,
        ambient_dt_seconds,
        ambient_loss_per_second,
        cell_size_meters,
    );

    // write-new:原地 apply(put_delta 量化/稀疏,与 Elixir FieldLayer.put_delta 等价)。
    for (idx, delta) in new_deltas {
        state.put_delta(idx, delta);
    }

    ok()
}

#[rustler::nif]
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

#[rustler::nif]
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

#[rustler::nif]
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

#[rustler::nif]
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
