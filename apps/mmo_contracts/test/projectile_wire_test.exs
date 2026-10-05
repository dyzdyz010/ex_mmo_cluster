defmodule MmoContracts.ProjectileWireTest do
  use ExUnit.Case, async: true
  alias MmoContracts.Session
  alias Session.Codec

  test "Hello38 和人物命中 108B 手写字段顺序" do
    assert Codec.protocol_version() == 38
    bytes = <<255, 1::16, 1, 14, 108::32, 1::64, 2::64, 3::64,
      40::64, 30::64, 0::32, 10::64, 11::64, 20::64, 21::64,
      2094.0::float-64, 1.5::float-64, -2.0::float-64, 3.0::float-64>>
    assert {:ok, hit} = Codec.decode(bytes)
    assert hit.__struct__ == Session.ProjectileHit
    assert hit.world_seq == 40 and hit.projectile_seq == 30 and hit.projectile_n == 0
    assert hit.source_id == 10 and hit.source_life == 11 and hit.target_id == 20 and hit.target_life == 21
    assert hit.q_j == 2094.0 and hit.position == {1.5, -2.0, 3.0}
    assert {:ok, encoded} = Codec.encode(hit)
    assert IO.iodata_to_binary(encoded) == bytes
    assert {:error, :invalid_m1_message} = Codec.decode(bytes <> <<0>>)
  end
end
