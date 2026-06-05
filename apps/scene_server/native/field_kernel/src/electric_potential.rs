use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet};

use crate::grid;
use crate::types::{Aabb, Coord};

// ionization tick 演化 + step-cost 权重 + settle 容差来自 field 物理常量唯一真相源
// (见 field_constants.rs)。
use crate::field_constants::{
    BREAKDOWN_WEIGHT, DEFAULT_CONDUCTIVITY, DEFAULT_DIELECTRIC_STRENGTH, IONIZATION_BONUS_WEIGHT,
    IONIZATION_DECAY, IONIZATION_GROWTH, IONIZATION_MAX, IONIZATION_THRESHOLD, MIN_CONDUCTIVITY,
    MIN_STEP_COST, RESISTANCE_WEIGHT, STALE_EPSILON,
};

pub(crate) type Source = (u16, f64);
pub(crate) type FaceContacts = (u64, u64, u64, u64, u64, u64);
pub(crate) type NativeComponent = (u8, FaceContacts);
pub(crate) type NativeEntry = (u16, f64, f64, Vec<NativeComponent>);
pub(crate) type IonizationCell = (u16, f64);
pub(crate) type PotentialCell = (u16, f64);
pub(crate) type ElectricPropagationResult = (Vec<PotentialCell>, Vec<IonizationCell>);

// FACE_* / FACE_COUNT 是纯 Rust 内部的网格面编码,没有 Elixir 副本,保留本地定义。
const FACE_X_NEG: u8 = 0;
const FACE_X_POS: u8 = 1;
const FACE_Y_NEG: u8 = 2;
const FACE_Y_POS: u8 = 3;
const FACE_Z_NEG: u8 = 4;
const FACE_Z_POS: u8 = 5;
const FACE_SOURCE: u8 = 6;
const FACE_COUNT: usize = 6;

#[derive(Debug, Clone)]
struct Component {
    face_mask: u8,
    contacts: [u64; FACE_COUNT],
}

#[derive(Debug, Clone)]
struct Entry {
    conductivity: f64,
    dielectric_strength: f64,
    components: Vec<Component>,
    face_contacts: [u64; FACE_COUNT],
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Hash, Ord, PartialOrd)]
struct State {
    macro_index: u16,
    entry_face: u8,
    entry_contacts: u64,
}

#[derive(Debug, Clone, Copy)]
struct QueueItem {
    potential: f64,
    state: State,
}

impl Eq for QueueItem {}

impl PartialEq for QueueItem {
    fn eq(&self, other: &Self) -> bool {
        self.potential.to_bits() == other.potential.to_bits() && self.state == other.state
    }
}

impl Ord for QueueItem {
    fn cmp(&self, other: &Self) -> Ordering {
        self.potential
            .total_cmp(&other.potential)
            .then_with(|| other.state.cmp(&self.state))
    }
}

