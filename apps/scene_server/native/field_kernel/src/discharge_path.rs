use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet};

use crate::grid;
use crate::types::Aabb;

// 介质击穿 step-cost 权重 + 数值容差来自 field 物理常量唯一真相源(见 field_constants.rs)。
use crate::field_constants::{
    CONDUCTIVE_COST_WEIGHT, DEFAULT_CONDUCTIVITY, DEFAULT_DIELECTRIC_STRENGTH,
    DIELECTRIC_COST_WEIGHT, EPSILON, IONIZATION_COST_WEIGHT, IONIZATION_THRESHOLD_WEIGHT,
    MIN_CONDUCTIVITY, MIN_STEP_COST,
};

pub(crate) type NativeCell = (u16, f64, f64);
pub(crate) type IonizationCell = (u16, f64);

#[derive(Debug, Clone, Copy)]
struct Cell {
    conductivity: f64,
    dielectric_strength: f64,
}

#[derive(Debug, Clone, Copy)]
struct QueueItem {
    cost: f64,
    macro_index: u16,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(crate) enum DischargePathError {
    FrontierExhausted,
    NoDischargePath,
}

impl Eq for QueueItem {}

impl PartialEq for QueueItem {
    fn eq(&self, other: &Self) -> bool {
        self.cost.to_bits() == other.cost.to_bits() && self.macro_index == other.macro_index
    }
}

impl Ord for QueueItem {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .cost
            .total_cmp(&self.cost)
            .then_with(|| other.macro_index.cmp(&self.macro_index))
    }
}

