import {
  AttributeValueType,
  decodeAttributeSetPool,
  type AttributeSet,
} from "./attributeSet";

describe("decodeAttributeSetPool", () => {
  it("decodes an empty pool from <<0u32>>", () => {
    const buffer = new Uint8Array(4); // all zero == count 0
    const view = new DataView(buffer.buffer);
    expect(decodeAttributeSetPool(view)).toEqual([]);
  });

  it("rejects unknown value_type tags", () => {
    // count=1, set { entry_count=1, key_id=0xAA, value_type=0x99, ... }
    const buf = new Uint8Array([
      0x00, 0x00, 0x00, 0x01, // set_count = 1
      0x00, 0x01,             // entry_count = 1
      0x00, 0x00, 0x00, 0xaa, // key_id = 0xAA
      0x99,                   // value_type = unknown
      0x00, 0x00,             // 2 bytes of "value" (won't be reached)
    ]);
    expect(() =>
      decodeAttributeSetPool(new DataView(buf.buffer)),
    ).toThrow(/unknown_attribute_value_type/);
  });

  it("decodes all 5 value_type tags in a single set", () => {
    // schema_kind list mirrors AttributeEntry.value_type_payload_size:
    //   I16(0x01): 2B,  U16(0x02): 2B,  Fixed32(0x03): 4B,
    //   Enum8(0x04): 1B,  Bitset32(0x05): 4B.
    // We craft one set with 5 entries, key_ids ascending.
    const buf = new Uint8Array([
      // set_count
      0x00, 0x00, 0x00, 0x01,
      // entry_count
      0x00, 0x05,
      // entry 1: key_id=1, type=I16, value=-2
      0x00, 0x00, 0x00, 0x01, 0x01, 0xff, 0xfe,
      // entry 2: key_id=2, type=U16, value=0xABCD
      0x00, 0x00, 0x00, 0x02, 0x02, 0xab, 0xcd,
      // entry 3: key_id=3, type=Fixed32, raw=0x00018000 → 1.5
      0x00, 0x00, 0x00, 0x03, 0x03, 0x00, 0x01, 0x80, 0x00,
      // entry 4: key_id=4, type=Enum8, value=0x07
      0x00, 0x00, 0x00, 0x04, 0x04, 0x07,
      // entry 5: key_id=5, type=Bitset32, bits=0xCAFEBABE
      0x00, 0x00, 0x00, 0x05, 0x05, 0xca, 0xfe, 0xba, 0xbe,
    ]);
    const sets = decodeAttributeSetPool(new DataView(buf.buffer));
    expect(sets).toHaveLength(1);
    const set = sets[0] as AttributeSet;
    expect(set.entries).toHaveLength(5);
    const [e1, e2, e3, e4, e5] = set.entries;
    expect(e1).toEqual({
      keyId: 1,
      value: { type: AttributeValueType.I16, value: -2 },
    });
    expect(e2).toEqual({
      keyId: 2,
      value: { type: AttributeValueType.U16, value: 0xabcd },
    });
    expect(e3).toEqual({
      keyId: 3,
      value: { type: AttributeValueType.Fixed32, raw: 0x00018000, asFloat: 1.5 },
    });
    expect(e4).toEqual({
      keyId: 4,
      value: { type: AttributeValueType.Enum8, value: 0x07 },
    });
    expect(e5).toEqual({
      keyId: 5,
      value: { type: AttributeValueType.Bitset32, bits: 0xcafebabe },
    });
  });

  it("rejects trailing bytes after an empty pool", () => {
    const buf = new Uint8Array([0, 0, 0, 0, 0xff]);
    expect(() => decodeAttributeSetPool(new DataView(buf.buffer))).toThrow(
      /trailing_attribute_sets_bytes/,
    );
  });
});
