import {
  CatalogOpKind,
  CatalogSchemaKind,
  decodeCatalogPatchPayload,
  encodeCatalogPatchPayload,
  type CatalogPatch,
} from "./catalogPatch";
import {
  CATALOG_PATCH_FIXTURES,
  loadGolden,
} from "./fixtures/goldenFixtureLoader";

describe("CatalogPatch envelope", () => {
  it("decodes a minimal attribute add envelope", () => {
    // schema_kind=0x01, base_version=0, new_version=1, op_count=1,
    // op { op_kind=0x01 add, entry_id=0x1000, payload_len=4, payload=[1,2,3,4] }
    const buf = new Uint8Array([
      0x01,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
      0x00, 0x01,
      0x01,
      0x00, 0x00, 0x10, 0x00,
      0x00, 0x04,
      0x01, 0x02, 0x03, 0x04,
    ]);
    const patch = decodeCatalogPatchPayload(new DataView(buf.buffer));
    expect(patch.schemaKind).toBe(CatalogSchemaKind.Attribute);
    expect(patch.baseVersion).toBe(0n);
    expect(patch.newVersion).toBe(1n);
    expect(patch.ops).toHaveLength(1);
    const op = patch.ops[0];
    if (!op) throw new Error("expected one op");
    expect(op.opKind).toBe(CatalogOpKind.Add);
    expect(op.entryId).toBe(0x1000);
    expect(Array.from(op.payload)).toEqual([1, 2, 3, 4]);
  });

  it("rejects unknown schema_kind as a hard envelope error", () => {
    const buf = new Uint8Array([
      0x99, // unknown schema_kind
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 1,
      0, 0,
    ]);
    expect(() =>
      decodeCatalogPatchPayload(new DataView(buf.buffer)),
    ).toThrow(/catalog_patch_unknown_schema_kind/);
  });

  it("rejects non-monotonic versions", () => {
    const buf = new Uint8Array([
      0x01,
      0, 0, 0, 0, 0, 0, 0, 5, // base=5
      0, 0, 0, 0, 0, 0, 0, 4, // new=4 (regression)
      0, 0,
    ]);
    expect(() =>
      decodeCatalogPatchPayload(new DataView(buf.buffer)),
    ).toThrow(/catalog_patch_non_monotonic_version/);
  });

  it("preserves unknown op_kind for forward-compat skip and re-encodes byte-stable", () => {
    // schema_kind=0x02 tag, op with op_kind=0xFE (unknown) + 2-byte payload.
    const original = new Uint8Array([
      0x02,
      0, 0, 0, 0, 0, 0, 0, 1,
      0, 0, 0, 0, 0, 0, 0, 2,
      0x00, 0x01,
      0xfe, // unknown op_kind
      0x00, 0x00, 0x00, 0x42,
      0x00, 0x02,
      0xde, 0xad,
    ]);
    const patch = decodeCatalogPatchPayload(new DataView(original.buffer));
    expect(patch.ops).toHaveLength(1);
    const op = patch.ops[0];
    if (!op) throw new Error("expected one op");
    expect(op.opKind).toBe(0xfe);
    expect(Array.from(op.payload)).toEqual([0xde, 0xad]);

    const reencoded = encodeCatalogPatchPayload(patch);
    expect(Array.from(reencoded)).toEqual(Array.from(original));
  });

  it("rejects trailing bytes after the last op", () => {
    const buf = new Uint8Array([
      0x01,
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 1,
      0x00, 0x00, // op_count = 0
      0xff,        // junk
    ]);
    expect(() =>
      decodeCatalogPatchPayload(new DataView(buf.buffer)),
    ).toThrow(/catalog_patch_trailing_bytes/);
  });
});

// Phase 1.6a golden fixture roundtrip — 3 fixtures × decode→re-encode byte-stable.
describe.each(CATALOG_PATCH_FIXTURES)(
  "catalog_patch golden fixture %s",
  (fixtureName) => {
    it("decode → re-encode is byte-stable", () => {
      const { bytes } = loadGolden(fixtureName);
      const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
      const patch: CatalogPatch = decodeCatalogPatchPayload(view);
      const reencoded = encodeCatalogPatchPayload(patch);
      expect(Array.from(reencoded)).toEqual(Array.from(bytes));
    });
  },
);

describe("catalog_patch_forward_compat_skip fixture", () => {
  it("contains at least one unknown op_kind (0x04..0xFF)", () => {
    const { bytes } = loadGolden("catalog_patch_forward_compat_skip");
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const patch = decodeCatalogPatchPayload(view);
    const hasUnknown = patch.ops.some(
      (op) =>
        op.opKind !== CatalogOpKind.Add &&
        op.opKind !== CatalogOpKind.Remove &&
        op.opKind !== CatalogOpKind.Update,
    );
    expect(hasUnknown).toBe(true);
  });
});
