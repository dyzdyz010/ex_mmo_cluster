defmodule MmoContracts.OreSortWireTest do
  @moduledoc """
  只测试：Items 增量 1 徒手分选（Voxim `Docs/Items.md` §3.2，冻结契约 2026-11-09）的线格式。

  分选沿用 0x7F 生产信封（38 字节，字节格式不变）：action 6 = 分选一份，material = 混合矿 id，tool = 24（`ore.sort`），
  坐标忽略、填 0；action 7 = 取消当前分选（tool 仍须 > 0，material 忽略）。Hello 升到 44，43 在线边界拒绝。
  样本按大端字段手写十六进制，不由编码器生成。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.{Session, Voxel}

  test "分选一份 0x7F action 6 冻结样本：贫铜矿 89、工具 24" do
    wire =
      Base.decode16!(
        "7F" <>
          "0000000000000017" <>
          "0000000A" <>
          "0000000000000001" <>
          "06" <>
          "000000000000000000000000" <> "0018" <> "0059"
      )

    assert byte_size(wire) == 38

    assert {:ok,
            {:voxel_production_intent,
             %{request_id: 23, client_intent_seq: 10, logical_scene_id: 1, action: 6, coord: {0, 0, 0}, tool_id: 24,
               material: 89} = request}} = Voxel.Codec.decode(wire)

    refute Map.has_key?(request, :target)
  end

  test "取消分选 0x7F action 7 冻结样本；工具 0 与 action 8 拒绝" do
    wire =
      Base.decode16!(
        "7F" <>
          "0000000000000018" <>
          "0000000B" <>
          "0000000000000001" <>
          "07" <>
          "000000000000000000000000" <> "0018" <> "0000"
      )

    assert byte_size(wire) == 38

    assert {:ok,
            {:voxel_production_intent,
             %{request_id: 24, client_intent_seq: 11, action: 7, tool_id: 24, material: 0}}} =
             Voxel.Codec.decode(wire)

    <<head::binary-size(34), _tool::16, material::binary>> = wire
    assert {:error, :invalid_message} = Voxel.Codec.decode(head <> <<0::16>> <> material)
    <<head::binary-size(21), _action, rest::binary>> = wire
    assert {:error, :invalid_message} = Voxel.Codec.decode(head <> <<8>> <> rest)
  end

  test "Hello 44：Hello 43 在线边界拒绝" do
    assert Session.Codec.protocol_version() == 44
    {:ok, packet} = Session.Codec.encode(%Session.Hello{protocol_version: 44, kernel_id: <<1::256>>, profile_id: <<2::256>>})
    <<prefix::binary-size(9), 0x00, 0x2C, tail::binary>> = IO.iodata_to_binary(packet)
    assert {:ok, %Session.Hello{protocol_version: 44}} = Session.Codec.decode(prefix <> <<44::16>> <> tail)
    assert {:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<43::16>> <> tail)
  end
end
