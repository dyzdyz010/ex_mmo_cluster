defmodule MmoContracts.EntityEnterWireTest do
  @moduledoc """
  只测试：EntityEnter 在 Hello 39 末尾追加的阵营字段（Voxim Docs/Factions.md §10），大端。
  kind 之后依次：name utf8（u16 长度 + 字节）、guild_name utf8、nation_name utf8、relation u8、relation_source utf8。
  手写字节："阿岚" = E9 98 BF E5 B2 9A（6 字节）；"敌" = E6 95 8C（3 字节）；空串 = 0000。
  客户端 `MmoSessionCodec` Automation 用同一串尾部字节。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.Session

  @tail Base.decode16!("00" <> "0006E998BFE5B29A" <> "0000" <> "0000" <> "04" <> "0003E6958C")

  @value %Session.EntityEnter{
    identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
    entity_id: 7,
    entity_epoch: 10,
    interest_generation: 1,
    server_tick: 20,
    state: %Session.State{position: {4.0, 0.0, 0.0}, velocity: {0.0, 0.0, 0.0}, grounded: 1, yaw: 0},
    kind: 0,
    name: "阿岚",
    guild_name: "",
    nation_name: "",
    relation: 4,
    relation_source: "敌"
  }

  test "阵营字段紧跟 kind 写在末尾，解码还原同一值" do
    {:ok, packet} = Session.Codec.encode(@value)
    packet = IO.iodata_to_binary(packet)

    assert binary_part(packet, byte_size(packet) - byte_size(@tail), byte_size(@tail)) == @tail
    assert {:ok, @value} = Session.Codec.decode(packet)
  end

  test "截掉阵营字段的旧格式拒绝" do
    {:ok, packet} = Session.Codec.encode(@value)
    packet = IO.iodata_to_binary(packet)
    <<head::binary-size(5), _len::32, body::binary>> = packet
    old = binary_part(body, 0, byte_size(body) - (byte_size(@tail) - 1))

    assert {:error, _} = Session.Codec.decode(head <> <<byte_size(old)::32>> <> old)
  end
end
