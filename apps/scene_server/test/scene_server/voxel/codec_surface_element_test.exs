defmodule SceneServer.Voxel.CodecSurfaceElementTest do
  # 形态轨 · 表面元件层 M4:ChunkSnapshot 表面元件 section(0x08,append-only,仅非空发射)wire 编解码。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.SurfaceCatalog
  alias SceneServer.Voxel.Types

  # ChunkSnapshot 头部:request_id(8)+scene(8)+coord(12)+schema(2)+chunk_size(1)+micro(1)+
  # version(8)+hash(8) = 48 字节,随后 section_count u16。
  defp section_count(payload) do
    <<_::binary-size(48), count::unsigned-big-integer-size(16), _::binary>> = payload
    count
  end

  defp with_decal(storage, macro_coord, face, type_name) do
    Storage.put_surface_element(storage, %{
      macro_index: Types.macro_index!(macro_coord),
      face: face,
      surface_type_id: SurfaceCatalog.surface_type_id(type_name)
    })
  end

  test "无表面元件:仍 7 段(向后兼容,不发射 0x08)" do
    storage = Storage.new(7, {0, 0, 0})
    payload = Codec.encode_chunk_snapshot_payload(storage)
    assert section_count(payload) == 7
  end

  test "有表面元件:8 段(追加 0x08)" do
    storage = with_decal(Storage.new(7, {0, 0, 0}), {1, 0, 0}, :x_pos, :rust_decal)
    payload = Codec.encode_chunk_snapshot_payload(storage)
    assert section_count(payload) == 8
  end

  test "round-trip:表面元件编解码还原" do
    storage =
      Storage.new(7, {2, 3, 4})
      |> with_decal({1, 0, 0}, :x_pos, :rust_decal)
      |> with_decal({1, 0, 0}, :y_neg, :frost)
      |> with_decal({5, 2, 1}, :z_pos, :torch)
      |> Storage.put_surface_element(%{
        macro_index: Types.macro_index!({3, 0, 0}),
        face: :x_neg,
        surface_type_id: SurfaceCatalog.surface_type_id(:scorch),
        attribute_set_ref: 7,
        tag_set_ref: 9,
        owner_actor_id: 12_345
      })

    payload = Codec.encode_chunk_snapshot_payload(storage)
    {:ok, decoded} = Codec.decode_chunk_snapshot_payload(payload)

    assert decoded.storage.surface_elements == storage.surface_elements
    # 全部字段还原(取那条带状态/owner 的)。
    el = Storage.surface_element_at(decoded.storage, Types.macro_index!({3, 0, 0}), :x_neg)
    assert el.surface_type_id == SurfaceCatalog.surface_type_id(:scorch)
    assert el.attribute_set_ref == 7
    assert el.tag_set_ref == 9
    assert el.owner_actor_id == 12_345
  end

  test "round-trip:表面元件 + 实心块共存(贴面与体积正交)" do
    iron = MaterialCatalog.material_id(:iron)
    macro = Types.macro_index!({1, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> Storage.put_solid_block(macro, NormalBlockData.new(iron))
      |> with_decal({1, 0, 0}, :x_pos, :rust_decal)

    payload = Codec.encode_chunk_snapshot_payload(storage)
    {:ok, decoded} = Codec.decode_chunk_snapshot_payload(payload)

    assert Storage.normal_block_at(decoded.storage, macro).material_id == iron
    assert Storage.surface_element_at(decoded.storage, macro, :x_pos).surface_type_id ==
             SurfaceCatalog.surface_type_id(:rust_decal)
  end

  test "chunk_hash 纳入表面元件:有/无 表面元件 hash 不同;空表面元件 hash 不变(向后兼容)" do
    base = Storage.new(7, {0, 0, 0})
    decaled = with_decal(base, {1, 0, 0}, :x_pos, :rust_decal)

    assert Codec.chunk_hash(decaled) != Codec.chunk_hash(base)

    # 空表面元件 truth payload 不追加任何字节 → 与"从未有 surface_elements 字段"等价。
    assert Codec.chunk_hash(%{base | surface_elements: []}) == Codec.chunk_hash(base)
  end
end
