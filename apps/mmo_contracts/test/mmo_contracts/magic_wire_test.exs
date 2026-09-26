defmodule MmoContracts.MagicWireTest do
  @moduledoc """
  只测试：魔法线格式冻结样本（增量 1 起、Hello 28 现行）。0x82 施法意图（上行，大端，目标表示同 0x7D，
  增量 2 在粒度后加目标拟态 id）、0x83 施法者状态（下行，大端）与增量 2 PropertyBatch 末尾的拟态记录；
  样本字节逐字段手写，f64 取 IEEE 754 大端位型。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.Session
  alias MmoContracts.Voxel.Codec
  require Codec

  @digest :binary.copy(<<0x11>>, 32)

  # 0x82：rid 1、seq 2、scene 3、action 1、digest 0x11×32、方向 (0, −1, 0)、目标微格 (−8, 16, 24)、
  # incarnation 5、owner {0, 0}、material 28、granularity 0、目标拟态 {7, 1}、程序 2 字节 "{}"。
  @spell Base.decode16!(
           "82" <> "0000000000000001" <> "00000002" <> "0000000000000003" <> "01" <>
             String.duplicate("11", 32) <>
             "0000000000000000" <> "BFF0000000000000" <> "0000000000000000" <>
             "FFFFFFFFFFFFFFF8" <> "0000000000000010" <> "0000000000000018" <>
             "0000000000000005" <> "0000000000000000" <> "00000000" <> "001C" <> "00" <>
             "0000000000000007" <> "00000001" <> "0002" <> "7B7D"
         )

  test "Hello 31：Hello 29 在线边界拒绝" do
    assert Session.Codec.protocol_version() == 31
    hello = %Session.Hello{protocol_version: 31, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, packet} = Session.Codec.encode(hello)
    <<prefix::binary-size(9), 31::16, tail::binary>> = IO.iodata_to_binary(packet)
    assert {:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<29::16>> <> tail)
  end

  test "0x82 冻结样本解码为施法意图；非法动作、粒度、方向与长度拒绝" do
    assert byte_size(@spell) == 1 + 8 + 4 + 8 + 1 + 32 + 24 + 24 + 8 + 12 + 2 + 1 + 12 + 2 + 2
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
               semblance: {7, 1},
               program: "{}"
             }}} = Codec.decode(@spell)

    # action 在下标 21；granularity 在目标拟态 id 与程序长度之前（下标 size − 17）。
    assert {:error, :invalid_message} = Codec.decode(put(@spell, 21, 2))
    assert {:error, :invalid_message} = Codec.decode(put(@spell, byte_size(@spell) - 17, 3))
    # dy 改为 −0.5：非单位方向。
    assert {:error, :invalid_message} =
             Codec.decode(binary_part(@spell, 0, 62) <> <<-0.5::float-64>> <> binary_part(@spell, 70, byte_size(@spell) - 70))
    # 声明 3 字节程序但只有 2 字节；多一个尾字节。
    assert {:error, :invalid_message} = Codec.decode(put(@spell, byte_size(@spell) - 3, 3))
    assert {:error, :invalid_message} = Codec.decode(@spell <> <<0>>)
  end

  # Hello 28：末尾追加报价前摇 quote_windup_s（f64，这里 1.5 s = 3FF8000000000000），其余字段位置不变。
  test "0x83 施法者状态编码为冻结字节" do
    state = %{request_id: 9, seq: 10, energy_j: 898_000.0, capacity_j: 5.0e6, coherence: 4.0,
      quote_j: 2000.0, quote_s: 1.0, spent_j: 2000.0, quote_windup_s: 1.5}

    expected =
      Base.decode16!(
        "83" <> "0000000000000009" <> "000000000000000A" <> "412B67A000000000" <> "415312D000000000" <>
          "4010000000000000" <> "409F400000000000" <> "3FF0000000000000" <> "409F400000000000" <>
          "3FF8000000000000"
      )

    assert Codec.is_message({:voxel_caster_state, state})
    assert {:ok, bytes} = Codec.encode({:voxel_caster_state, state})
    assert IO.iodata_to_binary(bytes) == expected
    assert byte_size(expected) == 1 + 8 + 8 + 7 * 8
  end

  # 拟态记录（每条 134 B，大端，按 id 升序）：删除 {5, 2}；存在 {9, 0}——施法者 1001、球、半径 0.4 m、2000 K、
  # 无发光、出发点 (0.5, 2.5, 1.0)、速度 (0, 0, 12)、t0 = 1.7e15 µs、飞行 1/6 s、落点 (0.5, 2.36375, 2.6)。
  @semblances Base.decode16!(
                "0000000000000005" <> "00000002" <> "00" <> String.duplicate("00", 121) <>
                  "0000000000000009" <> "00000000" <> "01" <> "00000000000003E9" <> "00" <>
                  "3FD999999999999A" <> "409F400000000000" <> "0000000000000000" <>
                  "3FE0000000000000" <> "4004000000000000" <> "3FF0000000000000" <>
                  "0000000000000000" <> "0000000000000000" <> "4028000000000000" <>
                  "00060A24181E4000" <> "3FC5555555555555" <>
                  "3FE0000000000000" <> "4002E8F5C28F5C29" <> "4004CCCCCCCCCCCD"
              )

  @delta %{
    {5, 2} => nil,
    {9, 0} => %{caster: 1001, shape: 0, radius_m: 0.4, temperature_k: 2000.0, glow_w: 0.0, origin: {0.5, 2.5, 1.0},
      velocity: {0.0, 0.0, 12.0}, t0_us: 1_700_000_000_000_000, flight_s: 1 / 6, rest: {0.5, 2.36375, 2.6}}
  }

  test "拟态记录逐字节等于手写样本；World 内部字段不上线；属性批次末尾携带，完整批次不能含删除" do
    assert byte_size(@semblances) == 2 * 134
    internal = Map.new(@delta, fn {id, s} -> {id, s && Map.merge(s, %{mass_kg: 2.0, age_s: 0.3, contact: nil})} end)
    assert Codec.encode_semblances(internal) == @semblances
    assert Codec.decode_semblances(@semblances) == {:ok, @delta}
    assert Codec.encode_semblances(%{}) == <<>>

    batch = fn complete, semblances ->
      %MmoContracts.Voxel.PropertyBatch{identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
        transaction_seq: 7, l0_min: {0, 0, 0}, l0_max_exclusive: {1, 1, 1}, complete: complete, hp_enabled: 1,
        digest: :binary.copy(<<0xA5>>, 32), thermal_enabled: 1, ambient_kelvin: 293.15, epochs: <<>>, states: [],
        semblances: semblances}
    end

    {:ok, frame} = Codec.encode_m1(batch.(0, @semblances))
    # 帧尾：区域段 0 长度，随后拟态段 u32 长度 268 与样本，最后是空施放段（协议 27）。
    assert binary_part(frame, byte_size(frame) - 280, 280) == <<0::32, 268::32>> <> @semblances <> <<0::32>>
    assert {:ok, %{semblances: @semblances}} = Codec.decode_m1(frame)
    live = binary_part(@semblances, 134, 134)
    assert {:ok, %{semblances: ^live}} = Codec.decode_m1(elem(Codec.encode_m1(batch.(1, live)), 1))
    assert {:error, :invalid_m1_message} = Codec.decode_m1(elem(Codec.encode_m1(batch.(1, @semblances)), 1))

    # 反例：乱序、重复、未知形状、删除记录带非零字段、截断。
    <<gone::binary-size(134), kept::binary-size(134)>> = @semblances
    for bad <- [kept <> gone, kept <> kept, put(kept, 21, 2), put(gone, 40, 1), binary_part(@semblances, 0, 200)],
      do: assert({:error, :invalid_semblance} == Codec.decode_semblances(bad), inspect(bad))
  end

  # 施放记录（协议 27，大端，按施法者升序，变长）。与 Voxim 客户端 `Voxim.Magic.CastWire` 同一份手写样本：
  # 施法者 1001 已结算、走火（outcome 1），其余字段全 0（45 B）；施法者 1002 前摇中——t0 = 1.7e15 µs、
  # 出发点 (0.5, 2.5, 1.0)、2 步 (调整 0.5 s, 注能 1.5 s)、(0.25 s, 0.25 s)、程序 2 字节 "{}"（79 B）。
  @settled Base.decode16!(
             "00000000000003E9" <> "00" <> "01" <> "0000000000000000" <>
               "0000000000000000" <> "0000000000000000" <> "0000000000000000" <> "00" <> "0000"
           )
  @pending Base.decode16!(
             "00000000000003EA" <> "01" <> "00" <> "00060A24181E4000" <>
               "3FE0000000000000" <> "4004000000000000" <> "3FF0000000000000" <> "02" <>
               "3FE0000000000000" <> "3FF8000000000000" <> "3FD0000000000000" <> "3FD0000000000000" <>
               "0002" <> "7B7D"
           )
  @casts @settled <> @pending

  @cast_delta %{
    1001 => %{live: 0, outcome: 1},
    1002 => %{live: 1, t0_us: 1_700_000_000_000_000, origin: {0.5, 2.5, 1.0}, steps: [{0.5, 1.5}, {0.25, 0.25}],
      program: "{}"}
  }

  test "施放记录逐字节等于手写样本（与客户端同一份）；属性批次在拟态段之后携带；完整批次不能含已结算记录；非法记录拒绝" do
    assert {byte_size(@settled), byte_size(@pending)} == {45, 79}
    assert Codec.encode_casts(@cast_delta) == @casts
    assert Codec.decode_casts(@casts) == {:ok, @cast_delta}
    assert Codec.encode_casts(%{}) == <<>>
    # 已结算记录只取 caster、live、outcome：带着其余字段也按结算解码（编码端总写 0）。
    with_fields = binary_part(@settled, 0, 9) <> <<2>> <> binary_part(@pending, 10, 69)
    assert Codec.decode_casts(with_fields) == {:ok, %{1001 => %{live: 0, outcome: 2}}}

    batch = fn complete, casts ->
      %MmoContracts.Voxel.PropertyBatch{identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
        transaction_seq: 7, l0_min: {0, 0, 0}, l0_max_exclusive: {1, 1, 1}, complete: complete, hp_enabled: 1,
        digest: :binary.copy(<<0xA5>>, 32), thermal_enabled: 1, ambient_kelvin: 293.15, epochs: <<>>, states: [],
        casts: casts}
    end

    {:ok, frame} = Codec.encode_m1(batch.(0, @casts))
    # 帧尾：区域段、拟态段各 0 长度，随后施放段 u32 长度 124 与样本。
    assert binary_part(frame, byte_size(frame) - 136, 136) == <<0::32, 0::32, 124::32>> <> @casts
    assert {:ok, %{casts: @casts}} = Codec.decode_m1(frame)
    assert {:ok, %{casts: @pending}} = Codec.decode_m1(elem(Codec.encode_m1(batch.(1, @pending)), 1))
    assert {:error, :invalid_m1_message} = Codec.decode_m1(elem(Codec.encode_m1(batch.(1, @casts)), 1))
    # 空施放段：批次末尾 00000000。
    {:ok, empty} = Codec.encode_m1(batch.(1, <<>>))
    assert binary_part(empty, byte_size(empty) - 12, 12) == <<0::96>>

    # 反例：乱序、重复、未知 live、outcome 3、前摇中 outcome 非 0、前摇中 0 步、前摇中空程序、负时长、截断、尾随字节。
    no_steps = binary_part(@pending, 0, 42) <> <<0, 0, 2>> <> "{}"
    no_program = binary_part(@pending, 0, 75) <> <<0, 0>>
    for bad <- [@pending <> @settled, @pending <> @pending, put(@pending, 8, 2), put(@settled, 9, 3), put(@pending, 9, 1),
                no_steps, no_program, put(@pending, 43, 0xBF), binary_part(@pending, 0, 78), @pending <> <<0>>],
      do: assert({:error, :invalid_cast} == Codec.decode_casts(bad), inspect(bad))
  end

  defp put(bytes, at, value),
    do: binary_part(bytes, 0, at) <> <<value>> <> binary_part(bytes, at + 1, byte_size(bytes) - at - 1)
end
