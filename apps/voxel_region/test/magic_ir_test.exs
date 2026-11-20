defmodule VoxelRegion.MagicIrTest do
  @moduledoc """
  只测试：目录 v5 加载与 IR v2 解码（符号组合魔法 v2 切片 0a）。

  - 契约：设计 v2.6 §11.4（TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md`）的字节布局、
    §11.4.2 的 B1 槽检查顺序与 K1 `dec` 规范判据、§11.4.3 的拒绝清单与 K4 分层；目录 schema 见
    `docs/10-active/magic/2026-11-19-catalog-v5-schema.md`。
  - 夹具：`fixtures/magic/77036cbc….json` 是按 schema 手写的 Test-only 目录（P1 14 个符号与 47 个预留下标，
    按 §2.3 表序冻结全部 61 个下标；姿态照抄 §2.6），不是 UE 发布物；`fixtures/magic/ir-v2-samples.json` 是从设计
    §11.4.4 逐字抽取的 9 组冻结字节（服务端持有的唯一判据）。
  - 判定：冻结样本的期望语义值抄自设计 §11.4.4 的逐字节注释；反例字节在样本上按注释偏移手工改写，期望原因与偏移手算。
  - 不覆盖：签名规则（见 `magic_signature_test.exs`）、数值检查与计价（切片 0b）。
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  @moduletag :t0
  alias VoxelRegion.Magic.{Catalog, Program}
  alias VoxelRegion.Magic.Program.{Glyph, Group, Rule}

  @digest "77036cbc08e1e1dd0139f81c32ba45160c730256d8ced6715f20684f368957bf"
  @path Path.expand("fixtures/magic/#{@digest}.json", __DIR__)
  @samples Path.expand("fixtures/magic/ir-v2-samples.json", __DIR__)
  @preset_ids ~w(draw_1mj draw_2mj lamp fireball hot_throw scorch dispel_pulse timed_ember guarded_fireball)

  setup_all do
    samples = Jason.decode!(File.read!(@samples))

    %{catalog: Catalog.load(@path), data: Jason.decode!(File.read!(@path)), samples_digest: samples["catalog_digest"],
      bytes: Map.new(samples["samples"], &{&1["id"], Base.decode16!(&1["program_hex"], case: :lower)})}
  end

  defp diagnose(c, bytes), do: Program.diagnose_ir(bytes, c.catalog)
  defp catalog(data), do: Catalog.decode(Jason.encode!(data))

  # 把 bytes 中从 at 起的 byte_size(part) 个字节替换为 part。
  defp patch(bytes, at, part),
    do: binary_part(bytes, 0, at) <> part <> binary_part(bytes, at + byte_size(part), byte_size(bytes) - at - byte_size(part))

  defp symbol(data, id, fun),
    do: update_in(data, ["symbols"], fn symbols -> Enum.map(symbols, &if(&1["id"] == id, do: fun.(&1), else: &1)) end)

  defp slot(data, id, name, fun),
    do: symbol(data, id, fn s -> %{s | "params" => Enum.map(s["params"], &if(&1["name"] == name, do: fun.(&1), else: &1))} end)

  test "目录 v5：digest = 文件 sha256；常量、计数、槽表与预设字节按 schema 解码", c do
    assert Base.encode16(c.catalog.digest, case: :lower) == @digest
    assert c.samples_digest == @digest
    assert c.catalog.caster.resolution_omega == 16
    assert c.catalog.construction.eta_j_s_per_rad2 == 18
    assert {c.catalog.limits.program_max_bytes, c.catalog.limits.backup_modes} == {512, [0]}
    assert c.catalog.limits.counts == %{n_act: 1, n_grp: 1, n_ref: 0, n_shape: 1, n_qual: 4, n_energy: 1, n_motion: 1,
             n_rule: 2, n_read: 2, n_resp: 2}
    assert {c.catalog.runtime.thermal_step_min_ms, c.catalog.quotas.region_budget_units} == {25, 256}
    assert c.catalog.group_requires_all == ["form:semblance", "energy:load"]
    # 设计 §11.4.5.1 建议补入的常数：b 底数下限与 quotas / runtime 新字段（抽查成对项与首尾）。
    assert c.catalog.construction.b_floor == 1
    assert {c.catalog.quotas.present_floor_structures, c.catalog.quotas.region_flight_slots_per_present} == {1, 1}
    assert {c.catalog.runtime.windup_interrupt_dose, c.catalog.runtime.env_neighbor_radius_m,
            c.catalog.runtime.env_neighbor_max, c.catalog.runtime.thermal_sleep_delta_k,
            c.catalog.runtime.thermal_sleep_power_w, c.catalog.runtime.quote_life_slices} == {0.3, 8, 16, 5, 100, 32}
    assert {map_size(c.catalog.quotas), map_size(c.catalog.runtime)} == {19, 39}
    # 设计 v2.9：〈热〉phi_grade 只发布 1 级（A3）；Q21(a) 的性质类与从零定义步长。只有〈热〉〈辉〉写 property_class。
    assert Enum.find(c.catalog.symbols[15].params, &(&1.name == "phi_grade")) |> Map.take([:min, :max]) == %{min: 1, max: 1}
    assert {c.catalog.runtime.scratch_unit_step, c.catalog.runtime.scratch_precision_step} == {0.5, 0.25}
    assert for({_, s} <- c.catalog.symbols, s.property_class, into: %{}, do: {s.id, s.property_class}) ==
             %{"cpl.thermal" => "thermal", "cpl.glow" => "emission"}

    # 姿态照抄设计 §2.6（整数度，解码为弧度）：〈取〉保留 v4 姿态；〈满〉〈散〉各为条件层、响应层左支加各自右支。
    degrees = fn index -> Enum.map(c.catalog.symbols[index].pose, &round(&1 * 180 / :math.pi())) end
    assert degrees.(0) == [155, -90, -95, 25, 90, 95]
    assert degrees.(36) == [130, -45, 10, -20, 55, 100]
    assert degrees.(44) == [-60, -45, 10, 5, 30, 15]
    assert degrees.(34) == [130, -45, 10, 45, 45, 0]
    assert degrees.(35) == [130, -45, 10, -10, -5, -45]
    assert degrees.(54) == [80, -130, -35, 15, 80, 20]

    # K3：已发布 14 个 + 预留 47 个 = §2.3 表序全部 61 个下标；〈容〉〈满〉已发布，〈否〉只预留。
    assert {map_size(c.catalog.symbols), map_size(c.catalog.reserved)} == {14, 47}
    assert Enum.sort(Map.keys(c.catalog.symbols) ++ Map.keys(c.catalog.reserved)) == Enum.to_list(0..60)
    assert {c.catalog.symbols[0x17].id, c.catalog.symbols[0x24].id} == {"cpl.capacity", "cond.load"}
    assert {c.catalog.reserved[0x35], c.catalog.reserved[60]} == {"resp.backup", "real.ascend"}

    form = c.catalog.symbols[2]
    assert {form.id, form.section} == {"form.semblance", :shape}
    # 槽序即字节序，照抄 §11.4.2 P1 槽表。
    assert Enum.map(form.params, & &1.name) == ~w(shape size1_mm size2_mm size3_mm mass_g)
    assert hd(form.params).enum == %{0 => "sphere", 1 => "block", 2 => "plate"}
    assert List.last(form.params).zero_means_absent
    assert form.ranges_by_param["shape"]["plate"]["size3_mm"] == {10, 200}
    # 能量槽换算为整数 mJ，键随之改名。
    assert [%{key: "energy_mj", scale: 1000, min: 1, max: 5_000_000}] = c.catalog.symbols[27].params
    assert Enum.at(c.catalog.symbols[23].params, 0).enum == %{0 => "storage", 2 => "repair"}

    # 9 个预设（§11.4.5 清单与推荐 id）与冻结样本逐字相同；加载时已逐个解码并通过签名，这里再经入口复核一次。
    assert Enum.map(c.catalog.presets, &{&1.id, &1.program}) == Enum.map(@preset_ids, &{&1, c.bytes[&1]})
    for preset <- c.catalog.presets, do: assert({:ok, _} = diagnose(c, preset.program))
  end

  test "目录 v5 拒绝：超硬上限、未开放量化类、槽名缺单位后缀、段符号缺 max_per_group、未知字段、非法预设、预留表冲突", c do
    lamp = Enum.find(c.data["presets"], &(&1["id"] == "lamp"))
    reserved = fn fun -> update_in(c.data, ["reserved_symbols"], fun) end

    rejected = [
      put_in(c.data, ["limits", "program_max_bytes"], 513),
      put_in(c.data, ["limits", "counts", "n_qual"], 13),
      put_in(c.data, ["limits", "backup_modes"], [1]),
      slot(c.data, "cpl.thermal", "phi_grade", &Map.put(&1, "class", "sid96")),
      slot(c.data, "energy.load", "energy_j", &Map.put(&1, "name", "energy")),
      symbol(c.data, "cpl.glow", &Map.delete(&1, "max_per_group")),
      symbol(c.data, "cpl.glow", &Map.put(&1, "require_all", ["mass"])),
      symbol(c.data, "cpl.glow", &Map.put(&1, "index", 2)),
      update_in(c.data, ["presets"], &[%{lamp | "program_hex" => String.upcase(lamp["program_hex"])} | &1]),
      update_in(c.data, ["presets"], &[%{lamp | "id" => "lamp_trailing", "program_hex" => lamp["program_hex"] <> "00"} | &1]),
      # 新字段必填；拼错的字段仍按未知字段拒绝。
      update_in(c.data, ["construction"], &Map.delete(&1, "b_floor")),
      put_in(c.data, ["runtime", "quote_life_slice"], 32),
      update_in(c.data, ["runtime"], &Map.delete(&1, "scratch_unit_step")),
      # property_class 只允许质段符号取已定义的类别。
      symbol(c.data, "cpl.glow", &Map.put(&1, "property_class", "light")),
      symbol(c.data, "energy.load", &Map.put(&1, "property_class", "thermal")),
      symbol(c.data, "cpl.glow", &Map.put(&1, "property_class", nil)),
      # ref8 槽须有 refs 声明（S4：非 0xFF 值只由签名层判）。
      symbol(c.data, "anchor.surface", &Map.delete(&1, "refs")),
      # K3 预留表：下标与已发布符号重复、id 与已发布符号重复、表序留空洞、预留项重复。
      reserved.(&[%{"index" => 2, "id" => "x.shadow"} | &1]),
      reserved.(&[%{"index" => 61, "id" => "cpl.glow"} | &1]),
      reserved.(&tl/1),
      reserved.(&[hd(&1) | &1])
    ]

    for data <- rejected, do: assert_raise(ArgumentError, ~r/magic catalog v5/, fn -> catalog(data) end)
  end

  test "冻结样本：9 组字节解码为设计 §11.4.4 声明的语义值", c do
    %{"draw_1mj" => draw, "lamp" => lamp, "fireball" => fireball, "dispel_pulse" => dispel, "timed_ember" => ember} = c.bytes
    # 字节数与设计各标题一致（定时火种 v2.3 已更正为 38 B）。
    assert Enum.map(@preset_ids, &byte_size(c.bytes[&1])) == [7, 7, 30, 43, 35, 32, 33, 38, 55]

    # 取能：energy_j = dec(e=3, m=1000) = 1 000 000 J = 1e9 mJ。
    assert diagnose(c, draw) ==
             {:ok, %Program{kind: :caster_action, bytes: draw,
               action: %Glyph{index: 0, id: "energy.draw", params: %{"energy_mj" => 1_000_000_000}}}}

    hand = %Glyph{index: 7, id: "anchor.hand", params: %{}}
    surface = %Glyph{index: 8, id: "anchor.surface", params: %{"to_group" => nil}}
    form = fn shape, s1, s2, s3, mass ->
      %Glyph{index: 2, id: "form.semblance",
        params: %{"shape" => shape, "size1_mm" => s1, "size2_mm" => s2, "size3_mm" => s3, "mass_g" => mass}}
    end
    load = &%Glyph{index: 27, id: "energy.load", params: %{"energy_mj" => &1}}
    release = %Glyph{index: 44, id: "resp.release", params: %{}}

    # 灯：球 150 mm，mass_g = 0 为“无质量”（跳过区间）；〈辉〉100 W；〈蓄〉dec(2, 500) = 50 kJ。
    assert {:ok, %Program{kind: :structure, groups: [lamp_group]}} = diagnose(c, lamp)
    assert lamp_group == %Group{form_anchor: hand, shape: [form.("sphere", 150, 0, 0, nil)],
             quality: [%Glyph{index: 16, id: "cpl.glow", params: %{"power_w" => 100}}], energy: [load.(50_000_000)]}

    # 火球：球 250 mm、500 g；〈热〉t0_dk = 20000、phi_grade = 1；〈蓄〉dec(1, 2000) = 20 kJ；〈投〉12000 mm/s；当〈遇〉则〈散〉。
    assert {:ok, %Program{groups: [fireball_group]}} = diagnose(c, fireball)
    assert fireball_group == %Group{form_anchor: hand, shape: [form.("sphere", 250, 0, 0, 500)],
             quality: [%Glyph{index: 15, id: "cpl.thermal", params: %{"t0_dk" => 20_000, "phi_grade" => 1}}],
             energy: [load.(20_000_000)],
             motion: [%Glyph{index: 30, id: "act.throw", params: %{"speed_mmps" => 12_000}}],
             rules: [%Rule{priority: 0, readings: [%Glyph{index: 34, id: "cond.contact", params: %{}}],
               responses: [release], backup: :none, backup_response: nil}]}

    # 驱散脉冲：〈附〉to_group = 0xFF；球 200 mm；〈乱〉dec(2, 1000) = 100 kW、半径 3000 mm；〈蓄〉dec(2, 600) = 60 kJ。
    assert {:ok, %Program{groups: [dispel_group]}} = diagnose(c, dispel)
    assert dispel_group == %Group{form_anchor: surface, shape: [form.("sphere", 200, 0, 0, nil)],
             quality: [%Glyph{index: 54, id: "int.disrupt", params: %{"activity_w" => 100_000, "radius_mm" => 3000}}],
             energy: [load.(60_000_000)]}

    # 定时火种：块 150/150/150 mm、无质量；〈蓄〉dec(2, 2000) = 200 kJ；当〈时 3000 cs，from = 0xFF〉则〈散〉。
    assert {:ok, %Program{groups: [ember_group]}} = diagnose(c, ember)
    assert ember_group == %Group{form_anchor: surface, shape: [form.("block", 150, 150, 150, nil)],
             energy: [load.(200_000_000)],
             rules: [%Rule{priority: 0, readings: [%Glyph{index: 35, id: "cond.timer", params: %{"duration_cs" => 3000, "from" => nil}}],
               responses: [release], backup: :none, backup_response: nil}]}

    # 取能 2 MJ：energy_j = dec(e=3, m=2000) = 2 000 000 J = 2e9 mJ。
    assert diagnose(c, c.bytes["draw_2mj"]) ==
             {:ok, %Program{kind: :caster_action, bytes: c.bytes["draw_2mj"],
               action: %Glyph{index: 0, id: "energy.draw", params: %{"energy_mj" => 2_000_000_000}}}}

    thermal = &%Glyph{index: 15, id: "cpl.thermal", params: %{"t0_dk" => &1, "phi_grade" => 1}}
    throw = %Glyph{index: 30, id: "act.throw", params: %{"speed_mmps" => 12_000}}

    # 炽热投掷：球 400 mm、dec(0, 2000) = 2000 g；〈热〉20000 dK、phi_grade 1；〈蓄〉dec(2, 1200) = 120 kJ；〈投〉12000 mm/s；无规则。
    assert {:ok, %Program{groups: [hot_throw_group]}} = diagnose(c, c.bytes["hot_throw"])
    assert hot_throw_group == %Group{form_anchor: hand, shape: [form.("sphere", 400, 0, 0, 2000)],
             quality: [thermal.(20_000)], energy: [load.(120_000_000)], motion: [throw]}

    # 灼点：〈附〉0xFF；球 250 mm、dec(0, 660) = 660 g；〈热〉15000 dK、phi_grade 1；〈蓄〉dec(1, 1500) = 15 kJ；无动段、无规则。
    assert {:ok, %Program{groups: [scorch_group]}} = diagnose(c, c.bytes["scorch"])
    assert scorch_group == %Group{form_anchor: surface, shape: [form.("sphere", 250, 0, 0, 660)],
             quality: [thermal.(15_000)], energy: [load.(15_000_000)]}

    # 过热保险火球：前 34 B 与火球相同；规则 0〈遇〉→〈散〉；规则 1〈满 相干 低于 5000 bp〉→〈散〉；backup 均为 0。
    assert binary_part(c.bytes["guarded_fireball"], 0, 34) == binary_part(fireball, 0, 34)
    assert {:ok, %Program{groups: [guarded_group]}} = diagnose(c, c.bytes["guarded_fireball"])
    coherence_below = %Glyph{index: 36, id: "cond.load",
      params: %{"quantity" => "coherence", "dir" => "below", "threshold_bp" => 5000}}
    assert guarded_group == %{fireball_group | rules: fireball_group.rules ++
             [%Rule{priority: 1, readings: [coherence_below], responses: [release], backup: :none, backup_response: nil}]}
  end

  test "K1：dec 只认 e = 0 或 m ≥ 410；m 能被 10 整除合法、不进位", c do
    # 灯偏移 26 是〈蓄〉energy_j（区间 [1, 5 000 000] J）；样本原值即 (2, 500) = 50 kJ。
    lamp = c.bytes["lamp"]
    dec = fn e, m -> patch(lamp, 26, <<e::4, m::12>>) end

    assert diagnose(c, dec.(1, 100)) == {:error, {:noncanonical_dec, 26, "energy_j"}}
    assert diagnose(c, dec.(2, 100)) == {:error, {:noncanonical_dec, 26, "energy_j"}}
    assert dec.(2, 500) == lamp
    assert {:ok, _} = diagnose(c, lamp)
    # e = 0 时任意 m 都规范，落在区间内即接受；m = 0 也规范，但 0 J 越界，报的是区间而不是规范性。
    for m <- [1, 10, 409, 410, 1000, 4095], do: assert({:ok, _} = diagnose(c, dec.(0, m)))
    assert diagnose(c, dec.(0, 0)) == {:error, {:out_of_range, 26, "energy_j", 0}}
  end

  test "K3：预留下标出现在 Glyph 位置一律按未知下标拒绝", c do
    # 灯偏移 19 是质段〈辉〉的下标；取能偏移 3 是施法者动作 Glyph 的下标。
    for {index, _id} <- c.catalog.reserved do
      assert diagnose(c, patch(c.bytes["lamp"], 19, <<index::16>>)) == {:error, {:unknown_index, 19, index}}
      assert diagnose(c, patch(c.bytes["draw_1mj"], 3, <<index::16>>)) == {:error, {:unknown_index, 3, index}}
    end
  end

  test "拒绝清单：每条规则一个最小反例，原因带字节偏移", c do
    %{"draw_1mj" => draw, "lamp" => lamp, "fireball" => fireball, "dispel_pulse" => dispel} = c.bytes
    # 灯的偏移：9 shape，10/12/14 size1–3，16 mass_g，18 n_qual，19 〈辉〉下标，21 power_w，23 n_energy，24 〈蓄〉下标，26 energy_j。
    # 火球的偏移：34 n_rule，35 priority，40 响应下标，42 backup。驱散的偏移：5 to_group。
    in_order = binary_part(lamp, 0, 18) <> <<2, 0x0010::16, 0x0064::16, 0x0036::16, 0x23E8::16, 0x0BB8::16>> <> binary_part(lamp, 23, 7)
    reversed = binary_part(lamp, 0, 18) <> <<2, 0x0036::16, 0x23E8::16, 0x0BB8::16, 0x0010::16, 0x0064::16>> <> binary_part(lamp, 23, 7)
    twice = binary_part(lamp, 0, 18) <> <<2, 0x0010::16, 0x0064::16, 0x0010::16, 0x0064::16>> <> binary_part(lamp, 23, 7)
    plate = lamp |> patch(9, <<2>>) |> patch(12, <<150::16>>) |> patch(14, <<201::16>>)
    assert {:ok, _} = diagnose(c, in_order)

    cases = [
      # 截断、空程序、尾随字节、超长（先判长度，513 字节全 0 也不进入解析）。
      {binary_part(lamp, 0, 29), {:truncated, 29}},
      {<<>>, {:truncated, 0}},
      {lamp <> <<0>>, {:trailing_bytes, 30}},
      {lamp <> :binary.copy(<<0>>, 483), {:too_long, 513, 512}},
      # 版本、kind、计数：n_act ≠ 1、n_grp = 0、n_rule 超过目录值 2。
      {patch(lamp, 0, <<1>>), {:version, 1}},
      {patch(lamp, 1, <<2>>), {:kind, 1, 2}},
      {patch(draw, 2, <<2>>), {:count, 2, :n_act, 2}},
      {patch(lamp, 2, <<0>>), {:count, 2, :n_grp, 0}},
      {patch(fireball, 34, <<3>>), {:count, 34, :n_rule, 3}},
      # 未知下标（0x0011〈貌〉为 P2，未发布）、段不符（〈辉〉写在能段；结构符号写成施法者动作）。
      {patch(lamp, 19, <<0x0011::16>>), {:unknown_index, 19, 0x11}},
      {patch(lamp, 24, <<0x0010::16>>), {:section, 24, "cpl.glow", :energy}},
      {<<2, 0, 1, 0x0007::16>>, {:section, 3, "anchor.hand", :caster_action}},
      # 非规范顺序：段内降序、完全相同的重复项；规则优先级不是 0。
      {reversed, {:order, 25}},
      # 〈辉〉占 4 B（下标 + 1 个 dec 槽）：19–22 与 23–26。
      {twice, {:order, 23}},
      {patch(fireball, 35, <<1>>), {:priority, 35, 1}},
      # P1 只开放 backup = 0；ref8 在 refs_enabled = false 时只允许 0xFF。
      {patch(fireball, 42, <<1>>), {:backup_mode, 42, 1}},
      {patch(dispel, 5, <<0>>), {:ref_disabled, 5, "to_group", 0}},
      # 槽：阶段外枚举（shape = 3 环未发布）；非规范 dec 200×10²（规范为 2000×10¹）。
      {patch(lamp, 9, <<3>>), {:unpublished_enum, 9, "shape", 3}},
      {patch(lamp, 26, <<0x20C8::16>>), {:noncanonical_dec, 26, "energy_j"}},
      # B1 顺序：3000 W 写成 300×10¹，既非规范又越界，先报非规范。
      {patch(lamp, 21, <<0x112C::16>>), {:noncanonical_dec, 21, "power_w"}},
      # 量化越界：2001 W > 2000；4095×10^15 J 用整数比较，不溢出。
      {patch(lamp, 21, <<0x07D1::16>>), {:out_of_range, 21, "power_w", 2001}},
      # P1 只发布 phi_grade = 1（设计 v2.9 A3）；火球偏移 23 是 phi_grade。
      {patch(fireball, 23, <<2>>), {:out_of_range, 23, "phi_grade", 2}},
      {patch(lamp, 26, <<0xFFFF::16>>), {:out_of_range, 26, "energy_j", 4095 * 10 ** 15}},
      # zero_means_absent 只豁免 0：写入 5 g 仍按 [10, 50000] 检查。
      {patch(lamp, 16, <<5::16>>), {:out_of_range, 16, "mass_g", 5}},
      # 依赖区间：球的 size2 须为 0；板的半厚 size3 ≤ 200。
      {patch(lamp, 12, <<1::16>>), {:dependent_range, 12, "size2_mm", 1}},
      {plate, {:dependent_range, 14, "size3_mm", 201}}
    ]

    for {bytes, reason} <- cases, do: assert(diagnose(c, bytes) == {:error, reason}, inspect({reason, diagnose(c, bytes)}))
  end

  test "〈否〉：in_program = false 的下标在任何 Glyph 位置都拒绝；开放 backup 后内联响应可解码", c do
    fireball = c.bytes["fireball"]
    backup = %{"index" => 53, "id" => "resp.backup", "section" => "rule.response", "phase" => 2, "in_program" => false,
      "params" => [], "units" => 1, "precision" => 0, "pose" => [150, -120, -120, 30, 120, 120]}

    # 按 K3 发布：〈否〉从预留表移入符号表，下标 0x0035 不变。
    c = %{c | catalog: c.data |> update_in(["symbols"], &(&1 ++ [backup]))
                             |> update_in(["reserved_symbols"], &Enum.reject(&1, fn r -> r["index"] == 53 end))
                             |> put_in(["limits", "backup_modes"], [0, 1, 2]) |> catalog()}

    assert diagnose(c, patch(fireball, 40, <<0x0035::16>>)) == {:error, {:not_in_program, 40, "resp.backup"}}
    assert diagnose(c, binary_part(fireball, 0, 42) <> <<1, 0x0035::16>>) == {:error, {:not_in_program, 43, "resp.backup"}}
    assert {:ok, %Program{groups: [%Group{rules: [rule]}]}} = diagnose(c, binary_part(fireball, 0, 42) <> <<2, 0x002C::16>>)
    assert {rule.backup, rule.backup_response} == {:undecidable, %Glyph{index: 44, id: "resp.release", params: %{}}}
  end

  test "长度上限取目录值；mask8 未发布位拒绝", c do
    short = c.data |> put_in(["limits", "program_max_bytes"], 29) |> Map.put("presets", []) |> catalog()
    assert Program.diagnose_ir(c.bytes["lamp"], short) == {:error, {:too_long, 30, 29}}

    masked =
      c.data
      |> slot("cpl.thermal", "phi_grade", &(&1 |> Map.drop(["min", "max"])
                                             |> Map.merge(%{"class" => "mask8", "bits" => [%{"bit" => 0, "name" => "a"}]})))
      |> catalog()

    assert Program.diagnose_ir(patch(c.bytes["fireball"], 23, <<4>>), masked) == {:error, {:unpublished_bits, 23, "phi_grade", 4}}
  end

  test "decode_ir：对外只返回 :invalid_program，并把原因写入 voxel_magic_program_rejected 日志", c do
    lamp = c.bytes["lamp"]
    assert Program.decode_ir(lamp, c.catalog) == diagnose(c, lamp)

    log = capture_log(fn -> assert Program.decode_ir(binary_part(lamp, 0, 29), c.catalog) == {:error, :invalid_program} end)
    assert log =~ "voxel_magic_program_rejected"
    assert log =~ "{:truncated, 29}"
  end
end
