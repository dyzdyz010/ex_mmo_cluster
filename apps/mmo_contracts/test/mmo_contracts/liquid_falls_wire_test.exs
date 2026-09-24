defmodule MmoContracts.LiquidFallsWireTest do
  @moduledoc "只测试：Hello16 下落展示尾段；纯字节协议，不启动网络或数据库。"
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel.Codec

  test "full signed canonical frame and explicit empty clear have frozen little endian bytes" do
    base = %{seq: 73, entries: [], coarse: []}
    old = <<73::little-64, 0::little-32, 0::little-32>>
    assert IO.iodata_to_binary(Codec.encode_transaction(base)) == old
    assert {:ok, ^base} = Codec.decode_transaction(old)

    for {material, transfers, tail} <- [
          {21, [{{-2, -3, 4}, 1}, {{65, 7, -8}, 524_288}],
           <<2, 21::little-16, 2::little-32, -2::little-signed-32, -3::little-signed-32,
             4::little-signed-32, 1::little-32, 65::little-signed-32, 7::little-signed-32,
             -8::little-signed-32, 524_288::little-32>>},
          {22, [], <<2, 22::little-16, 0::little-32>>}
        ] do
      txn = Map.put(base, :liquid_falls, %{material: material, transfers: transfers})
      assert IO.iodata_to_binary(Codec.encode_transaction(txn)) == old <> tail
      assert {:ok, ^txn} = Codec.decode_transaction(old <> tail)
    end

    for invalid <- [
          <<1, 21::little-16, 0::little-32>>,
          <<2, 20::little-16, 0::little-32>>,
          <<2, 21::little-16, 1::little-32>>,
          <<2, 21::little-16, 1::little-32, 0::96, 0::little-32>>
        ] do
      assert {:error, :invalid_transaction} = Codec.decode_transaction(old <> invalid)
    end

    assert MmoContracts.Session.Codec.protocol_version() == 19
  end
end
