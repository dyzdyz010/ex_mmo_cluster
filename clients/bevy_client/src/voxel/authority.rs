//! Server-authoritative voxel store: ingests decoded [`VoxelServerMessage`]s
//! into a per-chunk, per-macro-cell truth the mesher (M2) can query.
//!
//! Strict authority discipline (ported from the web client, the reference
//! oracle): the store starts empty, is mutated **only** by `ChunkSnapshot` /
//! `ChunkDelta` / `ChunkInvalidate`, never fabricates authoritative writes, and
//! applies deltas only when `base_chunk_version` matches the held version
//! (otherwise it asks the caller to resync). Touched chunks are marked dirty so
//! the renderer re-meshes only what changed.
//!
//! This is pure logic (no Bevy, no sockets) — the ECS `VoxelAuthorityPlugin`
//! (M1.8c) drives it from network events and feeds the dirty set to meshing.

use std::collections::{HashMap, HashSet};

use crate::voxel::wire::{
    ChunkDelta, ChunkInvalidate, ChunkSnapshot, DeltaCell, NormalBlock, RefinedCell,
    VoxelServerMessage,
};

pub type ChunkCoord = [i32; 3];

// Macro cell modes (mirror `SceneServer.Voxel.MacroCellHeader`).
const MODE_EMPTY: u8 = 0;
const MODE_SOLID: u8 = 1;
const MODE_REFINED: u8 = 2;

/// Resolved state of one macro cell (payload dereferenced from the snapshot
/// pools), indexed by `macro_index` within a chunk.
#[derive(Debug, Clone, PartialEq)]
pub enum CellState {
    Empty,
    Solid(NormalBlock),
    Refined(RefinedCell),
}

/// One authoritative chunk: its version and the flattened per-macro-cell array.
#[derive(Debug, Clone, PartialEq)]
pub struct AuthorityChunk {
    pub chunk_version: u64,
    pub chunk_size_in_macro: u8,
    pub cells: Vec<CellState>,
}

impl AuthorityChunk {
    pub fn cell(&self, macro_index: usize) -> Option<&CellState> {
        self.cells.get(macro_index)
    }
}

/// What ingesting a message did, so the caller can drive resubscribe/remesh.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IngestOutcome {
    /// Chunk truth changed (snapshot applied or delta applied).
    Applied(ChunkCoord),
    /// Delta `base_chunk_version` didn't match (or chunk unknown) — the caller
    /// should resubscribe/request a fresh snapshot for this chunk.
    Resync(ChunkCoord),
    /// Chunk dropped (invalidate); the renderer should clear it.
    Dropped(ChunkCoord),
    /// Not chunk truth (object/catalog/field stream) — no chunk store change.
    Ignored,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IngestError(pub String);

#[derive(Debug, Default)]
pub struct VoxelAuthorityStore {
    chunks: HashMap<ChunkCoord, AuthorityChunk>,
    dirty: HashSet<ChunkCoord>,
}

