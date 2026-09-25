defmodule MmoContracts.BodyWireTest do
  @moduledoc """
  只测试：魔法增量 4 的 BodyState 线格式冻结样本（Hello 26，M1 Session 领域 1、kind 12，大端）。
  客户端 `Voxim.Net.BodyState` Automation 用同一串手写字节。

  样本（92 字节体）：identity (1, 2, 3)，生命 70（0x46），状态 0，核心 310.0 K（0x4073600000000000），
  皮肤 307.5 K（0x4073380000000000），伤病 2 条：`trauma.thermal.burn`（19 字节）严重度 3、
  `temperature.hypothermia`（23 字节）严重度 1。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.Session

  @sample Base.decode16!(
            "FF0001010C0000005C" <>
              "0000000000000001" <> "0000000000000002" <> "0000000000000003" <>
              "46" <> "00" <> "4073600000000000" <> "4073380000000000" <>
              "0002" <> "0013" <> "747261756D612E746865726D616C2E6275726E" <> "03" <>
              "0017" <> "74656D70657261747572652E6879706F746865726D6961" <> "01"
          )

  @value %Session.BodyState{
    identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
    life: 70,
    status: 0,
    core_k: 310.0,
    skin_k: 307.5,
    injuries: [
      %Session.BodyInjury{tag: "trauma.thermal.burn", severity: 3},
      %Session.BodyInjury{tag: "temperature.hypothermia", severity: 1}
    ]
  }

  test "Hello 27：Hello 26 在线边界拒绝" do
    assert Session.Codec.protocol_version() == 27
    {:ok, packet} = Session.Codec.encode(%Session.Hello{protocol_version: 27, kernel_id: <<1::256>>, profile_id: <<2::256>>})
    <<prefix::binary-size(9), 27::16, tail::binary>> = IO.iodata_to_binary(packet)
    assert {:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<26::16>> <> tail)
  end

  test "BodyState 冻结样本：编码逐字节相等、解码还原" do
    {:ok, bytes} = Session.Codec.encode(@value)
    assert IO.iodata_to_binary(bytes) == @sample
    assert {:ok, @value} = Session.Codec.decode(@sample)
  end

  test "BodyState 拒绝：生命 > 100、状态 > 2、严重度 0、截断" do
    <<head::binary-size(33), _life, rest::binary>> = @sample
    assert {:error, _} = Session.Codec.decode(head <> <<101>> <> rest)
    <<head::binary-size(34), _status, rest::binary>> = @sample
    assert {:error, _} = Session.Codec.decode(head <> <<3>> <> rest)
    assert {:error, _} = Session.Codec.decode(binary_part(@sample, 0, byte_size(@sample) - 1) <> <<0>>)
    assert {:error, _} = Session.Codec.decode(binary_part(@sample, 0, byte_size(@sample) - 1))
  end
end
