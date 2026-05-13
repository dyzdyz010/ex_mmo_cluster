import { decodeTagSetPool } from "./tagSet";

describe("decodeTagSetPool", () => {
  it("decodes an empty pool from <<0u32>>", () => {
    const buf = new Uint8Array(4);
    expect(decodeTagSetPool(new DataView(buf.buffer))).toEqual([]);
  });

  it("decodes two TagSets with ascending unique tag_ids", () => {
    const buf = new Uint8Array([
      // set_count = 2
      0x00, 0x00, 0x00, 0x02,
      // set 1: tag_count=3, tag_ids=[1, 2, 7]
      0x00, 0x03,
      0x00, 0x00, 0x00, 0x01,
      0x00, 0x00, 0x00, 0x02,
      0x00, 0x00, 0x00, 0x07,
      // set 2: tag_count=2, tag_ids=[0x1000, 0x10010001]
      0x00, 0x02,
      0x00, 0x00, 0x10, 0x00,
      0x10, 0x01, 0x00, 0x01,
    ]);
    const sets = decodeTagSetPool(new DataView(buf.buffer));
    expect(sets).toEqual([
      { tagIds: [1, 2, 7] },
      { tagIds: [0x1000, 0x10010001] },
    ]);
  });

  it("rejects non-ascending tag_ids (drift detector)", () => {
    const buf = new Uint8Array([
      // set_count = 1
      0x00, 0x00, 0x00, 0x01,
      // tag_count = 2, tag_ids descending [5, 3]
      0x00, 0x02,
      0x00, 0x00, 0x00, 0x05,
      0x00, 0x00, 0x00, 0x03,
    ]);
    expect(() => decodeTagSetPool(new DataView(buf.buffer))).toThrow(
      /tag_set_tag_ids_not_ascending_or_unique/,
    );
  });

  it("rejects duplicate tag_ids (drift detector)", () => {
    const buf = new Uint8Array([
      0x00, 0x00, 0x00, 0x01,
      0x00, 0x02,
      0x00, 0x00, 0x00, 0x09,
      0x00, 0x00, 0x00, 0x09,
    ]);
    expect(() => decodeTagSetPool(new DataView(buf.buffer))).toThrow(
      /tag_set_tag_ids_not_ascending_or_unique/,
    );
  });

  it("rejects truncated tag_ids payload", () => {
    const buf = new Uint8Array([
      // set_count = 1, tag_count = 2, but only 1 tag id worth of bytes
      0x00, 0x00, 0x00, 0x01,
      0x00, 0x02,
      0x00, 0x00, 0x00, 0x01,
    ]);
    expect(() => decodeTagSetPool(new DataView(buf.buffer))).toThrow(
      /truncated_tag_sets_section/,
    );
  });
});
