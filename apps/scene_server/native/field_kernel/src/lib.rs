mod conduction_path;
mod electric_potential;
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
