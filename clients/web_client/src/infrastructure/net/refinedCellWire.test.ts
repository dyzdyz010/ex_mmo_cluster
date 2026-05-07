import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import {
  decodeRefinedCellPool,
  encodeRefinedCellPool,
  type RefinedCellWireData,
} from "./refinedCellWire";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const FIXTURE_PATH = resolve(
  __dirname,
  "../../../test/fixtures/voxel/refined_512_cell_v1.bin",
);

const ZERO_MASK: bigint[] = [0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n];

function viewOf(bytes: Uint8Array): DataView {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

describe("refinedCellWire decoder (Phase 1a)", () => {
  it("decodes the empty pool to []", () => {
    const empty = new Uint8Array([0, 0, 0, 0]);
    expect(decodeRefinedCellPool(viewOf(empty))).toEqual([]);
  });

  it("encodes [] to <<0u32>>", () => {
    const bytes = encodeRefinedCellPool([]);
    expect(bytes).toEqual(new Uint8Array([0, 0, 0, 0]));
  });

  it("rejects a section shorter than 4 bytes", () => {
    expect(() => decodeRefinedCellPool(viewOf(new Uint8Array([0, 0, 0])))).toThrow(
      /invalid_refined_cells_section/,
    );
  });

  it("rejects an empty pool with trailing bytes", () => {
    expect(() =>
      decodeRefinedCellPool(viewOf(new Uint8Array([0, 0, 0, 0, 0xff]))),
    ).toThrow(/trailing_refined_cells_bytes/);
  });

  it("round-trips one cell with one layer and no object refs", () => {
    const cell: RefinedCellWireData = {
      occupancyWords: [0xfn, 0n, 0n, 0n, 0n, 0n, 0n, 0n],
      boundaryCache: 0xcafef00dn,
      layers: [
        {
          maskWords: [0xfn, 0n, 0n, 0n, 0n, 0n, 0n, 0n],
          materialId: 17,
          stateFlags: 0x10,
          health: 200,
          attributeSetRef: 0,
          tagSetRef: 0,
          ownerObjectId: 0n,
          ownerPartId: 0,
        },
      ],
      objectRefs: [],
    };

    const encoded = encodeRefinedCellPool([cell]);
    const decoded = decodeRefinedCellPool(viewOf(encoded));
    expect(decoded).toEqual([cell]);
  });

  it("round-trips a cell with object refs and verifies wire size accounting", () => {
    const cell: RefinedCellWireData = {
      occupancyWords: [0x0fn, 0xf0n, 0n, 0n, 0n, 0n, 0n, 0n],
      boundaryCache: 0n,
      layers: [
        {
          maskWords: [0x0fn, 0xf0n, 0n, 0n, 0n, 0n, 0n, 0n],
          materialId: 42,
          stateFlags: 0,
          health: 100,
          attributeSetRef: 3,
          tagSetRef: 4,
          ownerObjectId: 0xdeadbeefn,
          ownerPartId: 7,
        },
      ],
      objectRefs: [
        {
          ownerObjectId: 0xdeadbeefn,
          ownerPartId: 7,
          maskWords: [0x0fn, 0xf0n, 0n, 0n, 0n, 0n, 0n, 0n],
        },
      ],
    };

    const encoded = encodeRefinedCellPool([cell]);
    // 4 (count)
    //   + 64 (occupancy) + 8 (boundary) + 2 (layer_count)
    //   + 92 (one layer)
    //   + 2 (object_ref_count)
    //   + 76 (one object_ref)
    expect(encoded.byteLength).toBe(4 + 64 + 8 + 2 + 92 + 2 + 76);

    const decoded = decodeRefinedCellPool(viewOf(encoded));
    expect(decoded).toEqual([cell]);
  });

  it("round-trips multiple cells", () => {
    const cells: RefinedCellWireData[] = [
      {
        occupancyWords: [0x1n, ...ZERO_MASK.slice(1)],
        boundaryCache: 1n,
        layers: [],
        objectRefs: [],
      },
      {
        occupancyWords: [0x0n, 0x2n, ...ZERO_MASK.slice(2)],
        boundaryCache: 2n,
        layers: [],
        objectRefs: [],
      },
    ];
    // Note: occupancy != OR(layers) is enforced server-side, not by the wire
    // decoder. The decoder is byte-faithful; semantic invariants live in the
    // Elixir RefinedCellData.normalize!/1.
    const encoded = encodeRefinedCellPool(cells);
    expect(decodeRefinedCellPool(viewOf(encoded))).toEqual(cells);
  });

  it("decodes the shared fixture refined_512_cell_v1.bin produced by Elixir", () => {
    const buffer = readFileSync(FIXTURE_PATH);
    const view = new DataView(
      buffer.buffer,
      buffer.byteOffset,
      buffer.byteLength,
    );
    const cells = decodeRefinedCellPool(view);
    expect(cells.length).toBe(2);

    const [c0, c1] = cells as [
      (typeof cells)[number],
      (typeof cells)[number],
    ];

    // cell #0
    expect(c0.occupancyWords).toEqual([0xffffn, 0n, 0n, 0n, 0n, 0n, 0n, 0n]);
    expect(c0.boundaryCache).toBe(0xcafebabedeadbeefn);
    expect(c0.layers.length).toBe(1);
    const l0 = c0.layers[0]!;
    expect(l0.maskWords).toEqual([0xffffn, 0n, 0n, 0n, 0n, 0n, 0n, 0n]);
    expect(l0.materialId).toBe(17);
    expect(l0.stateFlags).toBe(0x10);
    expect(l0.health).toBe(200);
    expect(l0.attributeSetRef).toBe(1);
    expect(l0.tagSetRef).toBe(2);
    expect(l0.ownerObjectId).toBe(0n);
    expect(l0.ownerPartId).toBe(0);
    expect(c0.objectRefs).toEqual([]);

    // cell #1
    expect(c1.occupancyWords).toEqual([0n, 0n, 0n, 0n, 0n, 0n, 0n, 0xffn]);
    expect(c1.boundaryCache).toBe(0n);
    expect(c1.layers.length).toBe(2);
    const [a, b] = c1.layers as [
      (typeof c1.layers)[number],
      (typeof c1.layers)[number],
    ];
    expect(a.maskWords).toEqual([0n, 0n, 0n, 0n, 0n, 0n, 0n, 0xf0n]);
    expect(a.materialId).toBe(42);
    expect(a.ownerObjectId).toBe(0xdeadbeefn);
    expect(a.ownerPartId).toBe(7);
    expect(b.maskWords).toEqual([0n, 0n, 0n, 0n, 0n, 0n, 0n, 0x0fn]);
    expect(b.materialId).toBe(99);
    expect(b.attributeSetRef).toBe(5);
    expect(b.tagSetRef).toBe(6);

    expect(c1.objectRefs.length).toBe(1);
    const [ref] = c1.objectRefs as [(typeof c1.objectRefs)[number]];
    expect(ref.ownerObjectId).toBe(0xdeadbeefn);
    expect(ref.ownerPartId).toBe(7);
    expect(ref.maskWords).toEqual([0n, 0n, 0n, 0n, 0n, 0n, 0n, 0xf0n]);

    // round-trip the bytes through encode and confirm they match
    const reEncoded = encodeRefinedCellPool(cells);
    expect(Array.from(reEncoded)).toEqual(Array.from(buffer));
  });

  it("preserves big-endian byte order for u64/u32/u16 fields", () => {
    const cell: RefinedCellWireData = {
      occupancyWords: [0x0102030405060708n, ...ZERO_MASK.slice(1)],
      boundaryCache: 0xa1a2a3a4a5a6a7a8n,
      layers: [],
      objectRefs: [],
    };

    const encoded = encodeRefinedCellPool([cell]);
    // count u32 = 1 → bytes [0,0,0,1]
    expect(encoded[0]).toBe(0);
    expect(encoded[1]).toBe(0);
    expect(encoded[2]).toBe(0);
    expect(encoded[3]).toBe(1);
    // occupancy_words[0] big-endian → [0x01..0x08] starting at byte 4
    expect(Array.from(encoded.slice(4, 12))).toEqual([
      0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    ]);
    // boundary_cache lives after 8 occupancy words = byte 4 + 64 = 68
    expect(Array.from(encoded.slice(68, 76))).toEqual([
      0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8,
    ]);
  });
});
