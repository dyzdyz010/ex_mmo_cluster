//! Client-side voxel **map cache**: persists the authority store's chunks to disk
//! so a returning session loads the map locally and re-subscribes advertising the
//! chunk versions it already holds (`ChunkSubscribe.known[]`). The server then
//! streams only changed / new chunks — a startup *diff* — instead of the whole
//! world on every launch.
//!
//! Serialisation reuses the existing wire codec (`wire::{NormalBlock, RefinedCell}`
//! already expose `encode`/`decode`; the flat `SurfaceElement` is hand-rolled), so
//! no serde / extra binary-format dependency is pulled in. The on-disk layout:
//!
//! ```text
//! magic u32 "VMC1" | chunk_count u32 |
//! chunk[]{ cx i32, cy i32, cz i32, version u64, size u8,
//!          cell_count u32, cell[]{ tag u8; 1→NormalBlock, 2→RefinedCell },
//!          se_count u16, se[]{ macro u16, face u8, type u16, attr u32, tag u32, owner u64 } }
//! ```

use std::path::PathBuf;
use std::time::Duration;

use bevy::prelude::*;

use crate::protocol::ProtocolError;
use crate::voxel::authority::{AuthorityChunk, CellState, ChunkCoord, VoxelAuthorityStore};
use crate::voxel::authority_plugin::{VOXEL_LOGICAL_SCENE_ID, VoxelAuthority};
use crate::voxel::wire::{NormalBlock, Reader, RefinedCell, SurfaceElement, Writer};

/// "VMC1" — map-cache format magic + version. Bump on any layout change so an old
/// cache is rejected (→ full re-stream) rather than mis-decoded.
const CACHE_MAGIC: u32 = 0x_564D_4331;

/// How often the loaded map is flushed to disk while playing.
const SAVE_INTERVAL: Duration = Duration::from_secs(20);

#[derive(Resource)]
struct MapCacheSaveTimer(Timer);

pub struct MapCachePlugin;

impl Plugin for MapCachePlugin {
    fn build(&self, app: &mut App) {
        app.insert_resource(MapCacheSaveTimer(Timer::new(
            SAVE_INTERVAL,
            TimerMode::Repeating,
        )))
        // Seed the store from disk before the network thread / first subscribe, so
        // the persisted map both renders immediately and populates `known[]`.
        .add_systems(PreStartup, load_map_cache)
        .add_systems(Update, save_map_cache_periodic)
        .add_systems(Last, save_map_cache_on_exit);
    }
}

fn cache_path(scene_id: u64) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join(".demo")
        .join("voxel_cache")
        .join(format!("scene_{scene_id}.vmc"))
}

fn load_map_cache(mut authority: ResMut<VoxelAuthority>) {
    let path = cache_path(VOXEL_LOGICAL_SCENE_ID);
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(_) => return, // first run / no cache — nothing to load.
    };
    match decode_cache(&bytes) {
        Ok(chunks) => {
            let mut seeded = 0usize;
            for (coord, chunk) in chunks {
                if authority.store.seed_chunk(coord, chunk) {
                    seeded += 1;
                }
            }
            info!(
                "voxel map cache: seeded {seeded} chunks from {}",
                path.display()
            );
        }
        Err(error) => warn!("voxel map cache: ignoring unreadable cache ({error})"),
    }
}

fn save_map_cache_periodic(
    time: Res<Time>,
    mut timer: ResMut<MapCacheSaveTimer>,
    authority: Res<VoxelAuthority>,
) {
    if timer.0.tick(time.delta()).just_finished() {
        save_cache(&authority);
    }
}

fn save_map_cache_on_exit(mut exits: MessageReader<AppExit>, authority: Res<VoxelAuthority>) {
    if exits.read().next().is_some() {
        save_cache(&authority);
    }
}

fn save_cache(authority: &VoxelAuthority) {
    if authority.store.chunk_count() == 0 {
        return; // nothing loaded yet — don't clobber a good cache with an empty one.
    }
    let bytes = encode_cache(&authority.store);
    let path = cache_path(VOXEL_LOGICAL_SCENE_ID);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Err(error) = std::fs::write(&path, &bytes) {
        warn!("voxel map cache: save failed: {error}");
    }
}