impl VoxelAuthorityStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn chunk(&self, coord: ChunkCoord) -> Option<&AuthorityChunk> {
        self.chunks.get(&coord)
    }

    pub fn chunk_count(&self) -> usize {
        self.chunks.len()
    }

    /// All loaded chunk coordinates (for status/diagnostics).
    pub fn chunk_coords(&self) -> Vec<ChunkCoord> {
        self.chunks.keys().copied().collect()
    }

    /// Drains the set of chunks touched since the last call — the mesher
    /// re-meshes exactly these (and, later, their border neighbors).
    pub fn take_dirty(&mut self) -> Vec<ChunkCoord> {
        let mut dirty: Vec<ChunkCoord> = self.dirty.drain().collect();
        dirty.sort_unstable();
        dirty
    }

    pub fn ingest(&mut self, msg: &VoxelServerMessage) -> Result<IngestOutcome, IngestError> {
        match msg {
            VoxelServerMessage::ChunkSnapshot(snap) => self.apply_snapshot(snap),
            VoxelServerMessage::ChunkDelta(delta) => self.apply_delta(delta),
            VoxelServerMessage::ChunkInvalidate(inv) => Ok(self.apply_invalidate(inv)),
            // Object/catalog/field streams are gameplay inputs (M5), not chunk
            // truth; the chunk store ignores them.
            _ => Ok(IngestOutcome::Ignored),
        }
    }

    pub fn apply_snapshot(&mut self, snap: &ChunkSnapshot) -> Result<IngestOutcome, IngestError> {
        let coord = snap.chunk_coord;
        let cells = flatten_snapshot(snap)?;
        self.chunks.insert(
            coord,
            AuthorityChunk {
                chunk_version: snap.chunk_version,
                chunk_size_in_macro: snap.chunk_size_in_macro,
                cells,
            },
        );
        self.dirty.insert(coord);
        Ok(IngestOutcome::Applied(coord))
    }

    pub fn apply_delta(&mut self, delta: &ChunkDelta) -> Result<IngestOutcome, IngestError> {
        let coord = delta.chunk_coord;
        let Some(chunk) = self.chunks.get_mut(&coord) else {
            // Unknown chunk → can't version-gate; ask to resync.
            return Ok(IngestOutcome::Resync(coord));
        };
        if chunk.chunk_version != delta.base_chunk_version {
            // Stale/forked base → drop and resync rather than corrupt truth.
            return Ok(IngestOutcome::Resync(coord));
        }
        for op in &delta.ops {
            let idx = op.macro_index as usize;
            if idx >= chunk.cells.len() {
                return Err(IngestError(format!(
                    "delta macro_index {idx} out of range (chunk has {} cells)",
                    chunk.cells.len()
                )));
            }
            match &op.cell {
                DeltaCell::Empty => chunk.cells[idx] = CellState::Empty,
                DeltaCell::Solid(block) => chunk.cells[idx] = CellState::Solid(block.clone()),
                DeltaCell::Refined(cell) => chunk.cells[idx] = CellState::Refined(cell.clone()),
                // Forward-compat: unknown delta kind leaves the cell unchanged.
                DeltaCell::Opaque { .. } => {}
            }
        }
        chunk.chunk_version = delta.new_chunk_version;
        self.dirty.insert(coord);
        Ok(IngestOutcome::Applied(coord))
    }

    pub fn apply_invalidate(&mut self, inv: &ChunkInvalidate) -> IngestOutcome {
        let coord = inv.chunk_coord;
        self.chunks.remove(&coord);
        // Mark dirty so the renderer clears the (now absent) chunk's mesh.
        self.dirty.insert(coord);
        IngestOutcome::Dropped(coord)
    }
}

