defmodule MmoContracts.BodyWireTest do
  @moduledoc """
  只测试：BodyState 线格式冻结样本（魔法增量 4 引入于 Hello 26；身体闭环 H1 于 Hello 29、生命条可恢复段于 Hello 30 追加字段；
  M1 Session 领域 1、kind 12，大端）。客户端 `Voxim.Body.Wire` Automation 用同一串手写字节。

  样本（119 字节体 = 0x77）：identity (1, 2, 3)，生命 70（0x46），可恢复 2（0x02），状态 0，核心 310.0 K（0x4073600000000000），
  皮肤 307.5 K（0x4073380000000000），伤病 2 条：`trauma.thermal.burn`（19 字节）严重度 3、愈合进度 50 %（0x32）、
  剩余 350.5 s（0x4075E80000000000 = 1.0101111012 × 2^8）；`temperature.hypothermia`（23 字节）严重度 1、进度 0、剩余 0.0；
  末尾蛋白质储备 42.5 g（0x4045400000000000）。
  Hello 30 相对 Hello 29：生命后追加 recoverable u8，每条伤病 heal 后追加 remaining_s f64，共多 1 + 2 × 8 = 17 字节（102 → 119）。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.Session

  @sample Base.decode16!(
            "FF0001010C00000077" <>
              "0000000000000001" <> "0000000000000002" <> "0000000000000003" <>
              "46" <> "02" <> "00" <> "4073600000000000" <> "4073380000000000" <>
              "0002" <> "0013" <> "747261756D612E746865726D616C2E6275726E" <> "03" <> "32" <> "4075E80000000000" <>
              "0017" <> "74656D70657261747572652E6879706F746865726D6961" <> "01" <> "00" <> "0000000000000000" <>
              "4045400000000000"
          )

  @value %Session.BodyState{
    identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
    life: 70,
    recoverable: 2,
    status: 0,
    core_k: 310.0,
    skin_k: 307.5,
    injuries: [
      %Session.BodyInjury{tag: "trauma.thermal.burn", severity: 3, heal: 50, remaining_s: 350.5},
      %Session.BodyInjury{tag: "temperature.hypothermia", severity: 1, heal: 0, remaining_s: 0.0}
    ],
    protein_g: 42.5
  }

  test "Hello 30：Hello 29 在线边界拒绝" do
    assert Session.Codec.protocol_version() == 30
    {:ok, packet} = Session.Codec.encode(%Session.Hello{protocol_version: 30, kernel_id: <<1::256>>, profile_id: <<2::256>>})
    <<prefix::binary-size(9), 30::16, tail::binary>> = IO.iodata_to_binary(packet)
    assert {:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<29::16>> <> tail)
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

  test "BodyState 拒绝：生命 > 100、生命 + 可恢复 > 100、状态 > 2、严重度 0、愈合进度 > 100、剩余为约定外负值、蛋白为负、截断" do
    # 体内偏移（信封 9 字节 + identity 24）：生命 33、可恢复 34、状态 35
    <<head::binary-size(33), _life, rest::binary>> = @sample
    assert {:error, _} = Session.Codec.decode(head <> <<101>> <> rest)
    <<head::binary-size(34), _recoverable, rest::binary>> = @sample
    assert {:error, _} = Session.Codec.decode(head <> <<31>> <> rest)
    assert {:ok, %{recoverable: 30}} = Session.Codec.decode(head <> <<30>> <> rest)
    <<head::binary-size(35), _status, rest::binary>> = @sample
    assert {:error, _} = Session.Codec.decode(head <> <<3>> <> rest)
    # 第二条伤病：严重度在倒数第 18 字节、进度倒数第 17、剩余倒数第 16..9（其后是 8 字节蛋白）
    n = byte_size(@sample)
    remaining = fn v -> binary_part(@sample, 0, n - 16) <> <<v::float-64>> <> binary_part(@sample, n - 8, 8) end
    assert {:error, _} = Session.Codec.decode(binary_part(@sample, 0, n - 18) <> <<0>> <> binary_part(@sample, n - 17, 17))
    assert {:error, _} = Session.Codec.decode(binary_part(@sample, 0, n - 17) <> <<101>> <> binary_part(@sample, n - 16, 16))
    assert {:ok, _} = Session.Codec.decode(binary_part(@sample, 0, n - 17) <> <<100>> <> binary_part(@sample, n - 16, 16))
    assert {:ok, %{injuries: [_, %{remaining_s: -1.0}]}} = Session.Codec.decode(remaining.(-1.0))
    assert {:ok, %{injuries: [_, %{remaining_s: -2.0}]}} = Session.Codec.decode(remaining.(-2.0))
    assert {:error, _} = Session.Codec.decode(remaining.(-0.5))
    assert {:error, _} = Session.Codec.decode(remaining.(-3.0))
    assert {:error, _} = Session.Codec.decode(binary_part(@sample, 0, n - 8) <> <<-1.0::float-64>>)
    assert {:error, _} = Session.Codec.decode(binary_part(@sample, 0, n - 1))
  end
end