impl PartialOrd for QueueItem {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

pub(crate) fn propagate_electric_potential(
    sources: Vec<Source>,
    entries: Vec<NativeEntry>,
    aabb: Aabb,
    ionization_cells: Vec<IonizationCell>,
) -> ElectricPropagationResult {
    let projection = build_projection(entries);
    let ionization = ionization_cells.into_iter().collect::<HashMap<_, _>>();
    let source_map = source_map(sources, &projection);
    let visited = propagate(&source_map, &projection, &ionization, aabb);
    let best_potential_by_cell = best_potential_by_cell(&visited);

    let mut potential_cells = best_potential_by_cell
        .iter()
        .filter_map(|(&macro_index, &potential)| {
            if potential > 0.0 {
                Some((macro_index, potential))
            } else {
                None
            }
        })
        .collect::<Vec<_>>();

    potential_cells.sort_by_key(|(macro_index, _)| *macro_index);

    let mut ionization_cells = grid::aabb_indices(aabb)
        .into_iter()
        .filter_map(|macro_index| {
            let potential = best_potential_by_cell
                .get(&macro_index)
                .copied()
                .unwrap_or(0.0);
            let current_ionization = ionization.get(&macro_index).copied().unwrap_or(0.0);

            let new_ionization = if potential.abs() >= IONIZATION_THRESHOLD {
                (current_ionization + IONIZATION_GROWTH).min(IONIZATION_MAX)
            } else {
                (current_ionization - IONIZATION_DECAY).max(0.0)
            };

            if new_ionization > 0.0 {
                Some((macro_index, new_ionization))
            } else {
                None
            }
        })
        .collect::<Vec<_>>();

    ionization_cells.sort_by_key(|(macro_index, _)| *macro_index);
    (potential_cells, ionization_cells)
}

fn source_map(sources: Vec<Source>, projection: &HashMap<u16, Entry>) -> HashMap<u16, f64> {
    sources
        .into_iter()
        .filter(|(macro_index, value)| *value > 0.0 && projection.contains_key(macro_index))
        .fold(HashMap::new(), |mut acc, (macro_index, value)| {
            acc.entry(macro_index)
                .and_modify(|previous| *previous = previous.max(value))
                .or_insert(value);
            acc
        })
}

fn propagate(
    source_map: &HashMap<u16, f64>,
    projection: &HashMap<u16, Entry>,
    ionization: &HashMap<u16, f64>,
    aabb: Aabb,
) -> HashMap<State, f64> {
    let mut queue = BinaryHeap::new();
    let mut visited = HashMap::new();
    let mut settled = HashSet::new();

    for (&macro_index, &potential) in source_map {
        let state = State {
            macro_index,
            entry_face: FACE_SOURCE,
            entry_contacts: 0,
        };
        visited.insert(state, potential);
        queue.push(QueueItem { potential, state });
    }

    while let Some(item) = queue.pop() {
        if settled.contains(&item.state) {
            continue;
        }

        if visited.get(&item.state).copied().unwrap_or(0.0) > item.potential + STALE_EPSILON {
            continue;
        }

        settled.insert(item.state);

        for neighbor_state in neighbor_states(projection, aabb, item.state) {
            let step_cost = step_cost(
                projection,
                ionization,
                neighbor_state.macro_index,
                item.potential.abs(),
            );
            let neighbor_potential = item.potential - step_cost;

            if neighbor_potential > 0.0
                && neighbor_potential > visited.get(&neighbor_state).copied().unwrap_or(0.0)
            {
                visited.insert(neighbor_state, neighbor_potential);
                queue.push(QueueItem {
                    potential: neighbor_potential,
                    state: neighbor_state,
                });
            }
        }
    }

    visited
}

fn best_potential_by_cell(visited: &HashMap<State, f64>) -> HashMap<u16, f64> {
    visited
        .iter()
        .fold(HashMap::new(), |mut acc, (state, potential)| {
            acc.entry(state.macro_index)
                .and_modify(|previous| *previous = f64::max(*previous, *potential))
                .or_insert(*potential);
            acc
        })
}

fn build_projection(entries: Vec<NativeEntry>) -> HashMap<u16, Entry> {
    entries
        .into_iter()
        .filter_map(
            |(macro_index, conductivity, dielectric_strength, components)| {
                let components = components
                    .into_iter()
                    .map(|(face_mask, contacts)| Component {
                        face_mask,
                        contacts: contacts_to_array(contacts),
                    })
                    .collect::<Vec<_>>();

                if components.is_empty() {
                    None
                } else {
                    let face_contacts =
                        components
                            .iter()
                            .fold([0_u64; FACE_COUNT], |mut acc, component| {
                                for (face, contacts) in component.contacts.iter().enumerate() {
                                    acc[face] |= contacts;
                                }
                                acc
                            });

                    Some((
                        macro_index,
                        Entry {
                            conductivity,
                            dielectric_strength,
                            components,
                            face_contacts,
                        },
                    ))
                }
            },
        )
        .collect()
}

fn contacts_to_array(contacts: FaceContacts) -> [u64; FACE_COUNT] {
    [
        contacts.0, contacts.1, contacts.2, contacts.3, contacts.4, contacts.5,
    ]
}

fn neighbor_states(projection: &HashMap<u16, Entry>, aabb: Aabb, state: State) -> Vec<State> {
    let current_coord = grid::macro_coord(state.macro_index);
    let mut neighbors = grid::neighbor_indices(current_coord, aabb);
    neighbors.sort_unstable();

    neighbors
        .into_iter()
        .filter_map(|neighbor_macro_index| {
            let neighbor_coord = grid::macro_coord(neighbor_macro_index);
            let (exit_face, neighbor_entry_face) = shared_faces(current_coord, neighbor_coord)?;

            let shared_contacts = electric_contact_transfer(
                projection,
                state.macro_index,
                state.entry_face,
                state.entry_contacts,
                exit_face,
                neighbor_macro_index,
                neighbor_entry_face,
            );

            if shared_contacts == 0 {
                None
            } else {
                Some(State {
                    macro_index: neighbor_macro_index,
                    entry_face: neighbor_entry_face,
                    entry_contacts: shared_contacts,
                })
            }
        })
        .collect()
}

fn electric_contact_transfer(
    projection: &HashMap<u16, Entry>,
    current_macro_index: u16,
    entry_face: u8,
    entry_contacts: u64,
    exit_face: u8,
    neighbor_macro_index: u16,
    neighbor_entry_face: u8,
) -> u64 {
    let reachable = reachable_face_contacts(
        projection,
        current_macro_index,
        entry_face,
        entry_contacts,
        exit_face,
    );

    if reachable == 0 {
        return 0;
    }

    projection
        .get(&neighbor_macro_index)
        .map(|entry| reachable & entry.face_contacts[neighbor_entry_face as usize])
        .unwrap_or(0)
}

fn reachable_face_contacts(
    projection: &HashMap<u16, Entry>,
    macro_index: u16,
    entry_face: u8,
    entry_contacts: u64,
    exit_face: u8,
) -> u64 {
    let Some(entry) = projection.get(&macro_index) else {
        return 0;
    };

    entry
        .components
        .iter()
        .filter(|component| component_has_face(component, exit_face))
        .filter(|component| {
            entry_face == FACE_SOURCE
                || (component_has_face(component, entry_face)
                    && (component.contacts[entry_face as usize] & entry_contacts) != 0)
        })
        .fold(0_u64, |acc, component| {
            acc | component.contacts[exit_face as usize]
        })
}

fn component_has_face(component: &Component, face: u8) -> bool {
    face < FACE_SOURCE && (component.face_mask & (1 << face)) != 0
}

fn step_cost(
    projection: &HashMap<u16, Entry>,
    ionization: &HashMap<u16, f64>,
    macro_index: u16,
    source_strength: f64,
) -> f64 {
    let (conductivity, dielectric_strength) = projection
        .get(&macro_index)
        .map(|entry| (entry.conductivity, entry.dielectric_strength))
        .unwrap_or((DEFAULT_CONDUCTIVITY, DEFAULT_DIELECTRIC_STRENGTH));

    let resistance_cost = RESISTANCE_WEIGHT / conductivity.max(MIN_CONDUCTIVITY);
    let breakdown_cost = if source_strength > 0.0 {
        if source_strength >= dielectric_strength {
            BREAKDOWN_WEIGHT * dielectric_strength / source_strength
        } else {
            BREAKDOWN_WEIGHT * (dielectric_strength - source_strength) + dielectric_strength
        }
    } else {
        dielectric_strength
    };
    let ionization_bonus =
        ionization.get(&macro_index).copied().unwrap_or(0.0) * IONIZATION_BONUS_WEIGHT;

    (1.0 + resistance_cost + breakdown_cost - ionization_bonus).max(MIN_STEP_COST)
}

fn shared_faces(current: Coord, neighbor: Coord) -> Option<(u8, u8)> {
    let (x, y, z) = current;
    let (nx, ny, nz) = neighbor;

    if ny == y && nz == z && nx + 1 == x {
        Some((FACE_X_NEG, FACE_X_POS))
    } else if ny == y && nz == z && nx == x + 1 {
        Some((FACE_X_POS, FACE_X_NEG))
    } else if nx == x && nz == z && ny + 1 == y {
        Some((FACE_Y_NEG, FACE_Y_POS))
    } else if nx == x && nz == z && ny == y + 1 {
        Some((FACE_Y_POS, FACE_Y_NEG))
    } else if nx == x && ny == y && nz + 1 == z {
        Some((FACE_Z_NEG, FACE_Z_POS))
    } else if nx == x && ny == y && nz == z + 1 {
        Some((FACE_Z_POS, FACE_Z_NEG))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL_CONTACTS: u64 = u64::MAX;
    const ALL_FACES: u8 = 0b0011_1111;

    fn solid_entry(index: u16) -> NativeEntry {
        (
            index,
            10.0,
            0.0,
            vec![(
                ALL_FACES,
                (
                    ALL_CONTACTS,
                    ALL_CONTACTS,
                    ALL_CONTACTS,
                    ALL_CONTACTS,
                    ALL_CONTACTS,
                    ALL_CONTACTS,
                ),
            )],
        )
    }

    #[test]
    fn propagates_potential_and_ionization_through_conductive_projection() {
        let source = grid::macro_index((0, 0, 0));
        let neighbor = grid::macro_index((1, 0, 0));

        let (potential, ionization) = propagate_electric_potential(
            vec![(source, 100.0)],
            vec![solid_entry(source), solid_entry(neighbor)],
            ((0, 0, 0), (3, 3, 3)),
            vec![],
        );

        let potential = potential.into_iter().collect::<HashMap<_, _>>();
        let ionization = ionization.into_iter().collect::<HashMap<_, _>>();

        assert_eq!(potential.get(&source).copied().unwrap(), 100.0);
        assert!(potential.get(&neighbor).copied().unwrap() > 0.0);
        assert!(potential.get(&neighbor).copied().unwrap() < 100.0);
        assert_eq!(ionization.get(&source).copied().unwrap(), 5.0);
    }

    #[test]
    fn does_not_spread_without_projected_conductive_edges() {
        let source = grid::macro_index((0, 0, 0));
        let neighbor = grid::macro_index((1, 0, 0));

        let (potential, _ionization) = propagate_electric_potential(
            vec![(source, 100.0)],
            vec![solid_entry(source)],
            ((0, 0, 0), (3, 3, 3)),
            vec![],
        );

        let potential = potential.into_iter().collect::<HashMap<_, _>>();
        assert!(potential.contains_key(&source));
        assert!(!potential.contains_key(&neighbor));
    }
}
