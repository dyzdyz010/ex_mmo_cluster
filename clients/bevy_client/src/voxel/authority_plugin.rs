//! `VoxelAuthorityPlugin` (M1.8c) — the ECS bridge that drives the pure
//! [`VoxelAuthorityStore`] from network voxel messages.
//!
//! The net layer ([`crate::net::plugin`]) decodes `0x60–0x75` frames into
//! `NetworkEvent::Voxel` and enqueues them here (thin glue — no domain logic in
//! net). This plugin's system drains the inbox and ingests each message into
//! the store (version-gated), which marks touched chunks dirty. The render
//! system (M2b) then re-meshes exactly the dirty chunks.
//!
//! The pure store stays Bevy-free; this wrapper resource holds the Bevy-facing
//! inbox and is the only place the two meet.

use bevy::prelude::*;

use crate::app::schedule::ClientSet;
use crate::login::AppState;
use crate::net::{NetworkBridge, NetworkCommand};
use crate::voxel::authority::{ChunkCoord, IngestOutcome, VoxelAuthorityStore};
use crate::voxel::field_view::VoxelFieldStore;
use crate::voxel::wire::VoxelServerMessage;

/// Logical scene the client subscribes voxels in (mirrors net::plugin; single
/// scene for now).
const VOXEL_LOGICAL_SCENE_ID: u64 = 1;

/// Bevy resource wrapping the pure authority stores plus an inbox the net layer
/// pushes decoded voxel messages into.
///
/// Two parallel pure stores, fed from the same inbox: `store` holds chunk truth
/// (snapshot/delta/invalidate + object state) for the ChunkMesh / SurfaceDecal
/// render sub-layers; `field_store` (C3) holds the Phase-6 local-field stream
/// (0x73/0x74) for the FieldView render sub-layer. They never couple — each is
/// driven independently from its own message kinds.
///
/// `resync_requests` collects chunks whose delta base forked from the held
/// version (so the held mesh is stale); `ingest_voxel_messages` drains it and
/// re-subscribes those chunks (radius-0, want_snapshot) so the server re-streams
/// a fresh snapshot — otherwise a stationary client would render stale truth
/// indefinitely.
#[derive(Resource, Default)]
pub struct VoxelAuthority {
    pub store: VoxelAuthorityStore,
    pub field_store: VoxelFieldStore,
    inbox: Vec<VoxelServerMessage>,
    resync_requests: Vec<ChunkCoord>,
}

impl VoxelAuthority {
    /// Queues a decoded voxel message for ingestion next `ingest_voxel_messages`
    /// run. Called by the net layer; deliberately does no domain work.
    pub fn enqueue(&mut self, message: VoxelServerMessage) {
        self.inbox.push(message);
    }

    /// Drains the inbox, routing each message to its store: field-stream messages
    /// (0x73/0x74) feed the field store; everything else feeds the chunk store
    /// (version-gated). Returns nothing — the render systems read the touched/dirty
    /// sets from the stores. Pure (no Bevy), so the ECS system and tests share it.
    pub(crate) fn drain_inbox(&mut self) {
        if self.inbox.is_empty() {
            return;
        }
        let inbox = std::mem::take(&mut self.inbox);
        for message in inbox {
            match &message {
                // C3: field stream drives the field store (FieldView render
                // sub-layer), never the chunk store — independent truth sources.
                VoxelServerMessage::FieldRegionSnapshot(snapshot) => {
                    self.field_store.apply_snapshot(snapshot.clone());
                }
                VoxelServerMessage::FieldRegionDestroyed(destroyed) => {
                    self.field_store.apply_destroyed(destroyed);
                }
                // Everything else is chunk truth (snapshot/delta/invalidate/object
                // state) or a catalog patch the chunk store version-gates / ignores.
                _ => match self.store.ingest(&message) {
                    Ok(IngestOutcome::Resync(coord)) => {
                        // Version-gate failed: the held chunk forked from the
                        // server's delta base. Queue a targeted re-subscribe so
                        // the server re-streams a fresh snapshot (otherwise the
                        // chunk stays stale until an unrelated AOI re-subscribe).
                        warn!("voxel chunk {coord:?} needs resync (delta base mismatch)");
                        self.resync_requests.push(coord);
                    }
                    Ok(_) => {}
                    Err(error) => {
                        warn!("voxel ingest rejected: {}", error.0);
                    }
                },
            }
        }
    }

    /// Drains the pending resync coords (deduped + sorted). The ECS system feeds
    /// these to the net bridge as targeted re-subscribes.
    pub(crate) fn take_resync_requests(&mut self) -> Vec<ChunkCoord> {
        if self.resync_requests.is_empty() {
            return Vec::new();
        }
        let mut coords = std::mem::take(&mut self.resync_requests);
        coords.sort_unstable();
        coords.dedup();
        coords
    }
}

