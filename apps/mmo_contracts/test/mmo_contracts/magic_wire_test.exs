defmodule MmoContracts.MagicWireTest do
  @moduledoc """
  只测试：魔法增量 1（Hello 24）线格式冻结样本。0x82 施法意图（上行，大端，目标表示同 0x7D）与
  0x83 施法者状态（下行，大端）；样本字节逐字段手写，f64 取 IEEE 754 大端位型。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.Session
  alias MmoContracts.Voxel.Codec
  require Codec

  @digest :binary.copy(<<0x11>>, 32)

  # 0x82：rid 1、seq 2、scene 3、action 1、digest 0x11×32、方向 (0, −1, 0)、目标微格 (−8, 16, 24)、
  # incarnation 5、owner {0, 0}、material 28、granularity 0、程序 2 字节 "{}"。
  @spell Base.decode16!(
           "82" <> "0000000000000001" <> "00000002" <> "0000000000000003" <> "01" <>
             String.duplicate("11", 32) <>
             "0000000000000000" <> "BFF0000000000000" <> "0000000000000000" <>
             "FFFFFFFFFFFFFFF8" <> "0000000000000010" <> "0000000000000018" <>
             "0000000000000005" <> "0000000000000000" <> "00000000" <> "001C" <> "00" <>
             "0002" <> "7B7D"
         )

  test "Hello 24" do
    assert Session.Codec.protocol_version() == 24
    hello = %Session.Hello{protocol_version: 24, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, packet} = Session.Codec.encode(hello)
    <<_prefix::binary-size(9), 24::16, _tail::binary>> = IO.iodata_to_binary(packet)
  end

  test "0x82 冻结样本解码为施法意图；非法动作、粒度、方向与长度拒绝" do
    assert byte_size(@spell) == 1 + 8 + 4 + 8 + 1 + 32 + 24 + 24 + 8 + 12 + 2 + 1 + 2 + 2
    assert Codec.is_opcode(0x82)

    assert {:ok,
            {:voxel_spell_intent,
             %{
               request_id: 1,
               client_intent_seq: 2,
               logical_scene_id: 3,
               action: 1,
               catalog_digest: @digest,
               direction: {+0.0, -1.0, +0.0},
               micro: {-8, 16, 24},
               incarnation: 5,
               owner: {0, 0},
               material: 28,
               granularity: 0,
               program: "{}"
             }}} = Codec.decode(@spell)

    # action 在下标 21；granularity 在程序长度之前（下标 size − 5）。
    assert {:error, :invalid_message} = Codec.decode(put(@spell, 21, 2))
    assert {:error, :invalid_message} = Codec.decode(put(@spell, byte_size(@spell) - 5, 3))
    # dy 改为 −0.5：非单位方向。
    assert {:error, :invalid_message} =
             Codec.decode(binary_part(@spell, 0, 62) <> <<-0.5::float-64>> <> binary_part(@spell, 70, byte_size(@spell) - 70))
    # 声明 3 字节程序但只有 2 字节；多一个尾字节。
    assert {:error, :invalid_message} = Codec.decode(put(@spell, byte_size(@spell) - 3, 3))
    assert {:error, :invalid_message} = Codec.decode(@spell <> <<0>>)
  end

  test "0x83 施法者状态编码为冻结字节" do
    state = %{request_id: 9, seq: 10, energy_j: 898_000.0, capacity_j: 5.0e6, coherence: 4.0,
      quote_j: 2000.0, quote_s: 1.0, spent_j: 2000.0}

    expected =
      Base.decode16!(
        "83" <> "0000000000000009" <> "000000000000000A" <> "412B67A000000000" <> "415312D000000000" <>
          "4010000000000000" <> "409F400000000000" <> "3FF0000000000000" <> "409F400000000000"
      )

    assert Codec.is_message({:voxel_caster_state, state})
    assert {:ok, bytes} = Codec.encode({:voxel_caster_state, state})
    assert IO.iodata_to_binary(bytes) == expected
    assert byte_size(expected) == 1 + 8 + 8 + 6 * 8
  end

  defp put(bytes, at, value),
    do: binary_part(bytes, 0, at) <> <<value>> <> binary_part(bytes, at + 1, byte_size(bytes) - at - 1)
end
