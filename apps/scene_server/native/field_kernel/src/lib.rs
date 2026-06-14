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

// BND-1(梯队2 step2.7b):电势传播句柄版——读 ionization_sim active(旧)→ **复用**无状态
// `propagate_electric_potential`(逐位等价)→ 写 potential_sim(merge put 绝对值)+ ionization_sim
// (clear aabb 再 put,与 Elixir `apply_cells`/`clear_layer_in_aabb` 等价)。两 sim 顺序锁(无同时
// 双锁,单 FieldTickWorker 顺序驱动)。
#[rustler::nif]
fn propagate_electric_potential_sim(
    potential_sim: cell_sim::FieldLayerSimArc,
    ionization_sim: cell_sim::FieldLayerSimArc,
    sources: Vec<electric_potential::Source>,
    entries: Vec<electric_potential::NativeEntry>,
    aabb: types::Aabb,
) -> Atom {
    // read-old:当前 ionization active(绝对值,= Elixir FieldLayer.active_cells(layer, aabb, 0))。
    let ionization_input: Vec<electric_potential::IonizationCell> = {
        let state = cell_sim::lock(&ionization_sim);
        cell_sim::active_cells(&state, aabb, 0.0)
    };

    let (potential_cells, new_ionization) =
        electric_potential::propagate_electric_potential(sources, entries, aabb, ionization_input);

    // potential:clear aabb 再 put 绝对值(= Elixir `get_layer |> clear_layer_in_aabb` 后 apply_cells,
    // 即 aabb 内替换;Dijkstra 每 tick 重算 potential 场)。
    {
        let mut state = cell_sim::lock(&potential_sim);
        state.clear_aabb(aabb);
        for (idx, value) in potential_cells {
            state.put_absolute(idx, value);
        }
    }

    // ionization:clear aabb 再 put 绝对值(= Elixir clear_layer_in_aabb |> apply_cells)。
    {
        let mut state = cell_sim::lock(&ionization_sim);
        state.clear_aabb(aabb);
        for (idx, value) in new_ionization {
            state.put_absolute(idx, value);
        }
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

// 梯队2 step2.7c(BND-1):旧无状态向量 NIF diffuse_temperature / propagate_electric_potential
// 已删(no dual-path)——统一走句柄版 *_sim(原地演化 cell_sim)。底层 stencil 计算函数
// `temperature_diffusion::diffuse_temperature` / `electric_potential::propagate_electric_potential`
// 仍被句柄版复用,保留。

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
