defmodule MmoContracts.BeaconWireTest do
  @moduledoc """
  只测试：传送信标线格式（Hello 41，Voxim `Docs/Gameplay/Beacon.md`）冻结样本，客户端 C++ 编解码对同一串手写字节。

  - 上行 0x87 出发：request_id u64、client_intent_seq u32、scene u64、出发 id（u8 长度 + UTF-8）、目的 id（同），大端。
  - 下行 0x87 目录：request_id u64、条数 u16，每条 id（u8 长度）、站名（u16 长度 + UTF-8）、核心 x/y/z f64、已调谐 u8。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel.Codec

  test "上行出发帧解码；空 id 与截断拒绝" do
    bytes =
      <<0x87, 0, 0, 0, 0, 0, 0, 0, 7, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 1, 7, "qinglan", 6, "ruyuan">>

    assert Codec.decode(bytes) ==
             {:ok,
              {:voxel_beacon_travel,
               %{request_id: 7, client_intent_seq: 9, logical_scene_id: 1, from: "qinglan", to: "ruyuan"}}}

    assert Codec.decode(<<0x87, 7::64, 9::32, 1::64, 0, 6, "ruyuan">>) == {:error, :invalid_message}
    assert Codec.decode(binary_part(bytes, 0, byte_size(bytes) - 1)) == {:error, :invalid_message}
  end

  test "下行目录帧编码：中文站名按 UTF-8 字节计长" do
    entries = [
      %{id: "qinglan", name: "青岚驿", core: {0.5625, 2.5625, 0.5625}, landing: {0.5, 3.5, 1.5}, attuned: true},
      %{id: "r", name: "如园", core: {-1.0, 0.0, 4000.0}, landing: {0.0, 0.0, 0.0}, attuned: false}
    ]

    # 0.5625 = 0x3FE2000000000000，2.5625 = 0x4004800000000000，-1.0 = 0xBFF0…，4000.0 = 0x40AF400000000000。
    expected =
      <<0x87, 0, 0, 0, 0, 0, 0, 0, 5, 0, 2>> <>
        <<7, "qinglan", 0, 9, 0xE9, 0x9D, 0x92, 0xE5, 0xB2, 0x9A, 0xE9, 0xA9, 0xBF>> <>
        <<0x3F, 0xE2, 0, 0, 0, 0, 0, 0, 0x40, 0x04, 0x80, 0, 0, 0, 0, 0, 0x3F, 0xE2, 0, 0, 0, 0, 0, 0, 1>> <>
        <<1, "r", 0, 6, 0xE5, 0xA6, 0x82, 0xE5, 0x9B, 0xAD>> <>
        <<0xBF, 0xF0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0xAF, 0x40, 0, 0, 0, 0, 0, 0>>

    assert Codec.encode({:voxel_beacon_directory, %{request_id: 5, entries: entries}}) == {:ok, expected}
    assert Codec.encode({:voxel_beacon_directory, %{request_id: 0, entries: []}}) == {:ok, <<0x87, 0::64, 0::16>>}
  end
end
