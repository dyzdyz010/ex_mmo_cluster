import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import { VoxelOpcode } from "./opcodes";
import {
  encodeVoxelEditIntent,
  EXPECTED_CELL_HASH_UNSPECIFIED,
  EXPECTED_CHUNK_VERSION_UNSPECIFIED,
  VoxelEditAction,
  VoxelEditTargetGranularity,
  VOXEL_EDIT_INTENT_PAYLOAD_BYTES,
  VOXEL_EDIT_INTENT_WIRE_BYTES,
  type VoxelEditIntentInput,
} from "./voxelEditIntent";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const FIXTURE_PATH = resolve(
  __dirname,
  "../../../test/fixtures/voxel/voxel_edit_intent_v1.bin",
);

function defaultIntent(overrides: Partial<VoxelEditIntentInput> = {}): VoxelEditIntentInput {
  return {
    requestId: 1n,
    clientIntentSeq: 1,
    logicalSceneId: 1n,
    action: VoxelEditAction.Place,
    targetGranularity: VoxelEditTargetGranularity.Macro,
    targetWorldMicro: { x: 0n, y: 0n, z: 0n },
    faceNormal: { x: 0, y: 0, z: 0 },
    materialId: 0,
    blueprintRef: 0,
    objectRef: 0n,
    partRef: 0,
    attributePatchRef: 0,
    expectedChunkVersion: EXPECTED_CHUNK_VERSION_UNSPECIFIED,
    expectedCellHash: EXPECTED_CELL_HASH_UNSPECIFIED,
    clientHintHash: 0n,
    ...overrides,
  };
}

