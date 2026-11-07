defmodule MmoContracts.SkinFieldTest do
  @moduledoc "只测试：手写 CSR 线格式验证紧凑接纳、规范化与旧持久 Payload 迁移；不启动 World／网络。"
  use ExUnit.Case, async: true
  @moduletag :t0
  import Bitwise
  alias MmoContracts.Voxel.{Codec, Payload, Skins, SkinField}

  test "canonical CSR stays compact and reencodes to identical bytes" do
    raw = terrain(1_000)
    bytes = Codec.encode_payload(4, {1, 0, 2}, 7, 123, raw)
    assert {:ok, p} = Payload.decode(bytes)
    assert is_struct(p.records, SkinField)
    assert :erts_debug.flat_size(p) < 256
    assert Payload.skin_count(p) == 1_000
    assert Payload.skins(p, {0, 0, 0}, 11) == Skins.uniform(19)
    assert Payload.skins(p, {10, 20, 30}, 11) == Skins.uniform(11)
    assert Payload.encode(p, %{}, 7, 123) == bytes
  end

  test "legacy persisted map and replacing records cannot reuse stale compact bytes" do
    legacy = %Payload{cells: :binary.copy(<<11, 0>>, 287_496),
      records: %{{1, 2, 3} => {19 + (19 <<< 8) + (19 <<< 16) + (19 <<< 24) + (19 <<< 32) + (19 <<< 40), 0, 0}}}
    persisted = legacy |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    p = Payload.admit(persisted)
    assert is_struct(p.records, SkinField)
    assert Payload.encode(p, %{}, 9, 123) == Payload.encode(legacy, %{}, 9, 123)
    replaced = %{p | records: %{{4, 5, 6} => Skins.uniform(23)}}
    expected = %{legacy | records: %{{4, 5, 6} => Skins.uniform(23)}}
    assert Payload.encode(replaced, %{}, 9, 123) == Payload.encode(expected, %{}, 9, 123)
    assert {:ok, changed} = Payload.decode(Payload.encode(p, %{{1, 2, 3} => {11, Skins.uniform(11)}}, 10, 123))
    assert Payload.skin_count(changed) == 0
  end

  test "valid noncanonical pool is normalized, including unused duplicate and uniform maps" do
    # 第一条记录的 face0 指向 pool1；pool0 未使用且重复，pool2 是与 face1 相同的均匀贴图。
    texture = <<1, 2, 3, 4>>
    raw = terrain(1, <<3::16-little>>, <<1::16-little, 2::16-little>>, texture <> texture <> <<19, 19, 19, 19>>, 2)
    bytes = Codec.encode_payload(1, {0, 0, 0}, 7, 123, raw)
    assert {:ok, p} = Payload.decode(bytes)
    canonical = terrain(1, <<1::16-little>>, <<0::16-little>>, texture, 2)
    assert {:ok, _, ^canonical} = Codec.unpack_payload_body(Payload.encode(p, %{}, 7, 123))
  end

  test "all face masks keep exact bytes and lookup uses the right face-map base" do
    for mask <- 0..63 do
      texture = <<1, 2, 3, 4>>
      fmi = for face <- 0..5, (mask &&& (1 <<< face)) != 0, into: <<>>, do: <<0::16>>
      raw = terrain(1, <<mask::16-little>>, fmi, if(mask == 0, do: <<>>, else: texture), 2)
      bytes = Codec.encode_payload(1, {0, 0, 0}, 7, 123, raw)
      assert {:ok, p} = Payload.decode(bytes)
      expected = Skins.canonical({2, List.to_tuple(for face <- 0..5,
        do: {19, if((mask &&& (1 <<< face)) == 0, do: nil, else: texture)})})
      assert Payload.skins(p, {0, 0, 0}, 11) == expected
      assert Payload.encode(p, %{}, 7, 123) == bytes
    end
  end

  test "first-use order and unused unique pool entries normalize independently" do
    a = <<1, 2, 3, 4>>
    b = <<5, 6, 7, 8>>
    for {mask, fmi, maps, wanted_fmi, wanted_maps} <- [
      {3, <<1::16-little, 0::16-little>>, b <> a, <<0::16-little, 1::16-little>>, a <> b},
      {1, <<0::16-little>>, a <> b, <<0::16-little>>, a}
    ] do
      bytes = Codec.encode_payload(1, {0, 0, 0}, 7, 123, terrain(1, <<mask::16-little>>, fmi, maps, 2))
      assert {:ok, p} = Payload.decode(bytes)
      expected = terrain(1, <<mask::16-little>>, wanted_fmi, wanted_maps, 2)
      assert {:ok, _, ^expected} = Codec.unpack_payload_body(Payload.encode(p, %{}, 7, 123))
    end
  end

  test "legacy empty CSR map extent normalizes to one without retaining stale fields" do
    raw = IO.iodata_to_binary([<<287_496::32-little>>, :binary.copy(<<11, 0>>, 287_496),
      <<0::32, 0::32, 0::32, 4::32-little, 0::32, 0::32, 0::32, 0::32, 0::32>>])
    assert {:ok, p} = Payload.decode(Codec.encode_payload(0, {0, 0, 0}, 0, 123, raw))
    assert Payload.skin_extent(p) == 1
    assert Payload.skin_count(p) == 0
    expected = Payload.encode(%Payload{cells: p.cells}, %{}, 0, 123)
    assert Payload.encode(p, %{}, 0, 123) == expected
  end

  defp terrain(n, masks \\ nil, fmi \\ <<>>, maps \\ <<>>, ext \\ 1) do
    rows = for row <- 0..4356, into: <<>>, do: <<min(row * 66, n)::32-little>>
    xs = for i <- 0..(n - 1), into: <<>>, do: <<rem(i, 66)::16-little>>
    masks = masks || :binary.copy(<<0, 0>>, n)
    IO.iodata_to_binary([<<287_496::32-little>>, :binary.copy(<<11, 0>>, 287_496),
      <<66::32-little, 66::32-little, 66::32-little, ext::32-little, 4357::32-little>>, rows,
      <<n::32-little>>, xs, <<n::32-little>>, :binary.copy(<<19>>, n * 6), masks,
      <<div(byte_size(fmi), 2)::32-little>>, fmi, <<byte_size(maps)::32-little>>, maps])
  end
end
