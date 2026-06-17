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
    ChunkDelta, ChunkInvalidate, ChunkSnapshot, DeltaCell, NormalBlock, ObjectStateDelta,
    RefinedCell, SurfaceElement, VoxelServerMessage,
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

/// One authoritative chunk: its version, the flattened per-macro-cell array, and
/// the zero-volume surface elements bound to its macro faces (section 0x08).
///
/// `surface_elements` is chunk truth (mirrors the server `Storage`): a separate
/// render input from `cells` (the SurfaceDecal render sub-layer reads it; the
/// ChunkMesh layer reads `cells`). It only arrives via snapshot — the server
/// resends a full snapshot on surface-element change — so deltas preserve it.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct AuthorityChunk {
    pub chunk_version: u64,
    pub chunk_size_in_macro: u8,
    pub cells: Vec<CellState>,
    pub surface_elements: Vec<SurfaceElement>,
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
    /// C2: an object's logical state advanced (ObjectStateDelta). Its affected
    /// chunks were marked dirty so the renderer refreshes the changed cells.
    ObjectStateApplied(u64),
    /// C2: ObjectStateDelta with a non-newer `object_version` (duplicate / out of
    /// order) — deduped, no state change.
    ObjectStateStale(u64),
    /// Not chunk truth (catalog/field stream) — no chunk store change.
    Ignored,
}

/// C2: client-tracked per-object logical state (mirrors the server
/// `ObjectRegistry` instance state the client needs). `version` dedupes the
/// monotonic `object_version`; `state_flags` is the latest event's bits
/// (damaged / part_destroyed / destroyed), which the render layer maps to
/// visuals (debris / part hide) in a later step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ObjectStateRecord {
    pub version: u64,
    pub state_flags: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IngestError(pub String);

