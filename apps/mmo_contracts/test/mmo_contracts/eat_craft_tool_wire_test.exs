defmodule MmoContracts.EatCraftToolWireTest do
  @moduledoc """
  只测试：Voxim 交互设计“2026-11-09 修订”第 3 步——吃（0x7F action 5）与合成（action 4）不再携带工具编号：
  tool 字段填 0 也合法，字节格式不变（38 字节信封）；服务端本来不读这两种动作的工具。其它 action 仍要求 tool > 0。
  样本按大端字段手写十六进制，不由编码器生成。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel

  # 0x7F | request_id u64 | client_intent_seq u32 | logical_scene_id u64 | action u8 | coord 3×i32 | tool u16 | material u16
  defp wire(action, tool, material),
    do:
      Base.decode16!(
        "7F" <>
          "0000000000000031" <>
          "00000005" <>
          "0000000000000001" <>
          action <>
          "000000000000000000000000" <> tool <> material
      )

  test "吃 action 5、工具 0、蒲公英 36 解码" do
    bytes = wire("05", "0000", "0024")
    assert byte_size(bytes) == 38

    assert {:ok,
            {:voxel_production_intent,
             %{
               request_id: 49,
               client_intent_seq: 5,
               action: 5,
               coord: {0, 0, 0},
               tool_id: 0,
               material: 36
             }}} =
             Voxel.Codec.decode(bytes)
  end

  test "合成 action 4、工具 0、开关 41 解码" do
    assert {:ok, {:voxel_production_intent, %{action: 4, tool_id: 0, material: 41}}} =
             Voxel.Codec.decode(wire("04", "0000", "0029"))
  end

  test "旧客户端带工具 1 的吃／合成仍解码" do
    assert {:ok, {:voxel_production_intent, %{action: 5, tool_id: 1}}} =
             Voxel.Codec.decode(wire("05", "0001", "0024"))

    assert {:ok, {:voxel_production_intent, %{action: 4, tool_id: 1}}} =
             Voxel.Codec.decode(wire("04", "0001", "0029"))
  end

  test "其它 action 工具 0 仍拒绝" do
    for action <- ~w(00 01 02 03 06 07) do
      assert {:error, :invalid_message} = Voxel.Codec.decode(wire(action, "0000", "000B")), action
    end
  end
end
