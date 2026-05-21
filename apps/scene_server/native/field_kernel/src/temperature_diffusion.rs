use std::collections::HashMap;

use crate::grid;
use crate::types::Aabb;

pub(crate) type TemperatureCell = (u16, f64);
pub(crate) type ThermalProperties = (u16, i64, i64, i64);

const TEMPERATURE_ALPHA_MAX: f64 = 0.5;
const FIXED32_SCALE: f64 = 65_536.0;
const DEFAULT_TC_RAW: i64 = 6_554;
const DEFAULT_DENSITY_RAW: i64 = 65_536;
const DEFAULT_SPECIFIC_HEAT_CAPACITY_RAW: i64 = 65_536_000;
const MIN_DENSITY_FLOAT: f64 = 0.001;
const MIN_SPECIFIC_HEAT_CAPACITY_FLOAT: f64 = 0.001;

pub(crate) fn diffuse_temperature(
    cells: Vec<TemperatureCell>,
    candidates: Vec<u16>,
    aabb: Aabb,
    thermal_properties: Vec<ThermalProperties>,
    diffusion_seconds: f64,
    ambient_dt_seconds: f64,
    ambient_loss_per_second: f64,
    cell_size_meters: f64,
) -> Vec<TemperatureCell> {
    let values = cells.into_iter().collect::<HashMap<_, _>>();
    let thermal_properties = thermal_properties
        .into_iter()
        .map(
            |(macro_index, thermal_conductivity, density, specific_heat_capacity)| {
                (
                    macro_index,
                    (thermal_conductivity, density, specific_heat_capacity),
                )
            },
        )
        .collect::<HashMap<_, _>>();

    let diffusion_seconds = diffusion_seconds.max(0.0);
    let ambient_dt_seconds = ambient_dt_seconds.max(0.0);
    let ambient_loss_per_second = ambient_loss_per_second.max(0.0);
    let cell_size_meters = cell_size_meters.max(f64::EPSILON);

    candidates
        .into_iter()
        .map(|macro_index| {
            let current_delta = values.get(&macro_index).copied().unwrap_or(0.0);
            let neighbor_avg_delta = neighbor_avg_delta(&values, aabb, macro_index);
            let alpha = alpha_for(
                &thermal_properties,
                macro_index,
                diffusion_seconds,
                cell_size_meters,
            );

            let new_delta = current_delta + alpha * (neighbor_avg_delta - current_delta);
            let new_delta =
                apply_ambient_loss(new_delta, ambient_dt_seconds, ambient_loss_per_second);

            (macro_index, new_delta)
        })
        .collect()
}

fn neighbor_avg_delta(values: &HashMap<u16, f64>, aabb: Aabb, idx: u16) -> f64 {
    let coord = grid::macro_coord(idx);

    let sum: f64 = [
        (coord.0.wrapping_sub(1), coord.1, coord.2),
        (coord.0 + 1, coord.1, coord.2),
        (coord.0, coord.1.wrapping_sub(1), coord.2),
        (coord.0, coord.1 + 1, coord.2),
        (coord.0, coord.1, coord.2.wrapping_sub(1)),
        (coord.0, coord.1, coord.2 + 1),
    ]
    .iter()
    .map(|&neighbor| {
        if grid::local_macro_coord(neighbor) && grid::in_aabb(neighbor, aabb) {
            values
                .get(&grid::macro_index(neighbor))
                .copied()
                .unwrap_or(0.0)
        } else {
            0.0
        }
    })
    .sum();

    sum / 6.0
}

fn alpha_for(
    thermal_properties: &HashMap<u16, (i64, i64, i64)>,
    idx: u16,
    diffusion_seconds: f64,
    cell_size_meters: f64,
) -> f64 {
    let (thermal_conductivity, density, specific_heat_capacity) =
        thermal_properties.get(&idx).copied().unwrap_or((
            DEFAULT_TC_RAW,
            DEFAULT_DENSITY_RAW,
            DEFAULT_SPECIFIC_HEAT_CAPACITY_RAW,
        ));

    let thermal_conductivity = fixed32_to_float(thermal_conductivity);
    let density = fixed32_to_float(density).max(MIN_DENSITY_FLOAT);
    let specific_heat_capacity =
        fixed32_to_float(specific_heat_capacity).max(MIN_SPECIFIC_HEAT_CAPACITY_FLOAT);
    let diffusivity = thermal_conductivity / (density * specific_heat_capacity);

    (diffusivity * diffusion_seconds / (cell_size_meters * cell_size_meters))
        .max(0.0)
        .min(TEMPERATURE_ALPHA_MAX)
}

fn fixed32_to_float(raw: i64) -> f64 {
    raw as f64 / FIXED32_SCALE
}

fn apply_ambient_loss(delta: f64, dt_seconds: f64, loss_per_second: f64) -> f64 {
    if loss_per_second <= 0.0 {
        delta
    } else {
        delta * (-loss_per_second * dt_seconds).exp()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diffuses_sparse_temperature_delta_to_neighbors() {
        let source = grid::macro_index((3, 3, 3));
        let neighbor = grid::macro_index((4, 3, 3));

        let result = diffuse_temperature(
            vec![(source, 480.0)],
            vec![source, neighbor],
            ((0, 0, 0), (7, 7, 7)),
            vec![
                (
                    source,
                    DEFAULT_TC_RAW,
                    DEFAULT_DENSITY_RAW,
                    DEFAULT_SPECIFIC_HEAT_CAPACITY_RAW,
                ),
                (
                    neighbor,
                    DEFAULT_TC_RAW,
                    DEFAULT_DENSITY_RAW,
                    DEFAULT_SPECIFIC_HEAT_CAPACITY_RAW,
                ),
            ],
            0.1,
            0.1,
            0.0,
            1.0,
        )
        .into_iter()
        .collect::<HashMap<_, _>>();

        assert!(result.get(&source).copied().unwrap() < 480.0);
        assert!(result.get(&neighbor).copied().unwrap() > 0.0);
        assert!(result.get(&neighbor).copied().unwrap() < 0.01);
    }
}
