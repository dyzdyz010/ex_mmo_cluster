defmodule MmoContracts.MagicWireTest do
  @moduledoc """
  只测试：魔法线格式冻结样本（Hello 45，魔法 v2 切片 3）。

  - 0x82 施法意图 v2、0x83 施法者状态 v2、PropertyBatch 施放记录 v2 的正例与反例来自
    `test/fixtures/wire-v2-samples.json`（与 Voxim 测试共读的同一份字节，布局见决策稿
    `docs/10-active/magic/2026-11-19-slice3-protocol.md` §3.1–3.3 与设计 v2.11 §11.4.6）。样本逐字段列出字节段，
    本测试先断言字节段拼接等于 `hex`，再断言解码 / 编码与 `hex` 逐字节一致。
  - 程序字节与目录 digest 取自 `voxel_region` 的 `ir-v2-samples.json`（唯一来源），这里只断言两处相同；
    0x83 报价字段与施放记录各步取自 `quote-v2-samples.json` 的 fireball。
  - v1（Hello 44）布局直接替换、不保留兼容分支（设计 §14.0 Q2）；v1 的 0x82 冻结样本作为反例留在 JSON 里。
  - 拟态记录（135 B）属结构记录 v2 的范围（切片 4），本片不改，样本仍是逐字段手写。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias MmoContracts.Session
  alias MmoContracts.Voxel.Codec
  require Codec

  @wire_path Path.expand("../fixtures/wire-v2-samples.json", __DIR__)
  @ir_path Path.expand("../../../voxel_region/test/fixtures/magic/ir-v2-samples.json", __DIR__)
  @external_resource @wire_path
  @external_resource @ir_path
  @wire Jason.decode!(File.read!(@wire_path))
  @ir Jason.decode!(File.read!(@ir_path))

  defp sample(id), do: Enum.find(@wire["samples"] ++ @wire["negatives"], &(&1["id"] == id))
  defp bytes(%{"hex" => hex}), do: Base.decode16!(hex, case: :lower)

  defp ir_program(id),
    do:
      Enum.find(@ir["samples"], &(&1["id"] == id))["program_hex"] |> Base.decode16!(case: :lower)

  test "Hello 45：当前版本是 45，Hello 44 与更早版本在线边界拒绝" do
    assert Session.Codec.protocol_version() == 45
    assert @wire["protocol_version"] == 45
    hello = %Session.Hello{protocol_version: 45, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, packet} = Session.Codec.encode(hello)
    <<prefix::binary-size(9), 45::16, tail::binary>> = IO.iodata_to_binary(packet)

    assert {:ok, %Session.Hello{protocol_version: 45}} =
             Session.Codec.decode(prefix <> <<45::16>> <> tail)

    for old <- [44, 43, 35, 29] do
      assert {:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<old::16>> <> tail)
    end
  end

  test "golden 样本：字节段偏移连续、拼接等于 hex、总长与声明一致；程序与 digest 同 ir-v2-samples" do
    for s <- @wire["samples"] do
      {total, hex} =
        Enum.reduce(s["segments"], {0, ""}, fn seg, {offset, acc} ->
          assert seg["offset"] == offset, "#{s["id"]} #{seg["field"]}"
          {offset + div(byte_size(seg["hex"]), 2), acc <> seg["hex"]}
        end)

      assert hex == s["hex"], s["id"]
      assert total == s["total_bytes"], s["id"]
    end

    assert @wire["catalog_digest"] == @ir["catalog_digest"]

    assert sample("spell_intent_fireball_quote")["fields"]["catalog_digest"] ==
             @ir["catalog_digest"]

    for id <- ["spell_intent_fireball_quote", "casts_fireball"],
        do: assert(sample(id)["program_sample"] == "fireball")

    assert Enum.map(Codec.spell_reject_checks(), &Atom.to_string/1) == @wire["rejects_bits"]
  end

  # 拟态记录（每条 135 B，大端，按 id 升序）：删除 {5, 2}；存在 {9, 0}——施法者 1001、球、半径 0.4 m、2000 K、
  # 无发光、出发点 (0.5, 2.5, 1.0)、速度 (0, 0, 12)、t0 = 1.7e15 µs、飞行 1/6 s、落点 (0.5, 2.36375, 2.6)。
  @semblances Base.decode16!(
                "0000000000000005" <>
                  "00000002" <>
                  "00" <>
                  String.duplicate("00", 122) <>
                  "0000000000000009" <>
                  "00000000" <>
                  "01" <>
                  "00000000000003E9" <>
                  "00" <>
                  "01" <>
                  "3FD999999999999A" <>
                  "409F400000000000" <>
                  "0000000000000000" <>
                  "3FE0000000000000" <>
                  "4004000000000000" <>
                  "3FF0000000000000" <>
                  "0000000000000000" <>
                  "0000000000000000" <>
                  "4028000000000000" <>
                  "00060A24181E4000" <>
                  "3FC5555555555555" <>
                  "3FE0000000000000" <> "4002E8F5C28F5C29" <> "4004CCCCCCCCCCCD"
              )

  @delta %{
    {5, 2} => nil,
    {9, 0} => %{
      caster: 1001,
      shape: 0,
      break_on_hit: true,
      no_gravity: false,
      radius_m: 0.4,
      temperature_k: 2000.0,
      glow_w: 0.0,
      origin: {0.5, 2.5, 1.0},
      velocity: {0.0, 0.0, 12.0},
      t0_us: 1_700_000_000_000_000,
      flight_s: 1 / 6,
      rest: {0.5, 2.36375, 2.6}
    }
  }

  test "拟态记录逐字节等于手写样本；World 内部字段不上线；属性批次末尾携带，完整批次不能含删除" do
    assert byte_size(@semblances) == 2 * 135

    internal =
      Map.new(@delta, fn {id, s} ->
        {id, s && Map.merge(s, %{mass_kg: 2.0, age_s: 0.3, contact: nil})}
      end)

    assert Codec.encode_semblances(internal) == @semblances
    assert Codec.decode_semblances(@semblances) == {:ok, @delta}
    assert Codec.encode_semblances(%{}) == <<>>

    # Persisted pre-flag records (missing break_on_hit / no_gravity) encode flags = 0 at offset 22.
    old = @delta[{9, 0}] |> Map.delete(:break_on_hit) |> Map.delete(:no_gravity)
    expected_old = @semblances |> binary_part(135, 135) |> put(22, 0)
    assert Codec.encode_semblances(%{{9, 0} => old}) == expected_old

    assert {:ok, %{{9, 0} => %{break_on_hit: false, no_gravity: false}}} =
             Codec.decode_semblances(expected_old)

    # Hello 45: byte 22 is bitflags (bit 0 = break_on_hit, bit 1 = no_gravity), valid values 0..3.
    live = binary_part(@semblances, 135, 135)

    for {flags, break_on_hit, no_gravity} <- [
          {0, false, false},
          {1, true, false},
          {2, false, true},
          {3, true, true}
        ] do
      record = %{@delta[{9, 0}] | break_on_hit: break_on_hit, no_gravity: no_gravity}
      expected = put(live, 22, flags)
      assert Codec.encode_semblances(%{{9, 0} => record}) == expected
      assert Codec.decode_semblances(expected) == {:ok, %{{9, 0} => record}}
    end

    batch = fn complete, semblances ->
      %MmoContracts.Voxel.PropertyBatch{
        identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
        transaction_seq: 7,
        l0_min: {0, 0, 0},
        l0_max_exclusive: {1, 1, 1},
        complete: complete,
        hp_enabled: 1,
        digest: :binary.copy(<<0xA5>>, 32),
        thermal_enabled: 1,
        ambient_kelvin: 293.15,
        epochs: <<>>,
        states: [],
        semblances: semblances
      }
    end

    {:ok, frame} = Codec.encode_m1(batch.(0, @semblances))

    # 帧尾：区域段 0 长度，随后拟态段 u32 长度 270 与样本，最后是空施放段（协议 27）。
    assert binary_part(frame, byte_size(frame) - 282, 282) ==
             <<0::32, 270::32>> <> @semblances <> <<0::32>>

    assert {:ok, %{semblances: @semblances}} = Codec.decode_m1(frame)

    assert {:ok, %{semblances: ^live}} =
             Codec.decode_m1(elem(Codec.encode_m1(batch.(1, live)), 1))

    assert {:error, :invalid_m1_message} =
             Codec.decode_m1(elem(Codec.encode_m1(batch.(1, @semblances)), 1))

    # A collision end is a full independently frozen record with kind=2 at byte12;
    # it survives coalescing over create and needs no preceding live record.
    impact = Map.put(@delta[{9, 0}], :live, 2)
    ended = put(live, 12, 2)
    assert Codec.encode_semblances(%{{9, 0} => impact}) == ended
    assert Codec.decode_semblances(ended) == {:ok, %{{9, 0} => impact}}

    # Hello 45: live=2 with flags=3 (break_on_hit + no_gravity) is valid; live=2 with flags=2 (no break_on_hit) is rejected.
    straight_impact = %{impact | no_gravity: true}
    straight_ended = put(ended, 22, 3)
    assert Codec.encode_semblances(%{{9, 0} => straight_impact}) == straight_ended
    assert Codec.decode_semblances(straight_ended) == {:ok, %{{9, 0} => straight_impact}}

    assert {:ok, %{semblances: ^ended}} =
             Codec.decode_m1(elem(Codec.encode_m1(batch.(0, ended)), 1))

    assert {:error, :invalid_m1_message} =
             Codec.decode_m1(elem(Codec.encode_m1(batch.(1, ended)), 1))

    assert {:error, :invalid_semblance} = Codec.decode_semblances(put(ended, 22, 0))
    assert {:error, :invalid_semblance} = Codec.decode_semblances(put(ended, 22, 2))

    # 反例：乱序、重复、未知形状、未定义 flags 位（>= 4）、删除记录带非零字段、截断。
    <<gone::binary-size(135), kept::binary-size(135)>> = @semblances

    for bad <- [
          kept <> gone,
          kept <> kept,
          put(kept, 21, 2),
          put(kept, 22, 4),
          put(kept, 22, 255),
          put(gone, 40, 1),
          binary_part(@semblances, 0, 200)
        ],
        do: assert({:error, :invalid_semblance} == Codec.decode_semblances(bad), inspect(bad))
  end

  # ── 0x82 v2 ──

  defp spell_fields(f) do
    %{
      request_id: f["request_id"],
      client_intent_seq: f["client_intent_seq"],
      logical_scene_id: f["logical_scene_id"],
      action: f["action"],
      catalog_digest: Base.decode16!(f["catalog_digest"], case: :lower),
      direction: List.to_tuple(f["direction"]),
      micro: List.to_tuple(f["micro"]),
      incarnation: f["incarnation"],
      owner: List.to_tuple(f["owner"]),
      material: f["material"],
      granularity: f["granularity"],
      program: Base.decode16!(f["program_hex"], case: :lower)
    }
  end

  test "0x82 v2 golden（127 + n B，无拟态 id）解码为施法意图；程序是 IR v2 火球" do
    s = sample("spell_intent_fireball_quote")
    spell = bytes(s)
    program = ir_program("fireball")
    assert byte_size(spell) == 127 + byte_size(program)
    assert <<_::binary-size(125), n::16, ^program::binary>> = spell
    assert n == byte_size(program)
    assert Codec.is_opcode(0x82)

    assert {:ok, {:voxel_spell_intent, request}} = Codec.decode(spell)
    assert request == spell_fields(s["fields"])
    refute Map.has_key?(request, :semblance)
    assert Codec.intent?({:voxel_spell_intent, request})
  end

  test "0x82 v2 反例：program_len 与剩余字节不符、v1 布局、非法 action / granularity / 方向" do
    for id <- [
          "spell_intent_program_len_overrun",
          "spell_intent_program_len_underrun",
          "spell_intent_v1_layout"
        ] do
      s = sample(id)
      assert s["expect"] == "invalid_message"
      assert {:error, :invalid_message} = Codec.decode(bytes(s)), id
    end

    spell = bytes(sample("spell_intent_fireball_quote"))

    # action 在偏移 21：0..3 合法，4 拒绝；granularity 在偏移 124：3 拒绝。
    for action <- [1, 2, 3] do
      assert {:ok, {:voxel_spell_intent, %{action: ^action}}} =
               Codec.decode(put(spell, 21, action))
    end

    assert {:error, :invalid_message} = Codec.decode(put(spell, 21, 4))
    assert {:error, :invalid_message} = Codec.decode(put(spell, 124, 3))

    # 方向 z 分量（偏移 70）改为 0.5：非单位向量。
    assert {:error, :invalid_message} =
             Codec.decode(
               binary_part(spell, 0, 70) <>
                 <<0.5::float-64>> <> binary_part(spell, 78, byte_size(spell) - 78)
             )

    # 截断在程序长度字段中间。
    assert {:error, :invalid_message} = Codec.decode(binary_part(spell, 0, 126))
  end

  # ── 0x83 v2 ──

  defp caster_fields(f) do
    f
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Map.update!(:rejects, fn names -> Enum.map(names, &String.to_existing_atom/1) end)
  end

  test "0x83 v2 golden（161 B）：报价回复按火球报价编码，逐字节等于样本" do
    s = sample("caster_state_fireball_quote")
    state = caster_fields(s["fields"])
    expected = bytes(s)

    assert byte_size(expected) == 161
    assert Codec.is_message({:voxel_caster_state, state})
    assert {:ok, encoded} = Codec.encode({:voxel_caster_state, state})
    assert IO.iodata_to_binary(encoded) == expected

    # 偏移 33 = Ω_eff，49 = S·P，57 = spent_j，121 = fail_step，129 = rejects（以 f64 承载整数值）。
    assert <<_::binary-size(33), omega::float-64, _::binary-size(8), sp::float-64,
             spent::float-64, _::binary-size(56), fail_step::float-64, rejects::float-64,
             _::binary>> = expected

    assert {omega, sp, spent, fail_step, rejects} == {16.0, 4.0, 0.0, 2.0, 0.0}
  end

  test "rejects 位序：0x83 位掩码与 0x68 原因串同一张表；表外名字与空原因串显式失败" do
    state = caster_fields(sample("caster_state_fireball_quote")["fields"])

    rejects_at = fn checks ->
      {:ok, bytes} = Codec.encode({:voxel_caster_state, %{state | rejects: checks}})
      <<_::binary-size(129), mask::float-64, _::binary>> = IO.iodata_to_binary(bytes)
      mask
    end

    assert rejects_at.([:capacity]) == 1.0
    assert rejects_at.([:domain]) == 2.0
    assert rejects_at.([:first_tick]) == 4.0
    assert rejects_at.([:ambient_floor]) == 8.0
    assert rejects_at.([:thermal_step]) == 16.0
    assert rejects_at.([:thermal_step, :first_tick]) == 20.0

    assert Codec.spell_rejects_reason([:domain]) == "rejects:domain"

    assert Codec.spell_rejects_reason([:thermal_step, :first_tick]) ==
             "rejects:first_tick,thermal_step"

    assert_raise ArgumentError, fn -> Codec.spell_rejects_mask([:out_of_domain]) end
    assert_raise ArgumentError, fn -> Codec.spell_rejects_reason([]) end
  end

  # ── 施放记录 v2 ──

  defp cast_fields(fields) do
    Map.new(fields, fn {caster, record} ->
      record =
        case record do
          %{"live" => 0} ->
            %{live: 0, outcome: record["outcome"], fail_step: record["fail_step"]}

          %{"live" => 1} ->
            %{
              live: 1,
              t0_us: record["t0_us"],
              origin: List.to_tuple(record["origin"]),
              steps:
                for(
                  st <- record["steps"],
                  do: %{
                    part_index: st["part_index"],
                    adjust_s: st["adjust_s"] * 1.0,
                    inject_s: st["inject_s"] * 1.0
                  }
                ),
              program: Base.decode16!(record["program_hex"], case: :lower)
            }
        end

      {String.to_integer(caster), record}
    end)
  end

  test "施放记录 v2 golden：已结算（第 2 步中断）46 B + 火球前摇 46 + 7 × 17 + n B，编解码逐字节一致" do
    s = sample("casts_fireball")
    casts = bytes(s)
    delta = cast_fields(s["fields"])
    program = ir_program("fireball")

    assert delta[1002].program == program
    assert byte_size(casts) == 46 + 46 + 7 * 17 + byte_size(program)
    assert Codec.encode_casts(delta) == casts
    assert Codec.decode_casts(casts) == {:ok, delta}
    assert Codec.encode_casts(%{}) == <<>>

    # 编码端只取每步的 part_index、adjust_s、inject_s：World 可以直接传报价的 steps（带 symbol、spent_mj 等）。
    quote_steps = Enum.map(delta[1002].steps, &Map.merge(&1, %{symbol: "x", spent_mj: 1}))
    assert Codec.encode_casts(%{delta | 1002 => %{delta[1002] | steps: quote_steps}}) == casts

    # 构造顺序可以与字节序不同（设计 §3.5）：part_index 是排列即合法。P1 预设目前都按字节序构造，
    # 这条只证明线契约不要求递增。
    reordered = %{delta[1002] | steps: Enum.reverse(delta[1002].steps)}

    assert {:ok, %{1002 => ^reordered}} =
             Codec.decode_casts(Codec.encode_casts(%{1002 => reordered}))
  end

  test "施放记录 v2 随 PropertyBatch 末尾携带；完整批次不能含已结算记录" do
    casts = bytes(sample("casts_fireball"))
    <<settled::binary-size(46), pending::binary>> = casts

    batch = fn complete, casts ->
      %MmoContracts.Voxel.PropertyBatch{
        identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
        transaction_seq: 7,
        l0_min: {0, 0, 0},
        l0_max_exclusive: {1, 1, 1},
        complete: complete,
        hp_enabled: 1,
        digest: :binary.copy(<<0xA5>>, 32),
        thermal_enabled: 1,
        ambient_kelvin: 293.15,
        epochs: <<>>,
        states: [],
        casts: casts
      }
    end

    {:ok, frame} = Codec.encode_m1(batch.(0, casts))
    size = byte_size(casts)
    # 帧尾：区域段、拟态段各 0 长度，随后施放段 u32 长度与样本。
    assert binary_part(frame, byte_size(frame) - size - 12, size + 12) ==
             <<0::32, 0::32, size::32>> <> casts

    assert {:ok, %{casts: ^casts}} = Codec.decode_m1(frame)

    assert {:ok, %{casts: ^pending}} =
             Codec.decode_m1(elem(Codec.encode_m1(batch.(1, pending)), 1))

    for not_live <- [casts, settled] do
      assert {:error, :invalid_m1_message} =
               Codec.decode_m1(elem(Codec.encode_m1(batch.(1, not_live)), 1))
    end
  end

  test "施放记录 v2 反例：part_index 非排列（解码拒绝、编码显式失败）、fail_step 与 outcome 不符、截断与乱序" do
    bad = sample("casts_part_index_not_permutation")
    assert bad["expect"] == "invalid_cast"
    assert {:error, :invalid_cast} = Codec.decode_casts(bytes(bad))
    assert_raise ArgumentError, fn -> Codec.encode_casts(cast_fields(bad["fields"])) end

    casts = bytes(sample("casts_fireball"))
    <<settled::binary-size(46), pending::binary>> = casts

    # 记录内偏移 9 = outcome，10 = fail_step。outcome 1 必须带步号，0 / 2 必须不带；outcome 3 未定义。
    for {outcome, fail_step} <- [{1, 0}, {0, 1}, {2, 3}, {3, 0}] do
      record = settled |> put(9, outcome) |> put(10, fail_step)
      assert {:error, :invalid_cast} = Codec.decode_casts(record), inspect({outcome, fail_step})

      assert_raise ArgumentError, fn ->
        Codec.encode_casts(%{1001 => %{live: 0, outcome: outcome, fail_step: fail_step}})
      end
    end

    for outcome <- [0, 2] do
      record = settled |> put(9, outcome) |> put(10, 0)

      assert Codec.decode_casts(record) ==
               {:ok, %{1001 => %{live: 0, outcome: outcome, fail_step: 0}}}
    end

    # 前摇中记录的步数（偏移 43）改为 0，并去掉 7 步。
    tail_at = 44 + 7 * 17

    no_steps =
      binary_part(pending, 0, 43) <>
        <<0>> <> binary_part(pending, tail_at, byte_size(pending) - tail_at)

    for invalid <- [
          put(pending, 9, 1),
          put(pending, 10, 1),
          put(pending, 8, 2),
          no_steps,
          # 第 1 步调整时长（偏移 45，紧跟 part_index）的符号位置 1。
          put(pending, 45, 0xBF),
          pending <> settled,
          pending <> pending,
          binary_part(pending, 0, byte_size(pending) - 1),
          pending <> <<0>>
        ],
        do: assert({:error, :invalid_cast} == Codec.decode_casts(invalid), inspect(invalid))
  end

  defp put(bytes, at, value),
    do:
      binary_part(bytes, 0, at) <>
        <<value>> <> binary_part(bytes, at + 1, byte_size(bytes) - at - 1)
end
