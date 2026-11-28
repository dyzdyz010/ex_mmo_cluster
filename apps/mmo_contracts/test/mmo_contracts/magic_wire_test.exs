defmodule MmoContracts.MagicWireTest do
  @moduledoc """
  只测试：魔法线格式冻结样本（Hello 46，魔法 v2 切片 3）。

  - 0x82 施法意图 v2、0x83 施法者状态 v2、PropertyBatch 施放记录 v2 的正例与反例来自
    `test/fixtures/wire-v2-samples.json`（与 Voxim 测试共读的同一份字节，布局见决策稿
    `docs/10-active/magic/2026-11-19-slice3-protocol.md` §3.1–3.3 与设计 v2.11 §11.4.6）。样本逐字段列出字节段，
    本测试先断言字节段拼接等于 `hex`，再断言解码 / 编码与 `hex` 逐字节一致。
  - 程序字节与目录 digest 取自 `voxel_region` 的 `ir-v2-samples.json`（唯一来源），这里只断言两处相同；
    0x83 报价字段与施放记录各步取自 `quote-v2-samples.json` 的 fireball。
  - v1（Hello 44）布局直接替换、不保留兼容分支（设计 §14.0 Q2）；v1 的 0x82 冻结样本作为反例留在 JSON 里。
  - 结构记录 v2（160 B）、结构状态增量（20 B）与带二者的 PropertyBatch（切片 4a，决策稿
    `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md` §3）：字段值取自 `voxel_region` 的
    `structure-v2-samples.json`（服务端产品函数产出），字节由同一独立生成器排出；反例覆盖 §13 C4-2、C4-3。
    旧 135 B 拟态记录不保留兼容解码。
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

  test "Hello 46：当前版本是 46，Hello 45 与更早版本在线边界拒绝" do
    assert Session.Codec.protocol_version() == 46
    assert @wire["protocol_version"] == 46
    hello = %Session.Hello{protocol_version: 46, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, packet} = Session.Codec.encode(hello)
    <<prefix::binary-size(9), 46::16, tail::binary>> = IO.iodata_to_binary(packet)

    assert {:ok, %Session.Hello{protocol_version: 46}} =
             Session.Codec.decode(prefix <> <<46::16>> <> tail)

    for old <- [45, 44, 43, 35, 29] do
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

  # ── 结构记录 v2、结构状态增量（切片 4a，决策稿 2026-11-26-p1-closure-slices4-8.md §3）──

  @structure_path Path.expand(
                    "../../../voxel_region/test/fixtures/magic/structure-v2-samples.json",
                    __DIR__
                  )
  @external_resource @structure_path
  @structures Jason.decode!(File.read!(@structure_path))

  defp structure_samples,
    do: Enum.filter(@wire["samples"], &String.starts_with?(&1["id"], "structure_record_v2_"))

  defp sid(key) do
    [seq, n] = key |> String.split(":") |> Enum.map(&String.to_integer/1)
    {seq, n}
  end

  # JSON 字段 → `encode_structures/1` 的记录形状。
  defp structure_fields(nil), do: nil

  defp structure_fields(f) do
    f
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Map.update!(:origin, &List.to_tuple/1)
    |> Map.update!(:velocity, &List.to_tuple/1)
    |> Map.update!(:rest, &List.to_tuple/1)
    |> Map.update!(:coupling, fn names -> Enum.map(names, &String.to_existing_atom/1) end)
    |> Map.update!(:status, fn names -> Enum.map(names, &String.to_existing_atom/1) end)
    |> Map.update!(:anchor_ref, &Base.decode16!(&1, case: :lower))
  end

  defp state_fields(f) do
    f
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Map.update!(:status, fn names -> Enum.map(names, &String.to_existing_atom/1) end)
  end

  defp delta(sample, convert),
    do: Map.new(sample["fields"], fn {key, f} -> {sid(key), convert.(f)} end)

  test "结构记录 v2 golden：8 条（live 0–6）各 160 B，字段取自产品产出的 structure-v2-samples，编解码与 hex 逐字节一致" do
    samples = structure_samples()
    assert length(samples) == 8

    assert Enum.map(@structures["records"], &"structure_record_v2_#{&1["id"]}") ==
             Enum.map(samples, & &1["id"])

    for {s, source} <- Enum.zip(samples, @structures["records"]) do
      record = bytes(s)
      assert byte_size(record) == 160, s["id"]
      # 字段值就是服务端产品函数的产出（独立生成器只负责排字节）。
      assert s["fields"] == %{Enum.join(source["sid"], ":") => source["fields"]}, s["id"]

      delta = delta(s, &structure_fields/1)
      assert Codec.encode_structures(delta) == record, s["id"]
      assert Codec.decode_structures(record) == {:ok, delta}, s["id"]
    end

    lives =
      Enum.map(samples, fn s ->
        f = s["fields"] |> Map.values() |> hd()
        f && f["live"]
      end)

    assert lives == [nil, 1, 1, 2, 3, 4, 5, 6]
    assert Codec.encode_structures(%{}) == <<>>

    # 位表与 golden 同一张（客户端按 golden 的位表解码）。
    assert Enum.map(Codec.structure_couplings(), &Atom.to_string/1) ==
             @wire["structure_coupling_bits"]

    assert Enum.map(Codec.structure_status_bits(), &Atom.to_string/1) ==
             @wire["structure_status_bits"]
  end

  test "结构记录 v2：灯为无质量静止（flags 0x02）、火球有质量飞行（flags 0x01、status 位 4），无〈热〉温度为 0" do
    lamp = bytes(sample("structure_record_v2_lamp_born"))
    flight = bytes(sample("structure_record_v2_fireball_flight"))

    # 偏移 21 shape、22 flags、23 size1、31 temperature、39 glow；135 起 size2/size3/proto/coupling（u16），
    # 143 load、144 coherence、145 status、146 failed_segments、147 anchor_type、148 anchor_ref。
    assert <<_::binary-size(21), 0, 0x02, _::binary-size(8), lamp_t::float-64, 100.0::float-64,
             _::binary-size(88), 0::16, 0::16, 0::16, 0x0002::16, 56, 255, 0, 0, 0, 0::96>> = lamp

    assert lamp_t == 0.0

    assert <<_::binary-size(21), 0, 0x01, 0.25::float-64, temperature::float-64,
             _::binary-size(96), 0::16, 0::16, 0::16, 0x0001::16, _load, 255, 0x10, 0, 0, 0::96>> =
             flight

    assert_in_delta temperature, 2000.0, 1.0e-9
  end

  test "终止事件编号：接触 2、断供 3、过载 4、驱散 5、非接触读数触发的〈散〉6；表外名字显式失败" do
    assert Enum.map(
             [:contact, :exhausted, :collapsed, :dispelled, :released],
             &Codec.structure_end_live/1
           ) == [2, 3, 4, 5, 6]

    assert_raise KeyError, fn -> Codec.structure_end_live(:expired) end
  end

  test "结构记录 v2 编码端显式失败：live 7、live 2 无 ends_on_contact、shape 3、负温度、load 越界、表外状态位名" do
    [{id, lamp}] =
      Map.to_list(delta(sample("structure_record_v2_lamp_born"), &structure_fields/1))

    for bad <- [
          %{lamp | live: 7},
          %{lamp | live: 2},
          %{lamp | shape: 3},
          %{lamp | temperature_k: -1.0},
          %{lamp | load: 256},
          %{lamp | status: [:massless]}
        ] do
      assert_raise ArgumentError, fn -> Codec.encode_structures(%{id => bad}) end
    end
  end

  test "结构状态增量 golden：2 × 20 B；温度 0.1 K、发光 W 的量化与独立生成器一致，编解码逐字节一致" do
    s = sample("structure_states_v2")
    states = bytes(s)
    assert byte_size(states) == 40
    delta = delta(s, &state_fields/1)
    assert Codec.encode_structure_states(delta) == states
    assert Codec.decode_structure_states(states) == {:ok, delta}
    assert Codec.encode_structure_states(%{}) == <<>>

    # 状态增量由完整记录投影（codec 的量化）；源字段是产品在该拍的 wire/1 产出。
    for src <- s["source_states"] do
      assert Codec.structure_state(state_fields(src["state"])) ==
               delta[List.to_tuple(src["sid"])]
    end

    # 饱和：超过 6553.5 K 与 65535 W 的值截到 65535。
    hot = %{
      load: 0,
      coherence: 0,
      status: [],
      failed_segments: 0,
      temperature_k: 9000.0,
      glow_w: 1.0e6
    }

    assert %{temperature_dk: 65_535, glow_w: 65_535} = Codec.structure_state(hot)
  end

  test "PropertyBatch golden：structures 与 structure_states 同批（增量批），帧逐字节一致；完整批只收 live 1" do
    s = sample("property_batch_structures_v2")
    frame = bytes(s)

    structures =
      s["structure_samples"]
      |> Enum.map(&bytes(sample("structure_record_v2_" <> &1)))
      |> Enum.join()

    states = bytes(sample(s["states_sample"]))
    [e, scene, epoch] = s["identity"]

    batch = %MmoContracts.Voxel.PropertyBatch{
      identity: %Session.Identity{session_epoch: e, scene_id: scene, scene_epoch: epoch},
      transaction_seq: s["transaction_seq"],
      l0_min: List.to_tuple(s["l0_min"]),
      l0_max_exclusive: List.to_tuple(s["l0_max_exclusive"]),
      complete: s["complete"],
      hp_enabled: s["hp_enabled"],
      digest: Base.decode16!(s["digest_hex"], case: :lower),
      thermal_enabled: s["thermal_enabled"],
      ambient_kelvin: s["ambient_kelvin"],
      epochs: <<>>,
      states: [],
      structures: structures,
      structure_states: states
    }

    assert {:ok, ^frame} = Codec.encode_m1(batch)
    assert {:ok, ^batch} = Codec.decode_m1(frame)

    # 完整批：只含 live 1 的结构、不带状态增量时接纳。
    live = bytes(sample("structure_record_v2_fireball_flight"))
    complete = %{batch | complete: 1, structures: live, structure_states: <<>>}
    assert {:ok, ^complete} = Codec.decode_m1(elem(Codec.encode_m1(complete), 1))
  end

  test "结构记录 / 状态增量 / PropertyBatch 反例（golden negatives）：各在对应边界显式拒绝" do
    negatives =
      Enum.filter(
        @wire["negatives"],
        &String.starts_with?(&1["id"], ["structure", "property_batch"])
      )

    assert length(negatives) == 19

    for n <- negatives do
      result =
        case n["expect"] do
          "invalid_structure" -> Codec.decode_structures(bytes(n))
          "invalid_structure_state" -> Codec.decode_structure_states(bytes(n))
          "invalid_m1_message" -> Codec.decode_m1(bytes(n))
        end

      assert result == {:error, String.to_existing_atom(n["expect"])}, n["id"]
    end
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

    # 帧尾：区域段、结构段各 0 长度，随后施放段 u32 长度与样本，最后是 0 长度的结构状态增量段。
    assert binary_part(frame, byte_size(frame) - size - 16, size + 16) ==
             <<0::32, 0::32, size::32>> <> casts <> <<0::32>>

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
