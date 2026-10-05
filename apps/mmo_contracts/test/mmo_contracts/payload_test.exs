defmodule MmoContracts.PayloadTest do
  use ExUnit.Case, async: true

  alias MmoContracts.Voxel.{Codec, Payload, Skins}

  # 只测试：纯载荷格式的小例；手算固定段、CSR 平面与 row_start，不验证压缩率。
  test "raw lower bound omits row_start for an empty CSR" do
    payload = %Payload{cells: :binary.copy(<<11, 0>>, 66 * 66 * 66)}
    assert Payload.min_body_bytes(payload, %{}) == 575_032
    bytes = Payload.encode(payload, %{}, 0, 1)
    assert {:ok, _, raw} = Codec.unpack_payload_body(bytes)
    assert byte_size(raw) == 575_032
  end

  test "raw lower bound counts retained and replaced records once" do
    skins = Skins.uniform(19)

    payload = %Payload{
      cells: :binary.copy(<<11, 0>>, 66 * 66 * 66),
      records: %{{1, 2, 3} => skins, {4, 5, 6} => skins}
    }

    overrides = %{{1, 2, 3} => {11, skins}, {7, 8, 9} => {11, skins}}
    assert Payload.min_body_bytes(payload, overrides) == 592_490
    bytes = Payload.encode(payload, overrides, 0, 1)
    assert {:ok, _, raw} = Codec.unpack_payload_body(bytes)
    assert byte_size(raw) == 592_490
    assert {:ok, decoded} = Payload.decode(bytes)
    assert Enum.sort(Map.keys(decoded.records)) == [{1, 2, 3}, {4, 5, 6}, {7, 8, 9}]
  end

  test "uniform override removes the final record and its row_start" do
    payload = %Payload{
      cells: :binary.copy(<<11, 0>>, 66 * 66 * 66),
      records: %{{1, 2, 3} => Skins.uniform(19)}
    }

    overrides = %{{1, 2, 3} => {11, Skins.uniform(11)}}
    assert Payload.min_body_bytes(payload, %{}) == 592_470
    assert Payload.min_body_bytes(payload, overrides) == 575_032
    bytes = Payload.encode(payload, overrides, 0, 1)
    assert {:ok, _, raw} = Codec.unpack_payload_body(bytes)
    assert byte_size(raw) == 575_032
    assert {:ok, %{records: records}} = Payload.decode(bytes)
    assert records == %{}
  end
end

defmodule MmoContracts.PayloadCanonicalEncodingTest do
  # 只测试：call_count 属于 VM 全局追踪，独占串行用例；产品不增加计数或分支。
  use ExUnit.Case, async: false

  alias MmoContracts.Voxel.{Codec, Payload, Skins}

  @moduletag :payload_face_reuse

  test "packed face ids, uniform collapse and first-use output pool keep hand-calculated bytes" do
    {payload, overrides} = packed_fixture()
    bytes = Payload.encode(payload, overrides, 42, 99)

    expected =
      expected_body(
        payload.cells,
        <<3::16-little, 6::16-little, 6::16-little>>,
        <<0::16-little, 1::16-little, 1::16-little, 0::16-little, 1::16-little, 0::16-little>>,
        <<8, 7, 7, 7, 7, 7, 7, 7>>
      )

    assert {:ok, _, ^expected} = Codec.unpack_payload_body(bytes)
    assert bytes == Codec.encode_payload(1, {-1, 2, -3}, 42, 99, expected, 4)
  end

  test "repeated packed faces normalize at most once per referenced source index and face id" do
    {payload, overrides} = packed_fixture()
    {:module, Skins} = :code.ensure_loaded(Skins)
    mfa = {Skins, :canonical_face, 1}
    assert :erlang.trace_pattern(mfa, true, [:call_count]) == 1

    try do
      Payload.encode(payload, overrides, 42, 99)
      # 两条保留记录共12面，但仅有4种带图输入：(0,7)、(0,8)、(2,9)、(1,9)。
      # 被覆盖删除的第三条记录不应规范化；均匀无图面不需要扫描贴图。
      assert {:call_count, count} = :erlang.trace_info(mfa, :call_count)
      assert count <= 4
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  test "source texture index is scoped to one encode call" do
    {payload, overrides} = packed_fixture()
    first = Payload.encode(payload, overrides, 42, 99)
    changed = %{payload | maps: <<8, 8, 8, 8, 8, 7, 7, 7, 8, 7, 7, 7, 5, 4, 3, 2>>}
    second = Payload.encode(changed, overrides, 42, 99)

    # 同一index0改为全8后，id7的面保留贴图、id8的面折叠，mask由6变5。
    # override仍先插入mixed与全7；新的全8图排到输出pool2。
    expected =
      expected_body(
        payload.cells,
        <<3::16-little, 5::16-little, 5::16-little>>,
        <<0::16-little, 1::16-little, 2::16-little, 0::16-little, 2::16-little, 0::16-little>>,
        <<8, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8>>
      )

    refute first == second
    assert {:ok, _, ^expected} = Codec.unpack_payload_body(second)
    assert second == Codec.encode_payload(1, {-1, 2, -3}, 42, 99, expected, 4)
  end

  defp packed_fixture do
    # 源pool0全7，pool1/2同内容mixed，pool3只被将删除的记录引用。
    # id7+pool0折叠，id8+pool0必须保留，故复用键不能只有texture index。
    payload = %Payload{
      level: 1,
      region: {-1, 2, -3},
      cells: :binary.copy(<<11, 0>>, 66 * 66 * 66),
      map_extent: 2,
      records: %{
        {1, 0, 0} => {0x0C0B0A090807, 7, 0},
        {2, 0, 0} => {0x0C0B0A090807, 7, 3},
        {0, 1, 0} => {0x0C0B0A090807, 1, 6}
      },
      fmi:
        <<0::16-little, 0::16-little, 2::16-little, 0::16-little, 0::16-little, 1::16-little,
          3::16-little>>,
      maps: <<7, 7, 7, 7, 8, 7, 7, 7, 8, 7, 7, 7, 5, 4, 3, 2>>
    }

    overrides = %{
      {0, 0, 0} =>
        {11,
         {2,
          {{9, <<8, 7, 7, 7>>}, {8, <<7, 7, 7, 7>>}, {9, nil}, {10, nil}, {11, nil}, {12, nil}}}},
      {0, 1, 0} => {11, Skins.uniform(11)}
    }

    {payload, overrides}
  end

  defp expected_body(cells, masks, fmi, maps) do
    # 手算输出：row0恰有x=0/1/2三条记录；以后4356个row_start均为3。
    # 六个面id平面逐面排列，两个packed记录的face0保持7，override的face0为9。
    IO.iodata_to_binary([
      <<287_496::32-little>>,
      cells,
      <<66::32-little, 66::32-little, 66::32-little, 2::32-little>>,
      <<4357::32-little, 0::32-little>>,
      :binary.copy(<<3::32-little>>, 4356),
      <<3::32-little, 0::16-little, 1::16-little, 2::16-little, 3::32-little>>,
      <<9, 7, 7, 8, 8, 8, 9, 9, 9, 10, 10, 10, 11, 11, 11, 12, 12, 12>>,
      masks,
      <<6::32-little>>,
      fmi,
      <<byte_size(maps)::32-little>>,
      maps
    ])
  end
end
