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
    payload = %Payload{cells: :binary.copy(<<11, 0>>, 66 * 66 * 66),
      records: %{{1, 2, 3} => skins, {4, 5, 6} => skins}}
    overrides = %{{1, 2, 3} => {11, skins}, {7, 8, 9} => {11, skins}}
    assert Payload.min_body_bytes(payload, overrides) == 592_490
    bytes = Payload.encode(payload, overrides, 0, 1)
    assert {:ok, _, raw} = Codec.unpack_payload_body(bytes)
    assert byte_size(raw) == 592_490
    assert {:ok, decoded} = Payload.decode(bytes)
    assert Enum.sort(Map.keys(decoded.records)) == [{1, 2, 3}, {4, 5, 6}, {7, 8, 9}]
  end

  test "uniform override removes the final record and its row_start" do
    payload = %Payload{cells: :binary.copy(<<11, 0>>, 66 * 66 * 66),
      records: %{{1, 2, 3} => Skins.uniform(19)}}
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