/// Dereferences a snapshot's macro headers against its payload pools into a
/// flat per-cell array the mesher can index by `macro_index`.
fn flatten_snapshot(snap: &ChunkSnapshot) -> Result<Vec<CellState>, IngestError> {
    let headers = snap
        .macro_headers()
        .ok_or_else(|| IngestError("snapshot missing macro headers section".into()))?;
    let normal_blocks = snap.normal_blocks().unwrap_or(&[]);
    let refined_cells = snap.refined_cells().unwrap_or(&[]);

    headers
        .iter()
        .map(|header| match header.mode {
            MODE_EMPTY => Ok(CellState::Empty),
            MODE_SOLID => normal_blocks
                .get(header.payload_index as usize)
                .cloned()
                .map(CellState::Solid)
                .ok_or_else(|| {
                    IngestError(format!(
                        "solid macro payload_index {} out of range ({} normal blocks)",
                        header.payload_index,
                        normal_blocks.len()
                    ))
                }),
            MODE_REFINED => refined_cells
                .get(header.payload_index as usize)
                .cloned()
                .map(CellState::Refined)
                .ok_or_else(|| {
                    IngestError(format!(
                        "refined macro payload_index {} out of range ({} refined cells)",
                        header.payload_index,
                        refined_cells.len()
                    ))
                }),
            other => Err(IngestError(format!("unknown macro cell mode {other}"))),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::{ChunkInvalidate, DeltaOp, Reader};

    fn decode_snapshot(name: &str) -> ChunkSnapshot {
        let golden = crate::voxel::wire::fixtures::golden(name);
        ChunkSnapshot::decode(&mut Reader::new(&golden)).unwrap()
    }

    #[test]
    fn ingests_full_snapshot_and_flattens_cells() {
        let snap = decode_snapshot("snapshot_full");
        let mut store = VoxelAuthorityStore::new();
        assert_eq!(
            store.ingest(&VoxelServerMessage::ChunkSnapshot(snap.clone())),
            Ok(IngestOutcome::Applied(snap.chunk_coord))
        );

        let chunk = store.chunk(snap.chunk_coord).expect("chunk present");
        assert_eq!(chunk.chunk_version, snap.chunk_version);
        assert_eq!(chunk.cells.len(), 4096);
        // snapshot_full populates every section, so it has solid + refined cells.
        assert!(chunk.cells.iter().any(|c| matches!(c, CellState::Solid(_))));
        assert!(
            chunk
                .cells
                .iter()
                .any(|c| matches!(c, CellState::Refined(_)))
        );
        assert!(chunk.cells.iter().any(|c| matches!(c, CellState::Empty)));
        // Snapshot marked the chunk dirty.
        assert_eq!(store.take_dirty(), vec![snap.chunk_coord]);
        assert!(store.take_dirty().is_empty());
    }

    #[test]
    fn empty_snapshot_is_all_empty_cells() {
        let snap = decode_snapshot("snapshot_empty");
        let mut store = VoxelAuthorityStore::new();
        store
            .ingest(&VoxelServerMessage::ChunkSnapshot(snap.clone()))
            .unwrap();
        let chunk = store.chunk(snap.chunk_coord).unwrap();
        assert_eq!(chunk.cells.len(), 4096);
        assert!(chunk.cells.iter().all(|c| matches!(c, CellState::Empty)));
    }

    #[test]
    fn version_gated_delta_applies_then_rejects_stale() {
        let snap = decode_snapshot("snapshot_empty");
        let coord = snap.chunk_coord;
        let base = snap.chunk_version;
        let mut store = VoxelAuthorityStore::new();
        store
            .ingest(&VoxelServerMessage::ChunkSnapshot(snap))
            .unwrap();
        store.take_dirty();

        let solid = NormalBlock {
            material_id: 5,
            state_flags: 0,
            health: 100,
            temperature_delta: 0,
            moisture_delta: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0,
        };
        let delta = ChunkDelta {
            logical_scene_id: 0,
            chunk_coord: coord,
            base_chunk_version: base,
            new_chunk_version: base + 1,
            ops: vec![DeltaOp {
                macro_index: 7,
                cell_version: 1,
                cell_hash: 0,
                cell: DeltaCell::Solid(solid.clone()),
            }],
        };
        // Matching base → applied, cell updated, version advanced.
        assert_eq!(
            store.ingest(&VoxelServerMessage::ChunkDelta(delta.clone())),
            Ok(IngestOutcome::Applied(coord))
        );
        let chunk = store.chunk(coord).unwrap();
        assert_eq!(chunk.chunk_version, base + 1);
        assert_eq!(chunk.cell(7), Some(&CellState::Solid(solid)));
        assert_eq!(store.take_dirty(), vec![coord]);

        // Re-applying the same (now stale) base → resync, no mutation.
        assert_eq!(
            store.ingest(&VoxelServerMessage::ChunkDelta(delta)),
            Ok(IngestOutcome::Resync(coord))
        );
        assert!(store.take_dirty().is_empty());
    }

    #[test]
    fn delta_for_unknown_chunk_requests_resync() {
        let mut store = VoxelAuthorityStore::new();
        let delta = ChunkDelta {
            logical_scene_id: 0,
            chunk_coord: [9, 9, 9],
            base_chunk_version: 0,
            new_chunk_version: 1,
            ops: vec![],
        };
        assert_eq!(
            store.ingest(&VoxelServerMessage::ChunkDelta(delta)),
            Ok(IngestOutcome::Resync([9, 9, 9]))
        );
    }

    #[test]
    fn invalidate_drops_chunk_and_marks_dirty() {
        let snap = decode_snapshot("snapshot_empty");
        let coord = snap.chunk_coord;
        let mut store = VoxelAuthorityStore::new();
        store
            .ingest(&VoxelServerMessage::ChunkSnapshot(snap))
            .unwrap();
        store.take_dirty();

        let inv = ChunkInvalidate {
            logical_scene_id: 0,
            chunk_coord: coord,
            reason: 0,
        };
        assert_eq!(
            store.ingest(&VoxelServerMessage::ChunkInvalidate(inv)),
            Ok(IngestOutcome::Dropped(coord))
        );
        assert!(store.chunk(coord).is_none());
        assert_eq!(store.take_dirty(), vec![coord]);
    }
}
