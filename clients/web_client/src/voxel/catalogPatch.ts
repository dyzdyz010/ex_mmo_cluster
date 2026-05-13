// Phase 1.6b: TS decoder for the CatalogPatch envelope (opcode 0x71).
//
// Mirrors `apps/scene_server/lib/scene_server/voxel/catalog_patch.ex`. The
// payload (without the leading opcode byte) is:
//
//   schema_kind:   u8           (0x01 attribute / 0x02 tag /
//                                 0x03..0xFF reserved → hard error)
//   base_version:  u64
//   new_version:   u64           (must satisfy base_version <= new_version)
//   op_count:      u16
//   ops[op_count] {
//     op_kind:     u8            (0x01 add / 0x02 remove / 0x03 update /
//                                  0x04..0xFF preserved as raw for
//                                  forward-compat skip)
//     entry_id:    u32
//     payload_len: u16
//     payload:     bytes(payload_len)
//   }
//
// Phase 1.6b does not interpret op `payload` bytes (Phase 5 will, when
// `AttributeDefinition` / `TagDefinition` land). The decoder is a byte-stable
// pass-through for the forward-compat skip case (unknown op_kind 0x04..0xFF).

export const CatalogSchemaKind = {
  Attribute: 0x01,
  Tag: 0x02,
} as const;

export const CatalogOpKind = {
  Add: 0x01,
  Remove: 0x02,
  Update: 0x03,
} as const;

export type CatalogSchemaKindValue =
  (typeof CatalogSchemaKind)[keyof typeof CatalogSchemaKind];

export type CatalogOpKindValue = (typeof CatalogOpKind)[keyof typeof CatalogOpKind];

export interface CatalogPatchOp {
  /**
   * Raw op_kind byte. Known values 0x01/0x02/0x03 correspond to add/remove/
   * update; unknown values 0x04..0xFF are preserved as-is for forward-compat
   * (the server may emit catalog ops the client does not yet understand;
   * routers and middle nodes must round-trip them byte-identically).
   */
  opKind: number;
  entryId: number; // u32
  payload: Uint8Array;
}

export interface CatalogPatch {
  schemaKind: number;
  baseVersion: bigint;
  newVersion: bigint;
  ops: readonly CatalogPatchOp[];
}

/**
 * Decode a CatalogPatch payload (without the opcode byte). Throws on
 * envelope-level errors (unknown schema_kind, malformed framing, monotonic
 * version violation, truncation, or trailing bytes).
 */
export function decodeCatalogPatchPayload(view: DataView): CatalogPatch {
  // Envelope: 1 (schema_kind) + 8 (base_version) + 8 (new_version) + 2 (op_count) = 19 bytes
  if (view.byteLength < 19) {
    throw new Error(`catalog_patch_truncated_envelope:${view.byteLength}`);
  }

  let offset = 0;
  const schemaKind = view.getUint8(offset);
  offset += 1;

  if (schemaKind !== CatalogSchemaKind.Attribute && schemaKind !== CatalogSchemaKind.Tag) {
    throw new Error(`catalog_patch_unknown_schema_kind:0x${schemaKind.toString(16)}`);
  }

  const baseVersion = view.getBigUint64(offset, false);
  offset += 8;
  const newVersion = view.getBigUint64(offset, false);
  offset += 8;
  if (baseVersion > newVersion) {
    throw new Error(
      `catalog_patch_non_monotonic_version:base_${baseVersion}_new_${newVersion}`,
    );
  }

  const opCount = view.getUint16(offset, false);
  offset += 2;

  const ops: CatalogPatchOp[] = [];
  for (let i = 0; i < opCount; i += 1) {
    if (offset + 1 + 4 + 2 > view.byteLength) {
      throw new Error(`catalog_patch_truncated_op_header:at_offset_${offset}`);
    }
    const opKind = view.getUint8(offset);
    offset += 1;
    const entryId = view.getUint32(offset, false);
    offset += 4;
    const payloadLen = view.getUint16(offset, false);
    offset += 2;
    if (offset + payloadLen > view.byteLength) {
      throw new Error(
        `catalog_patch_truncated_op_payload:need_${payloadLen}_at_${offset}_have_${
          view.byteLength - offset
        }`,
      );
    }
    const payload = new Uint8Array(
      view.buffer.slice(
        view.byteOffset + offset,
        view.byteOffset + offset + payloadLen,
      ),
    );
    offset += payloadLen;
    ops.push({ opKind, entryId, payload });
  }

  if (offset !== view.byteLength) {
    throw new Error(`catalog_patch_trailing_bytes:${view.byteLength - offset}`);
  }

  return { schemaKind, baseVersion, newVersion, ops };
}

/**
 * Re-encode a CatalogPatch back to its wire form. Used by tests to assert
 * byte-stable roundtrip (including forward-compat skip).
 */
export function encodeCatalogPatchPayload(patch: CatalogPatch): Uint8Array {
  let total = 19;
  for (const op of patch.ops) {
    total += 1 + 4 + 2 + op.payload.byteLength;
  }
  const buffer = new ArrayBuffer(total);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, patch.schemaKind);
  offset += 1;
  view.setBigUint64(offset, patch.baseVersion, false);
  offset += 8;
  view.setBigUint64(offset, patch.newVersion, false);
  offset += 8;
  view.setUint16(offset, patch.ops.length, false);
  offset += 2;
  const out = new Uint8Array(buffer);
  for (const op of patch.ops) {
    view.setUint8(offset, op.opKind);
    offset += 1;
    view.setUint32(offset, op.entryId, false);
    offset += 4;
    view.setUint16(offset, op.payload.byteLength, false);
    offset += 2;
    out.set(op.payload, offset);
    offset += op.payload.byteLength;
  }
  return out;
}