#[derive(Debug, Default)]
pub struct VoxelAuthorityStore {
    chunks: HashMap<ChunkCoord, AuthorityChunk>,
    dirty: HashSet<ChunkCoord>,
    objects: HashMap<u64, ObjectStateRecord>,
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
            VoxelServerMessage::ObjectStateDelta(delta) => Ok(self.apply_object_state_delta(delta)),
            // Catalog/field streams are gameplay inputs (later milestones), not
            // chunk truth; the chunk store ignores them.
            _ => Ok(IngestOutcome::Ignored),
        }
    }

    /// C2: consumes an `ObjectStateDelta`. Dedupes by monotonic `object_version`
    /// (a re-sent / out-of-order event with a non-newer version is ignored), then
    /// records the object's state and marks its `affected_chunks` dirty so the
    /// renderer refreshes the changed cells. The destroyed micro cells themselves
    /// arrive via snapshot/delta; this is the logical-state + refresh signal.
    pub fn apply_object_state_delta(&mut self, delta: &ObjectStateDelta) -> IngestOutcome {
        let is_newer = match self.objects.get(&delta.object_id) {
            Some(record) => delta.object_version > record.version,
            None => true,
        };

        if !is_newer {
            return IngestOutcome::ObjectStateStale(delta.object_id);
        }

        self.objects.insert(
            delta.object_id,
            ObjectStateRecord {
                version: delta.object_version,
                state_flags: delta.state_flags,
            },
        );

        for coord in &delta.affected_chunks {
            self.dirty.insert(*coord);
        }

        IngestOutcome::ObjectStateApplied(delta.object_id)
    }

    /// C2: the latest tracked logical state of an object (None if unseen).
    pub fn object_state(&self, object_id: u64) -> Option<&ObjectStateRecord> {
        self.objects.get(&object_id)
    }

    pub fn apply_snapshot(&mut self, snap: &ChunkSnapshot) -> Result<IngestOutcome, IngestError> {
        let coord = snap.chunk_coord;
        let cells = flatten_snapshot(snap)?;
        let surface_elements = snap.surface_elements().unwrap_or(&[]).to_vec();
        self.chunks.insert(
            coord,
            AuthorityChunk {
                chunk_version: snap.chunk_version,
                chunk_size_in_macro: snap.chunk_size_in_macro,
                cells,
                surface_elements,
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

    // Trust-boundary check: the mesher indexes `cells` by `chunk_size_in_macro^3`
    // (a wire-sourced u8). A malformed / truncated / adversarial snapshot whose
    // header count disagrees would later panic the render system on an
    // out-of-range index, so reject it here rather than storing a chunk the
    // mesher can't safely index. (A well-formed server always sends exactly
    // size^3 headers.)
    let size = snap.chunk_size_in_macro as usize;
    let expected = size.checked_pow(3).unwrap_or(usize::MAX);
    if size == 0 || headers.len() != expected {
        return Err(IngestError(format!(
            "snapshot macro header count {} != chunk_size_in_macro^3 ({} for size {})",
            headers.len(),
            expected,
            size
        )));
    }

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
    fn snapshot_surface_elements_land_in_chunk_truth() {
        // C1:表面元件经 snapshot 落入 AuthorityChunk.surface_elements(渲染子层的输入)。
        let snap = decode_snapshot("snapshot_surface_elements");
        let mut store = VoxelAuthorityStore::new();
        store
            .ingest(&VoxelServerMessage::ChunkSnapshot(snap.clone()))
            .unwrap();

        let chunk = store.chunk(snap.chunk_coord).expect("chunk present");
        assert_eq!(chunk.surface_elements.len(), 3);
        // 与 wire parity 测一致:类型 id [1,2,4] = rust_decal/frost/torch。
        let mut type_ids: Vec<u16> = chunk
            .surface_elements
            .iter()
            .map(|e| e.surface_type_id)
            .collect();
        type_ids.sort_unstable();
        assert_eq!(type_ids, vec![1, 2, 4]);
    }

    #[test]
    fn snapshot_with_header_count_mismatch_is_rejected_not_panicked() {
        // Robustness: a snapshot whose chunk_size_in_macro disagrees with its
        // actual header count must be refused at ingest, so the mesher (which
        // indexes cells by size^3) can never panic on an out-of-range index.
        let mut snap = decode_snapshot("snapshot_empty"); // size 16, 4096 headers
        snap.chunk_size_in_macro = 17; // 17^3 = 4913 != 4096
        let mut store = VoxelAuthorityStore::new();
        let result = store.ingest(&VoxelServerMessage::ChunkSnapshot(snap.clone()));
        assert!(matches!(result, Err(IngestError(_))), "got {result:?}");
        assert!(store.chunk(snap.chunk_coord).is_none());
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
    fn object_state_delta_tracks_state_dedups_and_marks_affected_chunks_dirty() {
        // C2:消费 ObjectStateDelta golden(object_version 42,affected [{0,0,0},{1,0,0}],
        // state_flags=destroyed)。证:记录对象状态 + 标记受影响 chunk dirty + 版本去重。
        let golden = crate::voxel::wire::fixtures::golden("object_state_delta_destroyed");
        let delta = ObjectStateDelta::decode(&mut Reader::new(&golden)).unwrap();
        let object_id = delta.object_id;

        let mut store = VoxelAuthorityStore::new();
        assert_eq!(
            store.ingest(&VoxelServerMessage::ObjectStateDelta(delta.clone())),
            Ok(IngestOutcome::ObjectStateApplied(object_id))
        );

        let record = store.object_state(object_id).expect("object tracked");
        assert_eq!(record.version, delta.object_version);
        assert_eq!(record.state_flags, delta.state_flags);

        // 受影响 chunk 被标 dirty(渲染据此刷新)。
        let mut dirty = store.take_dirty();
        dirty.sort_unstable();
        let mut expected = delta.affected_chunks.clone();
        expected.sort_unstable();
        assert_eq!(dirty, expected);

        // 重发同版本 → 去重(stale),无状态变化、无 dirty。
        assert_eq!(
            store.ingest(&VoxelServerMessage::ObjectStateDelta(delta)),
            Ok(IngestOutcome::ObjectStateStale(object_id))
        );
        assert!(store.take_dirty().is_empty());
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
