defmodule VoxelRegion.MagicQuoteSamplesTest do
  @moduledoc """
  只测试：离线报价样本 `fixtures/magic/quote-v2-samples.json` 与当前实现不漂移（供客户端 U0 编辑器对接报价显示，
  设计 v2.9 §9 U0、§4.2、§11.4.6）。

  - 契约：样本文件里每个字段都等于用同一目录、同一组施放处读数调用 `Cost.quote_structure/3` 的结果。浮点量按
    `@decimals` 位小数四舍五入后写入、比较；整数（能量 mJ、计数）逐位比较。
  - 夹具：程序字节取冻结样本 `fixtures/magic/ir-v2-samples.json`（9 个预设，含 2 个施法者动作〈取〉）；拒绝反例由
    样本改写槽字节得到（偏移按设计 §11.4.4 逐字节注释手数），经真实 `Program.decode_ir/2` 接纳，都是玩家能写出的程序。
  - 生成：本文件的 `document/2` 是样本文件的唯一生成器，只调用产品函数，不另写计价逻辑。实现或目录有意改变时，
    设置 `WRITE_MAGIC_QUOTE_SAMPLES=1` 运行本测试重写文件，再核对 diff；默认只比较、不写。
  - 判定的正确性不在这里证明：各字段的期望值由 `magic_cost_test.exs` 按设计附录对拍。本测试只保证文件与实现一致，
    并保证三个反例各自只触发目标检查。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.Magic.{Catalog, Cost, Program}

  @digest "e337873b1daaafeb55397bd0ef8e01fda4572dd549d34cd6e268ec54ec638264"
  @catalog_path Application.app_dir(:voxel_region, "priv/magic/#{@digest}.json")
  @ir_samples Path.expand("fixtures/magic/ir-v2-samples.json", __DIR__)
  @path Path.expand("fixtures/magic/quote-v2-samples.json", __DIR__)
  @decimals 6

  # 与 `magic_cost_test.exs` 相同的施放处读数：环境 293.15 K（附录 A.1）；〈附〉的形成位置与〈取〉的能源目标都在
  # 3 m（本地施法域 6 m 内，T6 通过）；
  # T15 的热环境取设计 A.7 的示意值 ε = 0.9、h = 10 W/(m²·K)。
  @site %{
    ambient_k: 293.15,
    formation_distance_m: 3.0,
    emissivity: 0.9,
    exchange_w_per_m2_k: 10.0
  }

  # 报价中写入样本的字段（设计 §4.2 与 §11.4.6 的名字，内部单位）；施法者动作只有构造计价的一组。
  @structure_fields ~w(units precision volume_m3 e_cap_mj e_min_mj x0 x_star p_maint_w life_s detect_w
    first_tick_min_mj entries_charge entries_spoof physical_mj loss_mj total_mj windup_s steps rejects)a
  @caster_action_fields ~w(units precision physical_mj loss_mj total_mj windup_s steps rejects)a

  @field_notes %{
    "units" => "S：结构单元数（含 §4.5 从零定义附加量）",
    "precision" => "P：精度系数 1 + Σπ；0x83 的 quote_s = units × precision",
    "volume_m3" => "V：体积（m³）",
    "e_cap_mj" => "E_cap：储能硬上限（整数 mJ）",
    "e_min_mj" => "E_min：最低运行储能（整数 mJ）；0x83 的 e_min_j = e_min_mj / 1000",
    "x0" => "出生装载比",
    "x_star" => "稳态线 x*（施放处温度定的 env，不含邻近干扰）",
    "p_maint_w" => "出生时维持功率：运行 + 修复 + 发光 + 活动（W）",
    "life_s" => "预计寿命（模拟秒，能量切片求积；带热耦合者为下界）",
    "detect_w" => "静持可察觉功率（W，§4.2 v2.9 A5）",
    "first_tick_min_mj" => "撑过第一拍所需的最低 E₀_op（整数 mJ）；0x83 的 first_tick_min_j = 本值 / 1000",
    "entries_charge" => "无〈印〉的〈纳〉数（P1 恒为 0）",
    "entries_spoof" => "规则所读外部读数的种类数",
    "physical_mj" => "E_phys：物理能量（整数 mJ；〈取〉为 0）",
    "loss_mj" => "构型损耗（整数 mJ，含出手前置）",
    "total_mj" => "总支出 = physical_mj + loss_mj（整数 mJ）；0x83 的 quote_j = total_mj / 1000",
    "windup_s" => "前摇（s，含出手前置）",
    "steps" =>
      "按 §3.5 自动构造顺序的各步：symbol、part_index、adjust_s、inject_s（s）、complexity（到本步为止的 S·P）、" <>
        "spent_mj（到本步为止的累计支出，整数 mJ）；fail_step 由 Cost.staged_failure/3 按 Ω_eff 与余额从这里判定",
    "rejects" => "数值检查违规（§3.3），check 为目录 numeric_checks 的名字，detail 为比较的两侧；空表即可施放"
  }

  setup_all do
    catalog = Catalog.load(@catalog_path)
    ir = Jason.decode!(File.read!(@ir_samples))
    %{catalog: catalog, ir: ir}
  end

  defp patch(bytes, at, part),
    do:
      binary_part(bytes, 0, at) <>
        part <> binary_part(bytes, at + byte_size(part), byte_size(bytes) - at - byte_size(part))

  # 拒绝反例：{id, 说明, 字节, 期望的唯一违规检查}。偏移见设计 §11.4.4 的逐字节注释。
  defp counterexamples(bytes) do
    [
      # 火球偏移 10 是〈形〉size1_mm：250 → 150，同样的热量装进 0.15 m 球（§4.6：x₀ 1.98）。
      {"t5_capacity", "T5：火球改为 0.15 m 球，装载超过储能硬上限", patch(bytes["fireball"], 10, <<150::16>>),
       :capacity},
      # 灯偏移 26 是〈蓄〉energy_j：50 kJ → dec(0, 600) = 600 J，不足 E_min 500 J 加首拍出账。
      {"t13_first_tick", "T13：灯的〈蓄〉改为 600 J，撑不过第一拍", patch(bytes["lamp"], 26, <<0::4, 600::12>>),
       :first_tick},
      # 火球改写：size1 → 50 mm（偏移 10）、mass → dec(0, 10) = 10 g（16）、t0 → 15000 dK（21）、〈蓄〉→ dec(0, 1500)
      # = 1.5 kJ（27）。热容 5 J/K 的稳定步长约 13.8 ms（A.7），其余检查都通过。
      {"t15_thermal_step", "T15：火球改为 0.05 m、10 g、1500 K、〈蓄〉1.5 kJ，热节点稳定步长不足 25 ms",
       bytes["fireball"]
       |> patch(10, <<50::16>>)
       |> patch(16, <<0::4, 10::12>>)
       |> patch(21, <<15_000::16>>)
       |> patch(27, <<0::4, 1500::12>>), :thermal_step}
    ]
  end

  # 样本文件的唯一生成器：只调用 `Program.decode_ir/2` 与 `Cost.quote_structure/3`。
  defp document(catalog, ir) do
    bytes = Map.new(ir["samples"], &{&1["id"], Base.decode16!(&1["program_hex"], case: :lower)})

    presets =
      for sample <- ir["samples"] do
        program = program!(bytes[sample["id"]], catalog)
        quote = Cost.quote_structure(program, catalog, @site)
        fields = if program.kind == :structure, do: @structure_fields, else: @caster_action_fields

        %{
          "id" => sample["id"],
          "design" => sample["design"],
          "kind" => Atom.to_string(program.kind),
          "program_hex" => sample["program_hex"],
          "quote" => Map.take(quote, fields)
        }
      end

    rejected =
      for {id, design, program_bytes, check} <- counterexamples(bytes) do
        quote = Cost.quote_structure(program!(program_bytes, catalog), catalog, @site)
        assert Enum.map(quote.rejects, & &1.check) == [check], "#{id}: #{inspect(quote.rejects)}"

        %{
          "id" => id,
          "design" => design,
          "program_hex" => Base.encode16(program_bytes, case: :lower),
          "rejects" => quote.rejects
        }
      end

    %{
      "source" =>
        "TheWorldBook docs/2026-11-19-glyph-composition-game-design.md v2.9 §4.2、§11.4.6；" <>
          "由服务端 Magic.Cost.quote_structure/3 算出",
      "catalog_digest" => Base.encode16(catalog.digest, case: :lower),
      "ir_samples" => "ir-v2-samples.json（程序字节的唯一来源；presets[].program_hex 照抄）",
      "generator" =>
        "apps/voxel_region/test/magic_quote_samples_test.exs；重新生成（仅 Linux）：cd apps/voxel_region && " <>
          "WRITE_MAGIC_QUOTE_SAMPLES=1 mix test --no-start test/magic_quote_samples_test.exs",
      "site" => @site,
      "float_decimals" => @decimals,
      "units_note" =>
        "能量一律为整数 mJ（键名后缀 _mj）；时间为 s（_s）；功率为 W（_w）；体积为 m³；其余无量纲。" <>
          "浮点量已按 float_decimals 位小数四舍五入（Elixir Float.round/2），比较时双方同样处理。施法者动作（kind = caster_action）只有构造计价字段。",
      "fields" => @field_notes,
      "presets" => presets,
      "rejected" => rejected
    }
    |> normalize()
  end

  defp program!(bytes, catalog) do
    {:ok, %Program{} = program} = Program.decode_ir(bytes, catalog)
    program
  end

  # JSON 化：原子键与原子值转字符串，浮点按固定小数位四舍五入，再经一次编解码与文件内容取同一表示。
  defp normalize(term), do: term |> rounded() |> Jason.encode!() |> Jason.decode!()

  defp rounded(x) when is_float(x), do: Float.round(x, @decimals)
  defp rounded(list) when is_list(list), do: Enum.map(list, &rounded/1)
  defp rounded(%{} = map), do: Map.new(map, fn {k, v} -> {k, rounded(v)} end)
  defp rounded(other), do: other

  test "quote-v2-samples.json 与当前实现逐字段一致（浮点按固定小数位），目录 digest 与程序字节取自唯一来源", c do
    expected = document(c.catalog, c.ir)

    if System.get_env("WRITE_MAGIC_QUOTE_SAMPLES") == "1" do
      File.write!(
        @path,
        Jason.encode_to_iodata!(expected, pretty: true)
        |> IO.iodata_to_binary()
        |> Kernel.<>("\n")
      )
    end

    file = Jason.decode!(File.read!(@path))
    assert file["catalog_digest"] == @digest and c.ir["catalog_digest"] == @digest
    assert length(file["presets"]) == 9 and length(file["rejected"]) == 3

    for key <- (Map.keys(expected) ++ Map.keys(file)) |> Enum.uniq(),
        do: assert(file[key] == expected[key], "字段 #{key} 与实现不一致；如属有意改变，按 generator 重新生成")
  end
end
