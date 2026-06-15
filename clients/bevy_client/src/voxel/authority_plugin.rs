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
use crate::voxel::authority::{IngestOutcome, VoxelAuthorityStore};
use crate::voxel::wire::VoxelServerMessage;

/// Bevy resource wrapping the pure authority store plus an inbox the net layer
/// pushes decoded voxel messages into.
#[derive(Resource, Default)]
pub struct VoxelAuthority {
    pub store: VoxelAuthorityStore,
    inbox: Vec<VoxelServerMessage>,
}

impl VoxelAuthority {
    /// Queues a decoded voxel message for ingestion next `ingest_voxel_messages`
    /// run. Called by the net layer; deliberately does no domain work.
    pub fn enqueue(&mut self, message: VoxelServerMessage) {
        self.inbox.push(message);
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

fn ingest_voxel_messages(mut authority: ResMut<VoxelAuthority>) {
    if authority.inbox.is_empty() {
        return;
    }
    // Take the inbox so the store borrow below doesn't alias the inbox field.
    let inbox = std::mem::take(&mut authority.inbox);
    for message in inbox {
        match authority.store.ingest(&message) {
            Ok(IngestOutcome::Resync(coord)) => {
                // Version-gate failed: the held chunk forked from the server's
                // delta base. M2b/M1.8d will trigger a resubscribe; for now log.
                debug!("voxel chunk {coord:?} needs resync (delta base mismatch)");
            }
            Ok(_) => {}
            Err(error) => {
                warn!("voxel ingest rejected: {}", error.0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voxel::wire::{ChunkSnapshot, Reader};

    fn snapshot(name: &str) -> ChunkSnapshot {
        let golden = crate::voxel::wire::fixtures::golden(name);
        ChunkSnapshot::decode(&mut Reader::new(&golden)).unwrap()
    }

    #[test]
    fn enqueue_then_ingest_populates_store() {
        // Drive the pure path the system uses, without spinning up an App.
        let mut authority = VoxelAuthority::default();
        let snap = snapshot("snapshot_full");
        let coord = snap.chunk_coord;
        authority.enqueue(VoxelServerMessage::ChunkSnapshot(snap));

        // Mirror `ingest_voxel_messages`' drain-and-ingest.
        let inbox = std::mem::take(&mut authority.inbox);
        for message in inbox {
            authority.store.ingest(&message).unwrap();
        }

        assert_eq!(authority.store.chunk_count(), 1);
        assert!(authority.store.chunk(coord).is_some());
        assert_eq!(authority.store.take_dirty(), vec![coord]);
    }
}
