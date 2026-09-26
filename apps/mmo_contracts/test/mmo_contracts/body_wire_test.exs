defmodule MmoContracts.BodyWireTest do
  @moduledoc """
  只测试：BodyState 线格式冻结样本（魔法增量 4 引入于 Hello 26；身体闭环 H1 于 Hello 29 追加字段；M1 Session 领域 1、kind 12，大端）。
  客户端 `Voxim.Net.BodyState` Automation 用同一串手写字节。

  样本（102 字节体 = 0x66）：identity (1, 2, 3)，生命 70（0x46），状态 0，核心 310.0 K（0x4073600000000000），
  皮肤 307.5 K（0x4073380000000000），伤病 2 条：`trauma.thermal.burn`（19 字节）严重度 3、愈合进度 50 %（0x32）；
  `temperature.hypothermia`（23 字节）严重度 1、进度 0；末尾蛋白质储备 42.5 g（0x4045400000000000）。
  Hello 29 相对 Hello 28：每条伤病在严重度后追加 heal u8（0..100），体末尾追加 protein_g f64，共多 2 × 1 + 8 = 10 字节。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.Session

  @sample Base.decode16!(
            "FF0001010C00000066" <>
              "0000000000000001" <> "0000000000000002" <> "0000000000000003" <>
              "46" <> "00" <> "4073600000000000" <> "4073380000000000" <>
              "0002" <> "0013" <> "747261756D612E746865726D616C2E6275726E" <> "03" <> "32" <>
              "0017" <> "74656D70657261747572652E6879706F746865726D6961" <> "01" <> "00" <>
              "4045400000000000"
          )

  @value %Session.BodyState{
    identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
    life: 70,
    status: 0,
    core_k: 310.0,
    skin_k: 307.5,
    injuries: [
      %Session.BodyInjury{tag: "trauma.thermal.burn", severity: 3, heal: 50},
      %Session.BodyInjury{tag: "temperature.hypothermia", severity: 1, heal: 0}
    ],
    protein_g: 42.5
  }

  test "Hello 29：Hello 28 在线边界拒绝" do
    assert Session.Codec.protocol_version() == 29
    {:ok, packet} = Session.Codec.encode(%Session.Hello{protocol_version: 29, kernel_id: <<1::256>>, profile_id: <<2::256>>})
    <<prefix::binary-size(9), 29::16, tail::binary>> = IO.iodata_to_binary(packet)
    assert {:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<28::16>> <> tail)
  end

  # 身体闭环 H1（Hello 29）：进食沿用 0x7F 生产信封（38 字节），action 5、material = 可食材料（这里蒲公英 36），坐标不用、填 0。
  test "进食意图 0x7F action 5 冻结样本" do
    wire = Base.decode16!("7F" <> "0000000000000016" <> "00000009" <> "0000000000000001" <> "05" <>
                            "000000000000000000000000" <> "0001" <> "0024")
    assert byte_size(wire) == 38

    assert {:ok, {:voxel_production_intent, %{request_id: 22, client_intent_seq: 9, logical_scene_id: 1, action: 5,
                                              coord: {0, 0, 0}, tool_id: 1, material: 36}}} =
             MmoContracts.Voxel.Codec.decode(wire)
  end

  test "BodyState 冻结样本：编码逐字节相等、解码还原" do
    {:ok, bytes} = Session.Codec.encode(@value)
    assert IO.iodata_to_binary(bytes) == @sample
    assert {:ok, @value} = Session.Codec.decode(@sample)
  end

  test "BodyState 拒绝：生命 > 100、状态 > 2、严重度 0、愈合进度 > 100、蛋白为负、截断" do
    <<head::binary-size(33), _life, rest::binary>> = @sample
    assert {:error, _} = Session.Codec.decode(head <> <<101>> <> rest)
    <<head::binary-size(34), _status, rest::binary>> = @sample
    assert {:error, _} = Session.Codec.decode(head <> <<3>> <> rest)
    # 第二条伤病：严重度在倒数第 10 字节、进度在倒数第 9 字节（其后是 8 字节蛋白）
    n = byte_size(@sample)
    assert {:error, _} = Session.Codec.decode(binary_part(@sample, 0, n - 10) <> <<0>> <> binary_part(@sample, n - 9, 9))
    assert {:error, _} = Session.Codec.decode(binary_part(@sample, 0, n - 9) <> <<101>> <> binary_part(@sample, n - 8, 8))
    assert {:ok, _} = Session.Codec.decode(binary_part(@sample, 0, n - 9) <> <<100>> <> binary_part(@sample, n - 8, 8))
    assert {:error, _} = Session.Codec.decode(binary_part(@sample, 0, n - 8) <> <<-1.0::float-64>>)
    assert {:error, _} = Session.Codec.decode(binary_part(@sample, 0, n - 1))
  end
end
