//! Client→server `PrefabPlaceIntent` (opcode 0x67): places a server-catalog
//! blueprint (sphere / cylinder / stairs / conductor wire / junction / power /
//! load terminal) as a refined-cell prefab at a macro anchor.
//!
//! Mirrors `SceneServer.Voxel.Codec.encode_prefab_place_intent_payload/1` at the
//! byte level (big-endian). The server's apply path
//! (`tcp_connection.ex::do_apply_voxel_prefab_place_intent`) uses only
//! `blueprint_id` / `blueprint_version` / `anchor_world_micro` / `rotation`; the
//! parcel + optimistic-concurrency fields (`parcel_id`,
//! `known_parcel_build_epoch`, `known_*` ref lists) are a not-yet-enforced future
//! feature, so the build path sends them empty / zero (= "no pin").
//!
//! Server `@blueprint_version = 2`; blueprint ids 1..7 (see `BlueprintCatalog`).

use super::cursor::{Reader, Writer};
use crate::protocol::ProtocolError;

/// Mirrors the server `@blueprint_version`.
pub const BLUEPRINT_VERSION: u32 = 2;

/// Micros per macro edge (the anchor is given in micro units = macro × 8).
pub const MICRO_PER_MACRO: i64 = 8;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrefabPlaceIntent {
    pub request_id: u64,
    pub client_intent_seq: u32,
    pub logical_scene_id: u64,
    pub parcel_id: u64,
    pub known_parcel_build_epoch: u64,
    pub blueprint_id: u64,
    pub blueprint_version: u32,
    /// Anchor in WORLD MICRO coords (macro × 8). Voxel/render axis convention.
    pub anchor_world_micro: [i64; 3],
    pub rotation: u8,
    pub placement_flags: u32,
}

impl PrefabPlaceIntent {
    /// Builds a placement of `blueprint_id` (at the catalog version) anchored at a
    /// GLOBAL macro coord, with no parcel/OCC pins (the build path's "place it"
    /// form). `anchor_world_micro = anchor_macro × 8`.
    pub fn macro_place(
        request_id: u64,
        client_intent_seq: u32,
        logical_scene_id: u64,
        blueprint_id: u64,
        anchor_macro: [i32; 3],
        rotation: u8,
    ) -> Self {
        Self {
            request_id,
            client_intent_seq,
            logical_scene_id,
            parcel_id: 0,
            known_parcel_build_epoch: 0,
            blueprint_id,
            blueprint_version: BLUEPRINT_VERSION,
            anchor_world_micro: [
                anchor_macro[0] as i64 * MICRO_PER_MACRO,
                anchor_macro[1] as i64 * MICRO_PER_MACRO,
                anchor_macro[2] as i64 * MICRO_PER_MACRO,
            ],
            rotation,
            placement_flags: 0,
        }
    }

    pub fn encode(&self, w: &mut Writer) {
        w.u64(self.request_id);
        w.u32(self.client_intent_seq);
        w.u64(self.logical_scene_id);
        w.u64(self.parcel_id);
        w.u64(self.known_parcel_build_epoch);
        w.u64(self.blueprint_id);
        w.u32(self.blueprint_version);
        w.i64(self.anchor_world_micro[0]);
        w.i64(self.anchor_world_micro[1]);
        w.i64(self.anchor_world_micro[2]);
        w.u8(self.rotation);
        // Empty known_refs / known_objects / known_cell_refs (no OCC pins).
        w.u16(0);
        w.u16(0);
        w.u16(0);
        w.u32(self.placement_flags);
    }

    pub fn decode(r: &mut Reader) -> Result<Self, ProtocolError> {
        let request_id = r.u64("prefab.request_id")?;
        let client_intent_seq = r.u32("prefab.client_intent_seq")?;
        let logical_scene_id = r.u64("prefab.logical_scene_id")?;
        let parcel_id = r.u64("prefab.parcel_id")?;
        let known_parcel_build_epoch = r.u64("prefab.known_parcel_build_epoch")?;
        let blueprint_id = r.u64("prefab.blueprint_id")?;
        let blueprint_version = r.u32("prefab.blueprint_version")?;
        let anchor_world_micro = [
            r.i64("prefab.ax")?,
            r.i64("prefab.ay")?,
            r.i64("prefab.az")?,
        ];
        let rotation = r.u8("prefab.rotation")?;
        // We only emit empty ref lists; decode (for round-trip tests) requires
        // each count to be 0.
        let known_ref_count = r.u16("prefab.known_ref_count")?;
        let known_object_count = r.u16("prefab.known_object_count")?;
        let known_cell_ref_count = r.u16("prefab.known_cell_ref_count")?;
        if known_ref_count != 0 || known_object_count != 0 || known_cell_ref_count != 0 {
            return Err(ProtocolError(
                "prefab decode: non-empty known refs unsupported".to_string(),
            ));
        }
        let placement_flags = r.u32("prefab.placement_flags")?;
        Ok(Self {
            request_id,
            client_intent_seq,
            logical_scene_id,
            parcel_id,
            known_parcel_build_epoch,
            blueprint_id,
            blueprint_version,
            anchor_world_micro,
            rotation,
            placement_flags,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn macro_place_resolves_anchor_to_micro_and_round_trips() {
        let intent = PrefabPlaceIntent::macro_place(7, 3, 1, 4, [10, -2, 3], 1);
        assert_eq!(intent.blueprint_id, 4);
        assert_eq!(intent.blueprint_version, BLUEPRINT_VERSION);
        assert_eq!(intent.anchor_world_micro, [80, -16, 24]);
        assert_eq!(intent.rotation, 1);
        assert_eq!(intent.parcel_id, 0);

        let mut w = Writer::new();
        intent.encode(&mut w);
        let bytes = w.into_bytes();
        // First 8 bytes = request_id big-endian (offset/endianness spot-check).
        assert_eq!(&bytes[0..8], &7u64.to_be_bytes());
        assert_eq!(PrefabPlaceIntent::decode(&mut Reader::new(&bytes)).unwrap(), intent);
    }
}