pub struct VoxelAuthorityPlugin;

impl Plugin for VoxelAuthorityPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<VoxelAuthority>().add_systems(
            Update,
            ingest_voxel_messages
                .in_set(ClientSet::Logic)
                .run_if(in_state(AppState::Game)),
        );
    }
}

fn ingest_voxel_messages(
    mut authority: ResMut<VoxelAuthority>,
    bridge: Option<Res<NetworkBridge>>,
) {
    authority.drain_inbox();

    // Re-subscribe forked chunks (radius-0 = just that chunk, want_snapshot) so
    // the server re-streams fresh truth. Deduped per drain; if the server keeps
    // sending mismatched deltas this re-requests each frame until resolved
    // (acceptable — radius-0 is cheap; finer rate-limiting is a follow-up).
    let resyncs = authority.take_resync_requests();
    if let Some(bridge) = bridge {
        for coord in resyncs {
            bridge.send(NetworkCommand::SubscribeChunks {
                logical_scene_id: VOXEL_LOGICAL_SCENE_ID,
                center_chunk: coord,
                radius: 0,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::{
        ChunkDelta, ChunkSnapshot, FIELD_MASK_TEMPERATURE, FieldRegionDestroyed,
        FieldRegionSnapshot, Reader,
    };

    fn snapshot(name: &str) -> ChunkSnapshot {
        let golden = crate::voxel::wire::fixtures::golden(name);
        ChunkSnapshot::decode(&mut Reader::new(&golden)).unwrap()
    }

    #[test]
    fn enqueue_then_ingest_populates_store() {
        // Drive the exact pure path the system uses, without spinning up an App.
        let mut authority = VoxelAuthority::default();
        let snap = snapshot("snapshot_full");
        let coord = snap.chunk_coord;
        authority.enqueue(VoxelServerMessage::ChunkSnapshot(snap));
        authority.drain_inbox();

        assert_eq!(authority.store.chunk_count(), 1);
        assert!(authority.store.chunk(coord).is_some());
        assert_eq!(authority.store.take_dirty(), vec![coord]);
    }

    #[test]
    fn delta_for_unsynced_chunk_queues_a_resync_request() {
        // #8: a delta whose base can't be version-gated (unknown/forked chunk)
        // must surface a resync request so the system can re-subscribe it, instead
        // of being silently logged-and-dropped.
        let mut authority = VoxelAuthority::default();
        let delta_a = ChunkDelta {
            logical_scene_id: 1,
            chunk_coord: [3, 0, -1],
            base_chunk_version: 5,
            new_chunk_version: 6,
            ops: vec![],
        };
        // Same forked chunk twice → deduped to one resync request.
        authority.enqueue(VoxelServerMessage::ChunkDelta(delta_a.clone()));
        authority.enqueue(VoxelServerMessage::ChunkDelta(delta_a));
        authority.drain_inbox();

        assert_eq!(authority.take_resync_requests(), vec![[3, 0, -1]]);
        // Drained — a second call is empty until a new fork occurs.
        assert!(authority.take_resync_requests().is_empty());
    }

    #[test]
    fn field_stream_routes_to_field_store_not_chunk_store() {
        // C3:0x73/0x74 必须落入 field_store(FieldView 子层),不污染 chunk store。
        let mut authority = VoxelAuthority::default();
        let region = FieldRegionSnapshot {
            logical_scene_id: 1,
            chunk_coord: [2, 0, -1],
            region_id: 99,
            tick_count: 5,
            field_mask: FIELD_MASK_TEMPERATURE,
            macro_indices: vec![0, 17],
            temperature: vec![120.0, 300.0],
            electric_potential: vec![],
            electric_current: vec![],
            ionization: vec![],
        };
        authority.enqueue(VoxelServerMessage::FieldRegionSnapshot(region));
        authority.drain_inbox();

        // Landed in field store, marked dirty; chunk store untouched.
        assert_eq!(authority.field_store.region_count(), 1);
        assert_eq!(authority.field_store.region(99).unwrap().tick_count, 5);
        assert_eq!(authority.field_store.take_dirty(), vec![99]);
        assert_eq!(authority.store.chunk_count(), 0);
        assert!(authority.store.take_dirty().is_empty());

        // Destroy drops the region (still marks dirty so the overlay despawns).
        authority.enqueue(VoxelServerMessage::FieldRegionDestroyed(
            FieldRegionDestroyed {
                logical_scene_id: 1,
                chunk_coord: [2, 0, -1],
                region_id: 99,
                destroy_reason: 0,
            },
        ));
        authority.drain_inbox();
        assert_eq!(authority.field_store.region_count(), 0);
        assert_eq!(authority.field_store.take_dirty(), vec![99]);
    }
}
