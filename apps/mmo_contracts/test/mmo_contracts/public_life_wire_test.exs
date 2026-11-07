defmodule MmoContracts.PublicLifeWireTest do
  @moduledoc "只测试：Hello42 公共生命字段的独立手写快照字节与拒绝边界。"
  use ExUnit.Case, async: true
  @moduletag :t0
  alias MmoContracts.Movement

  # 体长：identity 24 + tick 8 + count 2 + record 92 = 126；state 固定 51 字节全零。
  @packet <<255, 0, 1, 2, 3, 126::32, 1::64, 2::64, 3::64, 10::64, 1::16,
            7::64, 4::64, 5::64, 6::64, 0::408, 9::64, 2>>

  test "手写死亡快照具有完整生命代次并原字节重编码" do
    assert {:ok, %Movement.Snapshot{records: [record]} = message} = Movement.Codec.decode(@packet)
    assert %{entity_id: 7, entity_epoch: 4, interest_generation: 5, life_generation: 9, body_status: 2} = record
    assert {:ok, encoded} = Movement.Codec.encode(message)
    assert IO.iodata_to_binary(encoded) == @packet
  end

  test "缺失生命字段、零代次和未知身体状态都拒绝" do
    <<head::binary-size(5), _::32, body::binary>> = @packet
    old = binary_part(body, 0, byte_size(body)-9)
    assert {:error, _} = Movement.Codec.decode(head <> <<byte_size(old)::32>> <> old)
    prefix = binary_part(@packet, 0, byte_size(@packet)-9)
    assert {:error, _} = Movement.Codec.decode(prefix <> <<0::64, 0>>)
    assert {:error, _} = Movement.Codec.decode(prefix <> <<9::64, 3>>)
  end
end
