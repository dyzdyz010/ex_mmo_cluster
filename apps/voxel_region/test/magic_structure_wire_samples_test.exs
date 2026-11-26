defmodule VoxelRegion.MagicStructureWireSamplesTest do
  @moduledoc """
  只测试：结构记录 v2 与状态增量的字段样本 `fixtures/magic/structure-v2-samples.json` 与当前实现不漂移（魔法 v2 切片 4a，
  决策稿 `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md` §3、§9、§13 C4-1–C4-3）。

  - 契约：样本里每条记录的动态字段（装载、相干、状态、失效段、温度、发光）都等于对同一结构调用 `Structure.wire/1`
    的结果；结构由冻结程序 `fixtures/magic/ir-v2-samples.json` 经真实 `Program.decode_ir/2`、`Cost.quote_structure/3`、
    `Structure.new/4`（终止样本再经 `Structure.step/4`、`Structure.respond/3`）产生，都是玩家施放能产生的结构。
  - 静态字段（形状、尺寸、质量、耦合、锚、ends_on_contact）按决策稿 §3.1 从解码后的结构组读出；运动字段由
    `Semblance.trace/8` 在一个测试世界（y < 1 m 的宏格为实占用地面）里求出；`:flying` 状态位与 live 编号
    （`MmoContracts.Voxel.Codec.structure_end_live/1`）按 World 的职责在这里补上。切片 4c 的 World 结构记录生产者
    落地后，本文件的 `program_fields/2`、`motion/3` 改为调用它（退出条件）。
  - 生成：本文件的 `document/1` 是样本文件的唯一生成器；实现或目录有意改变时设置 `WRITE_STRUCTURE_WIRE_SAMPLES=1`
    运行本测试重写文件，再核对 diff，然后重跑 `apps/mmo_contracts/test/fixtures/gen_wire_v2_samples.py` 生成线字节。
    默认只比较、不写。浮点照原值写入（JSON 最短往返表示），线字节因此可逐位复现。
  - 不在这里证明：字段的数值正确性（`magic_structure_test.exs` 按设计附录对拍）、字节布局（mmo_contracts 的
    `magic_wire_test.exs` 用独立生成器的字节对拍）。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias MmoContracts.Voxel.Codec
  alias VoxelRegion.Magic.{Catalog, Cost, Program, Semblance, Structure}

  @digest "e337873b1daaafeb55397bd0ef8e01fda4572dd549d34cd6e268ec54ec638264"
  @catalog_path Application.app_dir(:voxel_region, "priv/magic/#{@digest}.json")
  @ir_samples Path.expand("fixtures/magic/ir-v2-samples.json", __DIR__)
  @path Path.expand("fixtures/magic/structure-v2-samples.json", __DIR__)

  # 与 `magic_quote_samples_test.exs` 相同的施放处读数（环境 293.15 K，形成距离 3 m，A.7 示意热环境）。
  @site %{
    ambient_k: 293.15,
    formation_distance_m: 3.0,
    emissivity: 0.9,
    exchange_w_per_m2_k: 10.0
  }
  @caster 1001
  @t0_us 1_700_000_000_000_000
  # 施法者手边（〈握〉形成位置）与〈附〉目标面上的块中心（地面顶面 y = 1 m 上方半边长 0.15 m）。
  @hand {0.5, 2.5, 1.0}
  @face {2.5, 1.15, 4.5}
  @floor_y 1.0

  setup_all do
    catalog = Catalog.load(@catalog_path)
    ir = Jason.decode!(File.read!(@ir_samples))
    bytes = Map.new(ir["samples"], &{&1["id"], Base.decode16!(&1["program_hex"], case: :lower)})
    %{catalog: catalog, bytes: bytes}
  end

  # 空闲环境读数：所在格 293.15 K、无净热、无供能、无邻居与干预场。
  defp inputs(overrides \\ []) do
    Map.merge(
      %{
        net_heat_j: 0,
        feed_w: 0,
        temperature_k: @site.ambient_k,
        cell_heat_capacity_j_per_k: 1200.0,
        embedded: false,
        neighbors: [],
        fields: [],
        release_doses: [],
        contact: false
      },
      Map.new(overrides)
    )
  end

  defp born(c, preset, sid) do
    {:ok, %Program{kind: :structure, groups: [group]} = program} =
      Program.decode_ir(c.bytes[preset], c.catalog)

    quote = Cost.quote_structure(program, c.catalog, @site)
    {Structure.new(sid, group, quote, 0), group, quote}
  end

  # 逐拍步进到 `stop?.(结构, outputs)` 成立，返回 {拍号, {结构, outputs}}；400 拍内必须停下。
  defp run_until(s, c, inputs, stop?) do
    Enum.reduce_while(1..400, s, fn tick, s ->
      {s, out} = Structure.step(s, inputs, tick, c.catalog)
      if stop?.(s, out), do: {:halt, {tick, {s, out}}}, else: {:cont, s}
    end)
    |> tap(fn result -> assert is_tuple(result), "400 拍内未出现目标事件" end)
  end

  defp terminated?(s, _out), do: s.status != :running

  defp glyph(glyphs, id), do: Enum.find(glyphs, &(&1.id == id))

  # 程序给出的静态字段（决策稿 §3.1）。切片 4c 由 World 的结构记录生产者给出。
  defp program_fields(group, catalog) do
    %{params: p} = glyph(group.shape, "form.semblance")
    {_, form} = Enum.find(catalog.symbols, fn {_, s} -> s.id == "form.semblance" end)
    %{enum: shapes} = Enum.find(form.params, &(&1.name == "shape"))
    {shape, _} = Enum.find(shapes, fn {_, name} -> name == p["shape"] end)

    %{
      shape: shape,
      size1_m: p["size1_mm"] / 1000,
      size2_mm: p["size2_mm"],
      size3_mm: p["size3_mm"],
      # 〈形〉mass_g 未写（zero_means_absent）即无质量、不受重力（用户 Q4-2，设计 Q17(a)）。
      massless: p["mass_g"] == nil,
      # 有一条读〈遇〉且响应〈散〉的规则（设计 §11.1 v2.11 W5）。
      ends_on_contact:
        Enum.any?(group.rules, fn rule ->
          Enum.any?(rule.readings, &(&1.id == "cond.contact")) and
            Enum.any?(rule.responses, &(&1.id == "resp.release"))
        end),
      coupling:
        for(
          {name, id} <- [
            thermal: "cpl.thermal",
            glow: "cpl.glow",
            capacity: "cpl.capacity",
            disrupt: "int.disrupt"
          ],
          glyph(group.quality, id),
          do: name
        ),
      anchor_type: Map.fetch!(%{"anchor.hand" => 0, "anchor.surface" => 1}, group.form_anchor.id),
      proto_id: 0,
      anchor_ref: <<0::96>>
    }
  end

  # 运动字段：静止结构停在形成位置；带〈投〉的结构自手边沿 +Z 抛出，在测试世界里求落点（弹道与 World 同一函数）。
  defp motion(_group, _massless, {:at, point}),
    do: %{origin: point, velocity: {0.0, 0.0, 0.0}, t0_us: @t0_us, flight_s: 0.0, rest: point}

  defp motion(group, massless, {:thrown, radius_m, catalog}) do
    velocity = {0.0, 0.0, glyph(group.motion, "act.throw").params["speed_mmps"] / 1000}

    {{:hit, flight_s, rest, :ground}, nil} =
      Semblance.trace(
        @hand,
        @hand,
        velocity,
        radius_m,
        catalog.limits.range_m,
        nil,
        &ground_cast/4,
        massless
      )

    %{origin: @hand, velocity: velocity, t0_us: @t0_us, flight_s: flight_s, rest: rest}
  end

  # 测试世界：y < 1 m 的宏格都是实占用地面，其余是空气。返回弦段首个进入的实占用微格（1/8 m）。
  defp ground_cast({ax, ay, az}, {dx, dy, dz}, length, state) do
    if ay >= @floor_y and dy < 0 and ay + dy * length < @floor_y do
      s = (ay - @floor_y) / -dy
      {{:ground, {floor((ax + dx * s) * 8), 7, floor((az + dz * s) * 8)}}, state}
    else
      {nil, state}
    end
  end

  # 一条完整记录：live、施法者、程序静态字段、运动字段、`Structure.wire/1` 的动态字段（加 World 判定的状态位）。
  defp record(c, group, live, place, wire, world_status \\ []) do
    fields = program_fields(group, c.catalog)

    place =
      case place do
        :thrown -> {:thrown, fields.size1_m, c.catalog}
        point -> {:at, point}
      end

    status = Enum.filter(Codec.structure_status_bits(), &(&1 in (wire.status ++ world_status)))

    fields
    |> Map.merge(motion(group, fields.massless, place))
    |> Map.merge(%{wire | status: status})
    |> Map.merge(%{live: live, caster: @caster})
  end

  # 样本：{名字, 结构 id, 预设, 说明, 拍号, 事件, 记录}。
  defp records(c) do
    # 灯：出生记录（未步进），无质量、静止在手边。
    {lamp, lamp_group, lamp_quote} = born(c, "lamp", {101, 0})
    lamp_born = record(c, lamp_group, 1, @hand, Structure.wire({lamp, lamp_quote}))

    # 火球：出生记录，飞行中（World 补 :flying），落点是测试世界地面上的命中点。
    {fireball, fireball_group, fireball_quote} = born(c, "fireball", {102, 0})

    fireball_flight =
      record(c, fireball_group, 1, :thrown, Structure.wire({fireball, fireball_quote}), [:flying])

    # 火球接触：第 1 拍带接触步进，〈遇〉→〈散〉触发，respond 主动终止 → live 2，快照取同拍步进结果。
    {hit, hit_group, _} = born(c, "fireball", {103, 0})
    {hit_stepped, hit_out} = Structure.step(hit, inputs(contact: true), 1, c.catalog)
    assert [%{outcome: :met, responses: [%{id: "resp.release"} = release]}] = hit_out.triggered
    {hit_ended, _} = Structure.respond(hit_stepped, release, c.catalog)
    assert hit_ended.status == {:terminated, :released}

    fireball_contact =
      record(
        c,
        hit_group,
        Codec.structure_end_live(:contact),
        :thrown,
        Structure.wire({hit_stepped, hit_out})
      )

    # 灯断供衰竭（附录 A.3：约 132 s）→ live 3。
    {spent, spent_group, _} = born(c, "lamp", {104, 0})
    {spent_tick, spent_result} = run_until(spent, c, inputs(), &terminated?/2)
    assert elem(spent_result, 0).status == {:terminated, :exhausted}

    lamp_exhausted =
      record(
        c,
        spent_group,
        Codec.structure_end_live(:exhausted),
        @hand,
        Structure.wire(spent_result)
      )

    # 灯举在 800 K 的火场格里：env 抬高、欠账累积，相干跌破 0.3 且 x ≥ 0.8·x* → 过载崩解，live 4。
    {hot, hot_group, _} = born(c, "lamp", {105, 0})

    {hot_tick, hot_result} =
      run_until(hot, c, inputs(temperature_k: 800.0), &terminated?/2)

    assert elem(hot_result, 0).status == {:terminated, :collapsed}

    lamp_collapsed =
      record(c, hot_group, Codec.structure_end_live(:collapsed), @hand, Structure.wire(hot_result))

    # 灯在驱散脉冲中心（d = 0，附录 A.4）：第 1 拍驱散 → live 5。场取发出者的拍首状态。
    {pulse, _, _} = born(c, "dispel_pulse", {99, 0})
    field = Structure.disruption_field(pulse, 0.0, 1, c.catalog)
    {dispelled, dispelled_group, _} = born(c, "lamp", {106, 0})
    dispelled_result = Structure.step(dispelled, inputs(fields: [field]), 1, c.catalog)
    assert elem(dispelled_result, 0).status == {:terminated, :dispelled}

    lamp_dispelled =
      record(
        c,
        dispelled_group,
        Codec.structure_end_live(:dispelled),
        @hand,
        Structure.wire(dispelled_result)
      )

    # 定时火种：〈时〉30 s 到期 → 〈散〉，非接触读数触发 → live 6；快照取同拍步进结果。
    {ember, ember_group, _} = born(c, "timed_ember", {107, 0})

    {ember_tick, {ember_stepped, ember_out} = ember_result} =
      run_until(ember, c, inputs(), fn _s, out -> out.triggered != [] end)

    assert [%{outcome: :met, responses: [%{id: "resp.release"} = release]}] = ember_out.triggered

    assert {%{status: {:terminated, :released}}, _} =
             Structure.respond(ember_stepped, release, c.catalog)

    ember_released =
      record(
        c,
        ember_group,
        Codec.structure_end_live(:released),
        @face,
        Structure.wire(ember_result)
      )

    [
      {"deleted", {100, 0}, nil, "无事件删除（live 0）：id 之外全 0", 0, nil, nil},
      {"lamp_born", {101, 0}, "lamp", "灯刚出生（未步进）：无质量、静止在手边，发光取〈辉〉标称 100 W", 0, nil, lamp_born},
      {"fireball_flight", {102, 0}, "fireball", "火球刚出生、飞行中（World 补 flying 位）：有质量弹道，落点为测试地面命中点",
       0, nil, fireball_flight},
      {"fireball_contact", {103, 0}, "fireball", "火球第 1 拍接触：〈遇〉→〈散〉触发，live 2 终态快照（同拍步进结果）", 1,
       "contact", fireball_contact},
      {"lamp_exhausted", {104, 0}, "lamp", "灯无供能逐拍出账至 E_op < E_min：断供衰竭 live 3", spent_tick, "exhausted",
       lamp_exhausted},
      {"lamp_collapsed", {105, 0}, "lamp", "灯举在 800 K 火场格：相干跌破 0.3 且 x ≥ 0.8·x*，过载崩解 live 4", hot_tick,
       "collapsed", lamp_collapsed},
      {"lamp_dispelled", {106, 0}, "lamp", "灯在驱散脉冲中心（d = 0）：第 1 拍驱散 live 5", 1, "dispelled", lamp_dispelled},
      {"timed_ember_released", {107, 0}, "timed_ember", "定时火种（〈附〉块）：〈时〉30 s 到期 → 〈散〉，live 6", ember_tick,
       "released", ember_released}
    ]
  end

  # 状态增量样本：同一结构相邻两拍的装载分箱 ⌊x·32⌋ 改变的第一拍（决策稿 §3.3 的发送条件之一）。
  defp states(c) do
    for {preset, sid} <- [{"lamp", {101, 0}}, {"timed_ember", {107, 0}}] do
      {s, _, quote} = born(c, preset, sid)

      {tick, {_, out} = result} =
        Enum.reduce_while(1..400, {s, floor(quote.x0 * 32)}, fn tick, {s, bin} ->
          {s, out} = Structure.step(s, inputs(), tick, c.catalog)
          next = floor(out.metrics.load * 32)
          if next != bin, do: {:halt, {tick, {s, out}}}, else: {:cont, {s, next}}
        end)

      assert out.events == []
      {preset, sid, tick, Structure.wire(result)}
    end
  end

  defp document(c) do
    %{
      "source" =>
        "ex_mmo_cluster docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md §3；" <>
          "由 Program.decode_ir/2、Cost.quote_structure/3、Structure.new/4、step/4、respond/3、wire/1 算出",
      "catalog_digest" => @digest,
      "ir_samples" => "ir-v2-samples.json（程序字节的唯一来源）",
      "generator" =>
        "apps/voxel_region/test/magic_structure_wire_samples_test.exs；重新生成（仅 Linux）：cd apps/voxel_region && " <>
          "WRITE_STRUCTURE_WIRE_SAMPLES=1 mix test --no-start test/magic_structure_wire_samples_test.exs；" <>
          "之后重跑 apps/mmo_contracts/test/fixtures/gen_wire_v2_samples.py 生成线字节",
      "site" => @site,
      "note" =>
        "fields 是结构记录 v2 的字段值（MmoContracts.Voxel.Codec.encode_structures/1 的输入形状）：" <>
          "coupling、status 为位名列表（按线上位序），anchor_ref 为 12 B 的十六进制，坐标与速度为 [x, y, z]；" <>
          "浮点为原值。state 是状态增量对应结构在该拍的动态字段（温度、发光未量化；量化在线字节生成器与 codec 各自实现）。",
      "records" =>
        for {name, {seq, n}, preset, design, tick, event, fields} <- records(c) do
          %{
            "id" => name,
            "sid" => [seq, n],
            "preset" => preset,
            "design" => design,
            "tick" => tick,
            "event" => event,
            "fields" => fields && json(fields)
          }
        end,
      "states" =>
        for {preset, {seq, n}, tick, wire} <- states(c) do
          %{"sid" => [seq, n], "preset" => preset, "tick" => tick, "state" => json(wire)}
        end
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp json(%{} = map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), json(v)} end)
  defp json(tuple) when is_tuple(tuple), do: Tuple.to_list(tuple)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(<<_::96>> = ref), do: Base.encode16(ref, case: :lower)
  defp json(atom) when is_atom(atom) and atom not in [true, false, nil], do: Atom.to_string(atom)
  defp json(other), do: other

  test "structure-v2-samples.json 与当前实现逐字段一致；样本覆盖 live 0–6 与两条状态增量", c do
    expected = document(c)

    if System.get_env("WRITE_STRUCTURE_WIRE_SAMPLES") == "1" do
      File.write!(
        @path,
        Jason.encode_to_iodata!(expected, pretty: true) |> IO.iodata_to_binary() |> Kernel.<>("\n")
      )
    end

    file = Jason.decode!(File.read!(@path))

    assert Enum.map(file["records"], &(&1["fields"] && &1["fields"]["live"])) ==
             [nil, 1, 1, 2, 3, 4, 5, 6]

    assert length(file["states"]) == 2

    for key <- (Map.keys(expected) ++ Map.keys(file)) |> Enum.uniq(),
        do:
          assert(
            file[key] == expected[key],
            "字段 #{key} 与实现不一致；如属有意改变，按 generator 重新生成"
          )
  end
end
