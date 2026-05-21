use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashMap, HashSet};

use crate::grid;
use crate::types::{Aabb, Coord};

pub(crate) type FaceContacts = (u64, u64, u64, u64, u64, u64);
pub(crate) type NativeComponent = (u8, FaceContacts);
pub(crate) type NativeEntry = (u16, f64, f64, Vec<NativeComponent>);
pub(crate) type IonizationCell = (u16, f64);

const FACE_X_NEG: u8 = 0;
const FACE_X_POS: u8 = 1;
const FACE_Y_NEG: u8 = 2;
const FACE_Y_POS: u8 = 3;
const FACE_Z_NEG: u8 = 4;
const FACE_Z_POS: u8 = 5;
const FACE_SOURCE: u8 = 6;
const FACE_COUNT: usize = 6;

const DEFAULT_CONDUCTIVITY: f64 = 0.0;
const DEFAULT_DIELECTRIC_STRENGTH: f64 = 3.0;
const MIN_CONDUCTIVITY: f64 = 0.001;
const RESISTANCE_WEIGHT: f64 = 4.0;
const BREAKDOWN_WEIGHT: f64 = 0.25;
const IONIZATION_BONUS_WEIGHT: f64 = 0.01;
const MIN_STEP_COST: f64 = 0.05;
const EPSILON: f64 = 0.000001;

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
    cost: f64,
    state: State,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub(crate) enum PathError {
    SourceNotConductive,
    TargetNotConductive,
    FrontierExhausted,
    Unreachable,
}

impl Eq for QueueItem {}

impl PartialEq for QueueItem {
    fn eq(&self, other: &Self) -> bool {
        self.cost.to_bits() == other.cost.to_bits() && self.state == other.state
    }
}

impl Ord for QueueItem {
    fn cmp(&self, other: &Self) -> Ordering {
        other
            .cost
            .total_cmp(&self.cost)
            .then_with(|| other.state.cmp(&self.state))
    }
}

impl PartialOrd for QueueItem {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

pub(crate) fn find_conduction_path(
    entries: Vec<NativeEntry>,
    aabb: Aabb,
    source_macro_index: u16,
    target_macro_index: u16,
    source_value: f64,
    ionization_cells: Vec<IonizationCell>,
    max_frontier: u32,
) -> Result<Vec<u16>, PathError> {
    let projection = build_projection(entries);

    if !projection.contains_key(&source_macro_index) {
        return Err(PathError::SourceNotConductive);
    }

    if !projection.contains_key(&target_macro_index) {
        return Err(PathError::TargetNotConductive);
    }

    let ionization = ionization_cells.into_iter().collect::<HashMap<_, _>>();
    let max_frontier = max_frontier.max(1);

    dijkstra(
        &projection,
        &ionization,
        aabb,
        source_macro_index,
        target_macro_index,
        source_value.abs(),
        max_frontier,
    )
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

fn dijkstra(
    projection: &HashMap<u16, Entry>,
    ionization: &HashMap<u16, f64>,
    aabb: Aabb,
    source_macro_index: u16,
    target_macro_index: u16,
    source_strength: f64,
    max_frontier: u32,
) -> Result<Vec<u16>, PathError> {
    let source_state = State {
        macro_index: source_macro_index,
        entry_face: FACE_SOURCE,
        entry_contacts: 0,
    };

    let mut queue = BinaryHeap::new();
    let mut costs = HashMap::new();
    let mut previous = HashMap::new();
    let mut settled = HashSet::new();
    let mut frontier_count = 0_u32;

    queue.push(QueueItem {
        cost: 0.0,
        state: source_state,
    });
    costs.insert(source_state, 0.0);

    while let Some(item) = queue.pop() {
        if frontier_count >= max_frontier {
            return Err(PathError::FrontierExhausted);
        }

        if settled.contains(&item.state) {
            continue;
        }

        if item.state.macro_index == target_macro_index {
            return Ok(reconstruct_path(&previous, source_state, item.state));
        }

        if item.cost > *costs.get(&item.state).unwrap_or(&f64::INFINITY) + EPSILON {
            continue;
        }

        settled.insert(item.state);

        for neighbor_state in neighbor_states(projection, aabb, item.state) {
            let step_cost = step_cost(
                projection,
                ionization,
                neighbor_state.macro_index,
                source_strength,
            );
            let candidate_cost = item.cost + step_cost;
            let known_cost = costs.get(&neighbor_state).copied().unwrap_or(f64::INFINITY);

            if candidate_cost + EPSILON < known_cost {
                costs.insert(neighbor_state, candidate_cost);
                previous.insert(neighbor_state, item.state);
                queue.push(QueueItem {
                    cost: candidate_cost,
                    state: neighbor_state,
                });
            }
        }

        frontier_count += 1;
    }

    Err(PathError::Unreachable)
}

fn reconstruct_path(
    previous: &HashMap<State, State>,
    source_state: State,
    target_state: State,
) -> Vec<u16> {
    let mut current = target_state;
    let mut states = vec![current];

    while current != source_state {
        match previous.get(&current).copied() {
            Some(parent) => {
                current = parent;
                states.push(current);
            }
            None => break,
        }
    }

    states.reverse();
    states.into_iter().map(|state| state.macro_index).collect()
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
            1.0,
            3.0,
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
    fn finds_sorted_neighbor_path() {
        let entries = vec![
            solid_entry(grid::macro_index((0, 1, 0))),
            solid_entry(grid::macro_index((0, 0, 0))),
            solid_entry(grid::macro_index((1, 0, 0))),
            solid_entry(grid::macro_index((2, 0, 0))),
            solid_entry(grid::macro_index((3, 0, 0))),
            solid_entry(grid::macro_index((3, 1, 0))),
        ];

        let path = find_conduction_path(
            entries,
            ((0, 0, 0), (3, 1, 0)),
            grid::macro_index((0, 1, 0)),
            grid::macro_index((3, 1, 0)),
            120.0,
            vec![],
            512,
        )
        .unwrap();

        assert_eq!(
            path,
            vec![
                grid::macro_index((0, 1, 0)),
                grid::macro_index((0, 0, 0)),
                grid::macro_index((1, 0, 0)),
                grid::macro_index((2, 0, 0)),
                grid::macro_index((3, 0, 0)),
                grid::macro_index((3, 1, 0)),
            ]
        );
    }

    #[test]
    fn respects_frontier_budget() {
        let entries = vec![
            solid_entry(grid::macro_index((0, 0, 0))),
            solid_entry(grid::macro_index((1, 0, 0))),
        ];

        let result = find_conduction_path(
            entries,
            ((0, 0, 0), (1, 0, 0)),
            grid::macro_index((0, 0, 0)),
            grid::macro_index((1, 0, 0)),
            120.0,
            vec![],
            1,
        );

        assert_eq!(result, Err(PathError::FrontierExhausted));
    }
}