pub(crate) fn encode_cache(store: &VoxelAuthorityStore) -> Vec<u8> {
    let mut w = Writer::new();
    w.u32(CACHE_MAGIC);
    let coords = store.chunk_coords();
    w.u32(coords.len() as u32);
    for coord in coords {
        let Some(chunk) = store.chunk(coord) else {
            continue;
        };
        w.i32(coord[0]);
        w.i32(coord[1]);
        w.i32(coord[2]);
        w.u64(chunk.chunk_version);
        w.u8(chunk.chunk_size_in_macro);
        w.u32(chunk.cells.len() as u32);
        for cell in &chunk.cells {
            match cell {
                CellState::Empty => w.u8(0),
                CellState::Solid(block) => {
                    w.u8(1);
                    block.encode(&mut w);
                }
                CellState::Refined(refined) => {
                    w.u8(2);
                    refined.encode(&mut w);
                }
            }
        }
        w.u16(chunk.surface_elements.len() as u16);
        for se in &chunk.surface_elements {
            w.u16(se.macro_index);
            w.u8(se.face);
            w.u16(se.surface_type_id);
            w.u32(se.attribute_set_ref);
            w.u32(se.tag_set_ref);
            w.u64(se.owner_actor_id);
        }
    }
    w.into_bytes()
}

pub(crate) fn decode_cache(bytes: &[u8]) -> Result<Vec<(ChunkCoord, AuthorityChunk)>, ProtocolError> {
    let mut r = Reader::new(bytes);
    let magic = r.u32("cache.magic")?;
    if magic != CACHE_MAGIC {
        return Err(ProtocolError(format!(
            "voxel cache magic {magic:#010x} != {CACHE_MAGIC:#010x}"
        )));
    }
    let chunk_count = r.u32("cache.chunk_count")? as usize;
    let mut out = Vec::with_capacity(chunk_count);
    for _ in 0..chunk_count {
        let coord = [r.i32("cache.cx")?, r.i32("cache.cy")?, r.i32("cache.cz")?];
        let chunk_version = r.u64("cache.version")?;
        let chunk_size_in_macro = r.u8("cache.size")?;
        let cell_count = r.u32("cache.cell_count")? as usize;
        let mut cells = Vec::with_capacity(cell_count);
        for _ in 0..cell_count {
            let tag = r.u8("cache.cell_tag")?;
            cells.push(match tag {
                0 => CellState::Empty,
                1 => CellState::Solid(NormalBlock::decode(&mut r)?),
                2 => CellState::Refined(RefinedCell::decode(&mut r)?),
                other => {
                    return Err(ProtocolError(format!("voxel cache bad cell tag {other}")));
                }
            });
        }
        let se_count = r.u16("cache.se_count")? as usize;
        let mut surface_elements = Vec::with_capacity(se_count);
        for _ in 0..se_count {
            surface_elements.push(SurfaceElement {
                macro_index: r.u16("cache.se.macro_index")?,
                face: r.u8("cache.se.face")?,
                surface_type_id: r.u16("cache.se.surface_type_id")?,
                attribute_set_ref: r.u32("cache.se.attribute_set_ref")?,
                tag_set_ref: r.u32("cache.se.tag_set_ref")?,
                owner_actor_id: r.u64("cache.se.owner_actor_id")?,
            });
        }
        out.push((
            coord,
            AuthorityChunk {
                chunk_version,
                chunk_size_in_macro,
                cells,
                surface_elements,
            },
        ));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_empty_solid_and_surface_elements() {
        let mut store = VoxelAuthorityStore::new();
        let mut cells = vec![CellState::Empty; 4096];
        cells[5] = CellState::Solid(NormalBlock {
            material_id: 2,
            state_flags: 0,
            health: 100,
            temperature_delta: 0,
            moisture_delta: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0,
        });
        store.seed_chunk(
            [1, 0, -2],
            AuthorityChunk {
                chunk_version: 6161,
                chunk_size_in_macro: 16,
                cells,
                surface_elements: vec![SurfaceElement {
                    macro_index: 7,
                    face: 3,
                    surface_type_id: 4,
                    attribute_set_ref: 0,
                    tag_set_ref: 0,
                    owner_actor_id: 0,
                }],
            },
        );

        let bytes = encode_cache(&store);
        let decoded = decode_cache(&bytes).expect("round-trip");
        assert_eq!(decoded.len(), 1);
        let (coord, chunk) = &decoded[0];
        assert_eq!(*coord, [1, 0, -2]);
        assert_eq!(chunk.chunk_version, 6161);
        assert_eq!(chunk.cells.len(), 4096);
        assert_eq!(chunk.cells[5], CellState::Solid(NormalBlock {
            material_id: 2,
            state_flags: 0,
            health: 100,
            temperature_delta: 0,
            moisture_delta: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0,
        }));
        assert_eq!(chunk.surface_elements.len(), 1);
        assert_eq!(chunk.surface_elements[0].surface_type_id, 4);
    }

    #[test]
    fn rejects_bad_magic() {
        assert!(decode_cache(&[0, 0, 0, 0, 0, 0, 0, 0]).is_err());
    }
}
