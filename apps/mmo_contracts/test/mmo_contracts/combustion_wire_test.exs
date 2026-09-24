defmodule MmoContracts.CombustionWireTest do
  use ExUnit.Case, async: true
  alias MmoContracts.{Session, Voxel}

  # 只测试：与 Voxim ConfirmedCombustion 测试使用同一组目标、能量与温度。
  defp state do
    %{
      request_id: 0,
      seq: 7,
      micro: {336, 4112, 504},
      granularity: 0,
      incarnation: 2,
      owner: {0, 0},
      material: 19,
      hp: 90.0,
      max_hp: 100.0,
      defense: 0.0,
      digest: :binary.copy(<<0xA5>>, 32),
      flags: 0,
      temperature_kelvin: 307.0
    }
  end

  defp bytes(row) do
    {:ok, packet} = Voxel.Codec.encode({:voxel_property_state, row})
    IO.iodata_to_binary(packet)
  end

  test "B7 Hello16 接纳，旧 Hello 在线边界拒绝" do
    assert Session.Codec.protocol_version() == 23
    hello = %Session.Hello{protocol_version: 23, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, packet} = Session.Codec.encode(hello)
    assert {:ok, ^hello} = Session.Codec.decode(packet)
    <<prefix::binary-size(9), 23::16, tail::binary>> = packet

    for version <- 1..22 do
      assert {:error, :invalid_m1_message} =
               Session.Codec.decode(prefix <> <<version::16>> <> tail)
    end
  end

  test "温度之后追加燃烧后缀，熄灭保留未耗燃料" do
    thermal = bytes(state())
    assert byte_size(thermal) == 129
    assert byte_size(bytes(Map.delete(state(), :temperature_kelvin))) == 121

    for {burning, flag, fuel, power} <- [
          {true, 1, 12345.0, 1000.0},
          {false, 0, 11000.0, 0.0},
          {false, 0, 0.0, 0.0}
        ] do
      packet =
        bytes(Map.merge(state(), %{burning: burning, remaining_fuel_j: fuel, power_w: power}))

      assert packet == thermal <> <<flag, fuel::float-64, power::float-64>>
      assert byte_size(packet) == 146
    end
  end

  test "完整属性快照与后续批次原样传输燃烧确认状态" do
    packet =
      bytes(Map.merge(state(), %{burning: true, remaining_fuel_j: 12345.0, power_w: 1000.0}))

    for complete <- [0, 1] do
      batch = %Voxel.PropertyBatch{
        identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
        transaction_seq: 7,
        l0_min: {0, 7, 0},
        l0_max_exclusive: {1, 9, 1},
        complete: complete,
        hp_enabled: 1,
        digest: state().digest,
        thermal_enabled: 1,
        ambient_kelvin: 293.15,
        epochs: <<>>,
        states: [packet]
      }

      assert {:ok, encoded} = Voxel.Codec.encode_m1(batch)
      assert {:ok, ^batch} = Voxel.Codec.decode_m1(encoded)
    end
  end
end
