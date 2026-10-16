defmodule MmoContracts.PayloadReuseTest do
  use ExUnit.Case, async: true

  alias MmoContracts.Voxel.{Codec, Payload, Refined}

  # 只测试：编码复用与提前判定的纯格式小例。期望来自手算字节、zlib 流前缀不变量与完整编码的同一结果。
  @cells 66 * 66 * 66

  # 确定性的不可压缩字节（SHA-256 链），不依赖随机种子。
  defp noise(bytes) do
    Stream.iterate(:crypto.hash(:sha256, "voxim"), &:crypto.hash(:sha256, &1))
    |> Enum.take(div(bytes, 32) + 1)
    |> IO.iodata_to_binary()
    |> binary_part(0, bytes)
  end

  test "slot records are the hand-computed little-endian rows in slot order" do
    slots = %{3 => {11, {5, 1}}, 1 => {2, {5, 0}}}

    assert Refined.slot_records(slots) ==
             <<1::16-little, 2::16-little, 5::64-little, 0::32-little, 3::16-little, 11::16-little,
               5::64-little, 1::32-little>>

    assert Refined.encode(%{7 => slots}, %{}, 5) ==
             <<1::32-little, 7::32-little, 2::32-little>> <> Refined.slot_records(slots) <> <<0::32-little>>
  end

  test "given slot records reproduce the same refined suffix bytes" do
    a = %{0 => {11, {5, 0}}, 511 => {12, {5, 0}}}
    b = Map.new(0..40, &{&1, {11, {6, 0}}})
    instances = %{{5, 0} => %{definition_id: <<1::256>>, anchor: {0, 0, 0}, orientation: 0},
      {6, 0} => %{definition_id: <<2::256>>, anchor: {8, 0, 0}, orientation: 1}}

    assert Refined.encode(%{3 => a, 9 => b}, instances, 7, %{9 => Refined.slot_records(b)}) ==
             Refined.encode(%{3 => a, 9 => b}, instances, 7)
  end

  test "compressed prefix bytes never exceed the full body and track incompressible input" do
    prefix = noise(256 * 1024)
    full = prefix <> :binary.copy(<<0>>, 64 * 1024)
    emitted = Codec.compressed_prefix_bytes(prefix)

    assert emitted <= byte_size(:zlib.compress(full))
    # zlib 至多缓存一个未满的块（16384 个符号）与少量前视；不可压缩输入的大部分必须已经输出。
    assert emitted >= 200_000
  end

  test "encode_below only reports not_smaller when the full payload is that long" do
    terrain = %Payload{cells: noise(@cells * 2)}
    full = Payload.encode(terrain, %{}, 3, 1)
    assert byte_size(full) >= 500_000
    assert Payload.encode_below(terrain, %{}, 3, 1, 400_000) == :not_smaller
    assert Payload.encode_below(terrain, %{}, 3, 1, byte_size(full) + 1_000_000) == {:ok, full}

    # 均匀地形压缩到几乎为空：头 + 2 字节流头之外没有已输出字节，不足以证明任何像样的下限。
    flat = %Payload{cells: :binary.copy(<<11, 0>>, @cells)}
    flat_full = Payload.encode(flat, %{}, 3, 1)
    assert Payload.encode_below(flat, %{}, 3, 1, Codec.payload_header_bytes() + 2) == :not_smaller
    assert Payload.encode_below(flat, %{}, 3, 1, byte_size(flat_full)) == {:ok, flat_full}
  end

  test "decode_cells returns the materialized cell plane only" do
    cells = :binary.copy(<<11, 0>>, @cells)
    bytes = Payload.encode(%Payload{cells: cells}, %{{1, 2, 3} => {19, MmoContracts.Voxel.Skins.uniform(19)}}, 0, 1)
    {:ok, decoded} = Payload.decode(bytes)
    assert Payload.decode_cells(bytes) == {:ok, decoded.cells}
    assert binary_part(decoded.cells, (1 + 66 * (2 + 66 * 3)) * 2, 2) == <<19, 0>>
  end
end