impl PartialOrd for QueueItem {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

pub(crate) fn find_discharge_path(
    cells: Vec<NativeCell>,
    aabb: Aabb,
    source_macro_index: u16,
    target_macro_index: u16,
    source_value: f64,
    ionization_cells: Vec<IonizationCell>,
    max_frontier: u32,
) -> Result<Vec<u16>, DischargePathError> {
    let source_coord = grid::macro_coord(source_macro_index);
    let target_coord = grid::macro_coord(target_macro_index);

    if !grid::in_aabb(source_coord, aabb) || !grid::in_aabb(target_coord, aabb) {
        return Err(DischargePathError::NoDischargePath);
    }

    let cell_map = build_cell_map(cells);
    let ionization = ionization_cells.into_iter().collect::<HashMap<_, _>>();
    let source_strength = source_value.abs();

    if !traversable_cell(&cell_map, &ionization, source_macro_index, source_strength)
        || !traversable_cell(&cell_map, &ionization, target_macro_index, source_strength)
    {
        return Err(DischargePathError::NoDischargePath);
    }

    dijkstra(
        &cell_map,
        &ionization,
        aabb,
        source_macro_index,
        target_macro_index,
        source_strength,
        max_frontier.max(1),
    )
}

fn build_cell_map(cells: Vec<NativeCell>) -> HashMap<u16, Cell> {
    cells
        .into_iter()
        .map(|(macro_index, conductivity, dielectric_strength)| {
            (
                macro_index,
                Cell {
                    conductivity,
                    dielectric_strength,
                },
            )
        })
        .collect()
}

fn dijkstra(
    cells: &HashMap<u16, Cell>,
    ionization: &HashMap<u16, f64>,
    aabb: Aabb,
    source_macro_index: u16,
    target_macro_index: u16,
    source_strength: f64,
    max_frontier: u32,
) -> Result<Vec<u16>, DischargePathError> {
    let mut queue = BinaryHeap::new();
    let mut costs = HashMap::new();
    let mut previous = HashMap::new();
    let mut settled = HashSet::new();
    let mut frontier_count = 0_u32;

    queue.push(QueueItem {
        cost: 0.0,
        macro_index: source_macro_index,
    });
    costs.insert(source_macro_index, 0.0);

    while let Some(item) = queue.pop() {
        if frontier_count >= max_frontier {
            return Err(DischargePathError::FrontierExhausted);
        }

        if settled.contains(&item.macro_index) {
            continue;
        }

        if item.macro_index == target_macro_index {
            return Ok(reconstruct_path(
                &previous,
                source_macro_index,
                item.macro_index,
            ));
        }

        if item.cost > *costs.get(&item.macro_index).unwrap_or(&f64::INFINITY) + EPSILON {
            continue;
        }

        settled.insert(item.macro_index);

        let mut neighbors = grid::neighbor_indices(grid::macro_coord(item.macro_index), aabb);
        neighbors.sort_unstable();

        for neighbor_macro_index in neighbors {
            if !traversable_cell(cells, ionization, neighbor_macro_index, source_strength) {
                continue;
            }

            let step_cost = step_cost(cells, ionization, neighbor_macro_index, source_strength);
            let candidate_cost = item.cost + step_cost;
            let known_cost = costs
                .get(&neighbor_macro_index)
                .copied()
                .unwrap_or(f64::INFINITY);

            if candidate_cost + EPSILON < known_cost {
                costs.insert(neighbor_macro_index, candidate_cost);
                previous.insert(neighbor_macro_index, item.macro_index);
                queue.push(QueueItem {
                    cost: candidate_cost,
                    macro_index: neighbor_macro_index,
                });
            }
        }

        frontier_count += 1;
    }

    Err(DischargePathError::NoDischargePath)
}

fn traversable_cell(
    cells: &HashMap<u16, Cell>,
    ionization: &HashMap<u16, f64>,
    macro_index: u16,
    source_strength: f64,
) -> bool {
    let conductivity = cells
        .get(&macro_index)
        .map(|cell| cell.conductivity)
        .unwrap_or(DEFAULT_CONDUCTIVITY);
    let threshold = effective_breakdown_threshold(cells, ionization, macro_index);

    conductivity >= MIN_CONDUCTIVITY || source_strength >= threshold
}

fn step_cost(
    cells: &HashMap<u16, Cell>,
    ionization: &HashMap<u16, f64>,
    macro_index: u16,
    source_strength: f64,
) -> f64 {
    let conductivity = cells
        .get(&macro_index)
        .map(|cell| cell.conductivity)
        .unwrap_or(DEFAULT_CONDUCTIVITY);
    let threshold = effective_breakdown_threshold(cells, ionization, macro_index);
    let ionization_value = ionization.get(&macro_index).copied().unwrap_or(0.0);

    let conductive_cost = if conductivity >= MIN_CONDUCTIVITY {
        CONDUCTIVE_COST_WEIGHT / conductivity.max(MIN_CONDUCTIVITY)
    } else {
        0.0
    };

    let dielectric_cost = if source_strength >= threshold {
        DIELECTRIC_COST_WEIGHT * threshold / source_strength.max(EPSILON)
    } else {
        DIELECTRIC_COST_WEIGHT * (threshold - source_strength + threshold)
    };

    (1.0 + conductive_cost + dielectric_cost - ionization_value * IONIZATION_COST_WEIGHT)
        .max(MIN_STEP_COST)
}

fn effective_breakdown_threshold(
    cells: &HashMap<u16, Cell>,
    ionization: &HashMap<u16, f64>,
    macro_index: u16,
) -> f64 {
    let dielectric_strength = cells
        .get(&macro_index)
        .map(|cell| cell.dielectric_strength)
        .unwrap_or(DEFAULT_DIELECTRIC_STRENGTH);
    let ionization_value = ionization.get(&macro_index).copied().unwrap_or(0.0);

    (dielectric_strength - ionization_value * IONIZATION_THRESHOLD_WEIGHT).max(0.0)
}

fn reconstruct_path(
    previous: &HashMap<u16, u16>,
    source_macro_index: u16,
    target_macro_index: u16,
) -> Vec<u16> {
    let mut current = target_macro_index;
    let mut path = vec![current];

    while current != source_macro_index {
        match previous.get(&current).copied() {
            Some(parent) => {
                current = parent;
                path.push(current);
            }
            None => break,
        }
    }

    path.reverse();
    path
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_discharge_through_empty_cells() {
        let path = find_discharge_path(
            vec![(0, 0.0, 3.0), (3, 1.0, 3.0)],
            ((0, 0, 0), (3, 0, 0)),
            0,
            3,
            120.0,
            vec![],
            32,
        )
        .unwrap();

        assert_eq!(path, vec![0, 1, 2, 3]);
    }

    #[test]
    fn rejects_under_threshold_discharge() {
        let result = find_discharge_path(
            vec![(0, 0.0, 3.0), (3, 1.0, 3.0)],
            ((0, 0, 0), (3, 0, 0)),
            0,
            3,
            2.0,
            vec![],
            32,
        );

        assert_eq!(result, Err(DischargePathError::NoDischargePath));
    }
}