describe("encodeVoxelEditIntent (Phase 1b wire form)", () => {
  it("emits exactly 92 bytes (1 opcode + 91 payload)", () => {
    const bytes = encodeVoxelEditIntent(defaultIntent());
    expect(bytes.byteLength).toBe(VOXEL_EDIT_INTENT_WIRE_BYTES);
    expect(VOXEL_EDIT_INTENT_PAYLOAD_BYTES).toBe(91);
    expect(bytes[0]).toBe(VoxelOpcode.VoxelEditIntent);
    expect(VoxelOpcode.VoxelEditIntent).toBe(0x70);
  });

  it("places fields at the protocol-specified offsets in big-endian byte order", () => {
    const bytes = encodeVoxelEditIntent(
      defaultIntent({
        requestId: 0x0102_0304_0506_0708n,
        clientIntentSeq: 0x0a0b_0c0d,
        logicalSceneId: 0x1112_1314_1516_1718n,
        action: VoxelEditAction.Replace,
        targetGranularity: VoxelEditTargetGranularity.ObjectPart,
        targetWorldMicro: { x: -1n, y: 1n, z: 0x7fff_ffff_ffff_fff0n },
        faceNormal: { x: 1, y: -1, z: 0 },
        materialId: 0xabcd,
        blueprintRef: 0x1234_5678,
        objectRef: 0xdead_beef_feed_facen,
        partRef: 0x09080706,
        attributePatchRef: 0xa1b2c3d4,
        expectedChunkVersion: 0x0000_0000_0000_0123n,
        expectedCellHash: 0xcafebabe,
        clientHintHash: 0xffff_eeee_dddd_ccccn,
      }),
    );

    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

    // opcode @0
    expect(view.getUint8(0)).toBe(0x70);
    // request_id u64 @1
    expect(view.getBigUint64(1, false)).toBe(0x0102_0304_0506_0708n);
    // client_intent_seq u32 @9
    expect(view.getUint32(9, false)).toBe(0x0a0b_0c0d);
    // logical_scene_id u64 @13
    expect(view.getBigUint64(13, false)).toBe(0x1112_1314_1516_1718n);
    // action u8 @21
    expect(view.getUint8(21)).toBe(VoxelEditAction.Replace);
    // target_granularity u8 @22
    expect(view.getUint8(22)).toBe(VoxelEditTargetGranularity.ObjectPart);
    // target_world_micro i64 x/y/z @23, @31, @39
    expect(view.getBigInt64(23, false)).toBe(-1n);
    expect(view.getBigInt64(31, false)).toBe(1n);
    expect(view.getBigInt64(39, false)).toBe(0x7fff_ffff_ffff_fff0n);
    // face_normal i8 x/y/z @47..49
    expect(view.getInt8(47)).toBe(1);
    expect(view.getInt8(48)).toBe(-1);
    expect(view.getInt8(49)).toBe(0);
    // material_id u16 @50
    expect(view.getUint16(50, false)).toBe(0xabcd);
    // blueprint_ref u32 @52
    expect(view.getUint32(52, false)).toBe(0x1234_5678);
    // object_ref u64 @56
    expect(view.getBigUint64(56, false)).toBe(0xdead_beef_feed_facen);
    // part_ref u32 @64
    expect(view.getUint32(64, false)).toBe(0x09080706);
    // attribute_patch_ref u32 @68
    expect(view.getUint32(68, false)).toBe(0xa1b2c3d4);
    // expected_chunk_version u64 @72
    expect(view.getBigUint64(72, false)).toBe(0x0000_0000_0000_0123n);
    // expected_cell_hash u32 @80
    expect(view.getUint32(80, false)).toBe(0xcafebabe);
    // client_hint_hash u64 @84
    expect(view.getBigUint64(84, false)).toBe(0xffff_eeee_dddd_ccccn);
  });

  it("encodes 'no constraint' sentinels correctly when callers want optimistic-concurrency off", () => {
    const bytes = encodeVoxelEditIntent(defaultIntent());
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    expect(view.getBigUint64(72, false)).toBe(0xffff_ffff_ffff_ffffn);
    expect(view.getUint32(80, false)).toBe(0xffff_ffff);
  });

  it("rejects out-of-range action (u8)", () => {
    expect(() => encodeVoxelEditIntent(defaultIntent({ action: 256 }))).toThrow(
      /action_out_of_u8/,
    );
    expect(() => encodeVoxelEditIntent(defaultIntent({ action: -1 }))).toThrow(
      /action_out_of_u8/,
    );
  });

  it("rejects out-of-range face_normal (i8)", () => {
    expect(() =>
      encodeVoxelEditIntent(defaultIntent({ faceNormal: { x: 200, y: 0, z: 0 } })),
    ).toThrow(/face_normal\.x_out_of_i8/);
    expect(() =>
      encodeVoxelEditIntent(defaultIntent({ faceNormal: { x: 0, y: -200, z: 0 } })),
    ).toThrow(/face_normal\.y_out_of_i8/);
  });

  it("rejects out-of-range material_id (u16)", () => {
    expect(() => encodeVoxelEditIntent(defaultIntent({ materialId: 0x1_0000 }))).toThrow(
      /material_id_out_of_u16/,
    );
    expect(() => encodeVoxelEditIntent(defaultIntent({ materialId: -1 }))).toThrow(
      /material_id_out_of_u16/,
    );
  });

  it("rejects non-bigint where bigint is required", () => {
    expect(() =>
      encodeVoxelEditIntent(
        defaultIntent({ requestId: 1 as unknown as bigint }),
      ),
    ).toThrow(/request_id_out_of_u64/);
  });

  it("rejects out-of-range expected_chunk_version (u64)", () => {
    expect(() =>
      encodeVoxelEditIntent(defaultIntent({ expectedChunkVersion: -1n })),
    ).toThrow(/expected_chunk_version_out_of_u64/);
    expect(() =>
      encodeVoxelEditIntent(
        defaultIntent({ expectedChunkVersion: 1n + 0xffff_ffff_ffff_ffffn }),
      ),
    ).toThrow(/expected_chunk_version_out_of_u64/);
  });

  it("matches the shared fixture voxel_edit_intent_v1.bin produced by Elixir", () => {
    const buffer = readFileSync(FIXTURE_PATH);
    expect(buffer.byteLength).toBe(2 * VOXEL_EDIT_INTENT_WIRE_BYTES);

    const intentA: VoxelEditIntentInput = {
      requestId: 0x0000_0000_0000_00a1n,
      clientIntentSeq: 1,
      logicalSceneId: 0x0000_0000_0000_002an,
      action: VoxelEditAction.Place,
      targetGranularity: VoxelEditTargetGranularity.Macro,
      targetWorldMicro: { x: 16n, y: 0n, z: 32n },
      faceNormal: { x: 0, y: 1, z: 0 },
      materialId: 17,
      blueprintRef: 0,
      objectRef: 0n,
      partRef: 0,
      attributePatchRef: 0,
      expectedChunkVersion: EXPECTED_CHUNK_VERSION_UNSPECIFIED,
      expectedCellHash: EXPECTED_CELL_HASH_UNSPECIFIED,
      clientHintHash: 0n,
    };

    const intentB: VoxelEditIntentInput = {
      requestId: 0x0000_0000_0000_00b2n,
      clientIntentSeq: 2,
      logicalSceneId: 0x0000_0000_0000_002an,
      action: VoxelEditAction.Break,
      targetGranularity: VoxelEditTargetGranularity.ObjectPart,
      targetWorldMicro: { x: -100n, y: 0n, z: 100n },
      faceNormal: { x: 1, y: 0, z: -1 },
      materialId: 0,
      blueprintRef: 0,
      objectRef: 0x0000_0000_dead_beefn,
      partRef: 7,
      attributePatchRef: 0,
      expectedChunkVersion: 0x0000_0000_0000_0123n,
      expectedCellHash: 0xcafebabe,
      clientHintHash: 0xffff_eeee_dddd_ccccn,
    };

    const ea = encodeVoxelEditIntent(intentA);
    const eb = encodeVoxelEditIntent(intentB);
    const concat = new Uint8Array(ea.byteLength + eb.byteLength);
    concat.set(ea, 0);
    concat.set(eb, ea.byteLength);

    expect(Array.from(concat)).toEqual(Array.from(buffer));
  });

  it("accepts boundary i64 values for target_world_micro", () => {
    expect(() =>
      encodeVoxelEditIntent(
        defaultIntent({
          targetWorldMicro: {
            x: -0x8000_0000_0000_0000n,
            y: 0x7fff_ffff_ffff_ffffn,
            z: 0n,
          },
        }),
      ),
    ).not.toThrow();
  });

  describe("hardening: full coverage of out-of-range rejections", () => {
    const u8Fields: Array<{ key: keyof VoxelEditIntentInput; label: string }> = [
      { key: "action", label: "action_out_of_u8" },
      { key: "targetGranularity", label: "target_granularity_out_of_u8" },
    ];

    for (const { key, label } of u8Fields) {
      it(`rejects ${key} > u8 max`, () => {
        expect(() =>
          encodeVoxelEditIntent(defaultIntent({ [key]: 256 } as Partial<VoxelEditIntentInput>)),
        ).toThrow(new RegExp(label));
      });

      it(`rejects ${key} < 0`, () => {
        expect(() =>
          encodeVoxelEditIntent(defaultIntent({ [key]: -1 } as Partial<VoxelEditIntentInput>)),
        ).toThrow(new RegExp(label));
      });
    }

    const u16Fields: Array<{ key: keyof VoxelEditIntentInput; label: string }> = [
      { key: "materialId", label: "material_id_out_of_u16" },
    ];

    for (const { key, label } of u16Fields) {
      it(`rejects ${key} > u16 max`, () => {
        expect(() =>
          encodeVoxelEditIntent(
            defaultIntent({ [key]: 0x1_0000 } as Partial<VoxelEditIntentInput>),
          ),
        ).toThrow(new RegExp(label));
      });

      it(`rejects ${key} < 0`, () => {
        expect(() =>
          encodeVoxelEditIntent(defaultIntent({ [key]: -1 } as Partial<VoxelEditIntentInput>)),
        ).toThrow(new RegExp(label));
      });
    }

    const u32Fields: Array<{ key: keyof VoxelEditIntentInput; label: string }> = [
      { key: "clientIntentSeq", label: "client_intent_seq_out_of_u32" },
      { key: "blueprintRef", label: "blueprint_ref_out_of_u32" },
      { key: "partRef", label: "part_ref_out_of_u32" },
      { key: "attributePatchRef", label: "attribute_patch_ref_out_of_u32" },
      { key: "expectedCellHash", label: "expected_cell_hash_out_of_u32" },
    ];

    for (const { key, label } of u32Fields) {
      it(`rejects ${key} > u32 max`, () => {
        expect(() =>
          encodeVoxelEditIntent(
            defaultIntent({ [key]: 0x1_0000_0000 } as Partial<VoxelEditIntentInput>),
          ),
        ).toThrow(new RegExp(label));
      });

      it(`rejects ${key} < 0`, () => {
        expect(() =>
          encodeVoxelEditIntent(defaultIntent({ [key]: -1 } as Partial<VoxelEditIntentInput>)),
        ).toThrow(new RegExp(label));
      });
    }

    const u64Fields: Array<{ key: keyof VoxelEditIntentInput; label: string }> = [
      { key: "requestId", label: "request_id_out_of_u64" },
      { key: "logicalSceneId", label: "logical_scene_id_out_of_u64" },
      { key: "objectRef", label: "object_ref_out_of_u64" },
      { key: "expectedChunkVersion", label: "expected_chunk_version_out_of_u64" },
      { key: "clientHintHash", label: "client_hint_hash_out_of_u64" },
    ];

    for (const { key, label } of u64Fields) {
      it(`rejects ${key} > u64 max`, () => {
        expect(() =>
          encodeVoxelEditIntent(
            defaultIntent({ [key]: 1n + 0xffff_ffff_ffff_ffffn } as Partial<VoxelEditIntentInput>),
          ),
        ).toThrow(new RegExp(label));
      });

      it(`rejects ${key} < 0n`, () => {
        expect(() =>
          encodeVoxelEditIntent(defaultIntent({ [key]: -1n } as Partial<VoxelEditIntentInput>)),
        ).toThrow(new RegExp(label));
      });

      it(`rejects ${key} as plain number (must be bigint)`, () => {
        expect(() =>
          encodeVoxelEditIntent(
            defaultIntent({ [key]: 0 } as unknown as Partial<VoxelEditIntentInput>),
          ),
        ).toThrow(new RegExp(label));
      });
    }

    it("rejects each i64 axis of target_world_micro independently when above max", () => {
      const above = 1n + 0x7fff_ffff_ffff_ffffn;

      expect(() =>
        encodeVoxelEditIntent(
          defaultIntent({ targetWorldMicro: { x: above, y: 0n, z: 0n } }),
        ),
      ).toThrow(/target_world_micro\.x_out_of_i64/);

      expect(() =>
        encodeVoxelEditIntent(
          defaultIntent({ targetWorldMicro: { x: 0n, y: above, z: 0n } }),
        ),
      ).toThrow(/target_world_micro\.y_out_of_i64/);

      expect(() =>
        encodeVoxelEditIntent(
          defaultIntent({ targetWorldMicro: { x: 0n, y: 0n, z: above } }),
        ),
      ).toThrow(/target_world_micro\.z_out_of_i64/);
    });

    it("rejects each i64 axis of target_world_micro independently when below min", () => {
      const below = -1n - 0x8000_0000_0000_0000n;

      expect(() =>
        encodeVoxelEditIntent(
          defaultIntent({ targetWorldMicro: { x: below, y: 0n, z: 0n } }),
        ),
      ).toThrow(/target_world_micro\.x_out_of_i64/);

      expect(() =>
        encodeVoxelEditIntent(
          defaultIntent({ targetWorldMicro: { x: 0n, y: below, z: 0n } }),
        ),
      ).toThrow(/target_world_micro\.y_out_of_i64/);

      expect(() =>
        encodeVoxelEditIntent(
          defaultIntent({ targetWorldMicro: { x: 0n, y: 0n, z: below } }),
        ),
      ).toThrow(/target_world_micro\.z_out_of_i64/);
    });

    it("rejects target_world_micro components passed as numbers (must be bigint)", () => {
      expect(() =>
        encodeVoxelEditIntent(
          defaultIntent({
            targetWorldMicro: { x: 1 as unknown as bigint, y: 0n, z: 0n },
          }),
        ),
      ).toThrow(/target_world_micro\.x_out_of_i64/);
    });

    it("rejects each face_normal axis independently when out of i8", () => {
      expect(() =>
        encodeVoxelEditIntent(defaultIntent({ faceNormal: { x: 128, y: 0, z: 0 } })),
      ).toThrow(/face_normal\.x_out_of_i8/);

      expect(() =>
        encodeVoxelEditIntent(defaultIntent({ faceNormal: { x: 0, y: 128, z: 0 } })),
      ).toThrow(/face_normal\.y_out_of_i8/);

      expect(() =>
        encodeVoxelEditIntent(defaultIntent({ faceNormal: { x: 0, y: 0, z: 128 } })),
      ).toThrow(/face_normal\.z_out_of_i8/);

      expect(() =>
        encodeVoxelEditIntent(defaultIntent({ faceNormal: { x: -129, y: 0, z: 0 } })),
      ).toThrow(/face_normal\.x_out_of_i8/);
    });

    it("accepts face_normal i8 boundaries 127 / -128", () => {
      expect(() =>
        encodeVoxelEditIntent(defaultIntent({ faceNormal: { x: 127, y: -128, z: 0 } })),
      ).not.toThrow();
    });

    it("rejects non-integer numeric fields (NaN, fractional, Infinity)", () => {
      expect(() =>
        encodeVoxelEditIntent(defaultIntent({ action: NaN })),
      ).toThrow(/action_out_of_u8/);

      expect(() =>
        encodeVoxelEditIntent(defaultIntent({ action: 1.5 })),
      ).toThrow(/action_out_of_u8/);

      expect(() =>
        encodeVoxelEditIntent(defaultIntent({ action: Number.POSITIVE_INFINITY })),
      ).toThrow(/action_out_of_u8/);

      expect(() =>
        encodeVoxelEditIntent(defaultIntent({ blueprintRef: 1.0001 })),
      ).toThrow(/blueprint_ref_out_of_u32/);

      expect(() =>
        encodeVoxelEditIntent(defaultIntent({ materialId: NaN })),
      ).toThrow(/material_id_out_of_u16/);
    });

    it("accepts all-zero intent (every field at min) and produces a 92-byte frame", () => {
      const allZero = encodeVoxelEditIntent({
        requestId: 0n,
        clientIntentSeq: 0,
        logicalSceneId: 0n,
        action: 0,
        targetGranularity: 0,
        targetWorldMicro: { x: 0n, y: 0n, z: 0n },
        faceNormal: { x: 0, y: 0, z: 0 },
        materialId: 0,
        blueprintRef: 0,
        objectRef: 0n,
        partRef: 0,
        attributePatchRef: 0,
        expectedChunkVersion: 0n,
        expectedCellHash: 0,
        clientHintHash: 0n,
      });

      expect(allZero.byteLength).toBe(VOXEL_EDIT_INTENT_WIRE_BYTES);
      expect(allZero[0]).toBe(VoxelOpcode.VoxelEditIntent);
      // The remaining 91 bytes should all be zero (verifies offsets stayed
      // consistent with the constructor's "everything at zero" semantics).
      for (let i = 1; i < allZero.byteLength; i += 1) {
        expect(allZero[i]).toBe(0);
      }
    });

    it("accepts all-max intent (every unsigned field at u_max, i64 at +max) and roundtrips", () => {
      const maxIntent: VoxelEditIntentInput = {
        requestId: 0xffff_ffff_ffff_ffffn,
        clientIntentSeq: 0xffff_ffff,
        logicalSceneId: 0xffff_ffff_ffff_ffffn,
        action: 0xff,
        targetGranularity: 0xff,
        targetWorldMicro: {
          x: 0x7fff_ffff_ffff_ffffn,
          y: 0x7fff_ffff_ffff_ffffn,
          z: 0x7fff_ffff_ffff_ffffn,
        },
        faceNormal: { x: 127, y: 127, z: 127 },
        materialId: 0xffff,
        blueprintRef: 0xffff_ffff,
        objectRef: 0xffff_ffff_ffff_ffffn,
        partRef: 0xffff_ffff,
        attributePatchRef: 0xffff_ffff,
        expectedChunkVersion: 0xffff_ffff_ffff_ffffn,
        expectedCellHash: 0xffff_ffff,
        clientHintHash: 0xffff_ffff_ffff_ffffn,
      };

      const bytes = encodeVoxelEditIntent(maxIntent);
      expect(bytes.byteLength).toBe(VOXEL_EDIT_INTENT_WIRE_BYTES);
      // Spot-check every byte after the opcode equals 0xFF; faceNormal axes
      // are i8 = 127 = 0x7F so they break the all-FF pattern.
      const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      expect(view.getBigUint64(1, false)).toBe(0xffff_ffff_ffff_ffffn);
      expect(view.getInt8(47)).toBe(127);
      expect(view.getInt8(48)).toBe(127);
      expect(view.getInt8(49)).toBe(127);
      expect(view.getUint16(50, false)).toBe(0xffff);
    });
  });
});
