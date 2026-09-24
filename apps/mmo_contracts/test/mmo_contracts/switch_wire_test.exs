defmodule MmoContracts.SwitchWireTest do
  use ExUnit.Case, async: true
  alias MmoContracts.{Session, Voxel}

  # 只测试：协议 21（R8-04 增量 2）。样本逐字段手写，与 Voxim `Voxim.R8.Switch.Wire` 同一份字节：
  # 一块宏面开关附件（材料 41，整件 ID 77，面轴 y → owner {77, 1}）闭合，环境温度 293.15 K，HP 12.5。
  @digest :binary.copy(<<0xA5>>, 32)
  @head <<0x7E, 0::64, 12::64, 8::signed-64, 16::signed-64, 24::signed-64, 3, 77::64, 77::64, 1::32,
          41::16, 12.5::float-64, 12.5::float-64, 8.0::float-64>> <> @digest
  # flags：位 0 删除，位 1 发光后缀，位 2 = 开关闭合（无后缀）。
  @closed @head <> <<4, 293.15::float-64>>
  @open @head <> <<0, 293.15::float-64>>

  defp row do
    %{request_id: 0, seq: 12, micro: {8, 16, 24}, granularity: 3, incarnation: 77, owner: {77, 1},
      material: 41, hp: 12.5, max_hp: 12.5, defense: 8.0, digest: @digest, flags: 0, temperature_kelvin: 293.15}
  end

  defp bytes(row) do
    {:ok, packet} = Voxel.Codec.encode({:voxel_property_state, row})
    IO.iodata_to_binary(packet)
  end

  test "闭合的开关行 flags 位 2、无后缀，逐字节等于手写样本；断开与缺省同为 0" do
    assert byte_size(@closed) == 129
    assert bytes(Map.put(row(), :closed, true)) == @closed
    assert bytes(Map.put(row(), :closed, false)) == @open
    assert bytes(row()) == @open

    assert Base.encode16(@closed, case: :lower) ==
             "7e0000000000000000000000000000000c0000000000000008000000000000001000000000000000180300000000000000" <>
               "4d000000000000004d000000010029402900000000000040290000000000004020000000000000" <>
               String.duplicate("a5", 32) <> "044072526666666666"

    # 删除（位 0）与闭合（位 2）互不干扰。
    assert binary_part(bytes(Map.merge(row(), %{closed: true, flags: 1})), 120, 1) == <<5>>
  end

  test "合成意图沿用 0x7F 生产信封，action 4 = 按目录配方合成 material 一次；5 仍非法" do
    wire = <<0x7F, 21::64, 8::32, 1::64, 4, 0::signed-32, 0::signed-32, 0::signed-32, 1::16, 41::16>>
    assert byte_size(wire) == 38
    assert Base.encode16(wire, case: :lower) == "7f00000000000000150000000800000000000000010400000000000000000000000000010029"

    assert {:ok, {:voxel_production_intent, %{request_id: 21, client_intent_seq: 8, action: 4, material: 41, tool_id: 1}}} =
             Voxel.Codec.decode(wire)

    assert {:error, :invalid_message} = Voxel.Codec.decode(<<0x7F, 21::64, 8::32, 1::64, 5, 0::96, 1::16, 41::16>>)
  end

  test "Hello 21：Hello 20 在线边界拒绝" do
    assert Session.Codec.protocol_version() == 21
    hello = %Session.Hello{protocol_version: 21, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, packet} = Session.Codec.encode(hello)
    <<prefix::binary-size(9), 21::16, tail::binary>> = packet
    assert {:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<20::16>> <> tail)
  end
end
