defmodule VoxelRegion.MagicSignatureTest do
  @moduledoc """
  只测试：签名解释器 `Magic.Signature`（符号组合魔法 v2 切片 0a，设计 §3.2、§3.3）。

  - 契约：每条签名规则（`provides_by_param` + `requires_all`、`requires_any`、`requires_by_param`、`excludes`、
    `max_per_group`、`max_per_rule`、`unique_by`、`refs` 的组与规则两种、目录级 `group_requires_all`）各有一个最小反例；
    经真实入口 `Program.diagnose_ir/2` 触发，判定为 `{:signature, violations}` 中的完整违规项。
  - 设计 v2.5–v2.6 裁定：S1/S4 越界引用同样以 `refs` 报出；S2 数值取值键按内部单位（J 槽按 mJ）；S3 输出全部违规，
    每条带组序号、部件序号 `part_index`（v2.7 R10：组内规范字节序，0 起）、符号、原因码与未满足的标签。
  - 夹具：与 `magic_ir_test.exs` 同一份 Test-only 目录 v5 与冻结样本；P1 目录没有用到的规则
    （`requires_by_param`、`excludes`、启用的 `refs`）在测试内改写目录数据后经 `Catalog.decode/1` 加载。
  - 冻结样本本身全部通过签名，由 `magic_ir_test.exs` 的解码用例覆盖，这里不重复。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.Magic.{Catalog, Program}

  @path Path.expand(
          "fixtures/magic/fcc1002aae2cb73ec18bfeaae39c44707d15322c75e0831faebc6bf975a45443.json",
          __DIR__
        )
  @samples Path.expand("fixtures/magic/ir-v2-samples.json", __DIR__)

  setup_all do
    samples = Jason.decode!(File.read!(@samples))["samples"]

    %{
      catalog: Catalog.load(@path),
      data: Jason.decode!(File.read!(@path)),
      bytes: Map.new(samples, &{&1["id"], Base.decode16!(&1["program_hex"], case: :lower)})
    }
  end

  # 改写签名后的目录去掉预设：预设在加载时逐个过签名，改写的签名可能让与本用例无关的预设不成立。
  defp catalog(data), do: Catalog.decode(Jason.encode!(Map.put(data, "presets", [])))

  defp symbol(data, id, fun),
    do:
      update_in(data, ["symbols"], fn symbols ->
        Enum.map(symbols, &if(&1["id"] == id, do: fun.(&1), else: &1))
      end)

  defp enable_ref(data, id, name),
    do:
      symbol(data, id, fn s ->
        %{
          s
          | "params" =>
              Enum.map(
                s["params"],
                &if(&1["name"] == name, do: %{&1 | "refs_enabled" => true}, else: &1)
              )
        }
      end)

  defp violations(catalog, bytes) do
    case Program.diagnose_ir(bytes, catalog) do
      {:error, {:signature, violations}} -> violations
      other -> flunk("期望签名违规，实际 #{inspect(other)}")
    end
  end

  # part_index：符号实例在本组规范字节中的 0 起部件序号（形成锚为 0；组级违规为 nil）。
  defp violation(id, part_index, check, detail, group \\ 0),
    do: %{group: group, part_index: part_index, symbol: id, check: check, detail: detail}

  test "provides_by_param / requires_all：〈形〉未写质量时不提供 mass，〈热〉不成立（T15 前提）", c do
    # 火球偏移 16 是 mass_g；写 0 即“无质量”。
    no_mass =
      binary_part(c.bytes["fireball"], 0, 16) <>
        <<0::16>> <> binary_part(c.bytes["fireball"], 18, 25)

    # 部件序号：〈握〉0〈形〉1〈热〉2〈蓄〉3〈投〉4〈遇〉5〈散〉6。
    assert violations(c.catalog, no_mass) == [
             violation("cpl.thermal", 2, :requires_all, ["mass"])
           ]
  end

  test "requires_any：〈遇〉需要接触、热、投掷或传输之一；灯没有任何一个", c do
    # 灯末尾 n_rule = 0 改为 1 条规则：priority 0，读〈遇〉，响应〈散〉，backup 0。
    lamp = binary_part(c.bytes["lamp"], 0, 29) <> <<1, 0, 1, 0x0022::16, 1, 0x002C::16, 0>>

    # 部件序号：〈握〉0〈形〉1〈辉〉2〈蓄〉3〈遇〉4〈散〉5。
    assert violations(c.catalog, lamp) ==
             [
               violation("cond.contact", 4, :requires_any, [
                 ["coupling:contact"],
                 ["coupling:thermal"],
                 ["motion:throw"],
                 ["motion:transmit"]
               ])
             ]
  end

  test "group_requires_all：结构组缺〈蓄〉", c do
    # 灯在偏移 23 的 n_energy 起改为：n_energy = 0、n_motion = 0、n_rule = 0。
    lamp = binary_part(c.bytes["lamp"], 0, 23) <> <<0, 0, 0>>

    assert violations(c.catalog, lamp) == [
             violation(nil, nil, :group_requires_all, ["energy:load"])
           ]
  end

  test "max_per_group 与 unique_by：两个〈辉〉超限；两个同种〈容〉重复，不同种通过", c do
    quality = fn glyphs ->
      binary_part(c.bytes["lamp"], 0, 18) <> glyphs <> binary_part(c.bytes["lamp"], 23, 7)
    end

    assert violations(c.catalog, quality.(<<2, 0x0010::16, 100::16, 0x0010::16, 200::16>>)) ==
             [violation("cpl.glow", 3, :max_per_group, 2)]

    # 〈辉〉100 W 后接两个〈容〉：cap_kind = 0 储能，等级 2 与 3。
    assert violations(
             c.catalog,
             quality.(<<3, 0x0010::16, 100::16, 0x0017::16, 0, 2, 0x0017::16, 0, 3>>)
           ) ==
             [violation("cpl.capacity", 4, :unique_by, ["cap_kind"])]

    assert {:ok, _} =
             Program.diagnose_ir(
               quality.(<<3, 0x0010::16, 100::16, 0x0017::16, 0, 2, 0x0017::16, 2, 2>>),
               c.catalog
             )
  end

  test "max_per_rule：一条规则读两个〈时〉", c do
    # 定时火种偏移 28 是 n_read；改为两个〈时〉3000 cs 与 4000 cs（按槽字节升序），其后接原响应与 backup。
    ember =
      binary_part(c.bytes["timed_ember"], 0, 28) <>
        <<2, 0x0023::16, 3000::16, 0xFF, 0x0023::16, 4000::16, 0xFF>> <>
        binary_part(c.bytes["timed_ember"], 34, 4)

    # 部件序号：〈附〉0〈形〉1〈蓄〉2〈时〉3〈时〉4〈散〉5；超出的是第二个〈时〉。
    assert violations(c.catalog, ember) == [violation("cond.timer", 4, :max_per_rule, {0, 2})]
  end

  test "requires_by_param：按枚举取值要求标签（测试内改写〈满〉签名）", c do
    catalog =
      c.data
      |> symbol(
        "cond.load",
        &Map.put(&1, "requires_by_param", %{"quantity" => %{"coherence" => ["coupling:glow"]}})
      )
      |> catalog()

    # 火球加第 2 条规则：当〈满 quantity, dir = 1 低于, 5000 bp〉则〈散〉。
    fireball = c.bytes["fireball"]

    with_rule = fn quantity ->
      binary_part(fireball, 0, 34) <>
        <<2>> <>
        binary_part(fireball, 35, 8) <>
        <<1, 1, 0x0024::16, quantity, 1, 5000::16, 1, 0x002C::16, 0>>
    end

    # 规则 1 的〈满〉在火球 7 个实例之后，部件序号 7。
    assert violations(catalog, with_rule.(1)) == [
             violation("cond.load", 7, :requires_by_param, ["coupling:glow"])
           ]

    assert {:ok, _} = Program.diagnose_ir(with_rule.(0), catalog)
  end

  test "excludes：本组不得具备的标签（测试内改写〈乱〉签名）", c do
    catalog =
      c.data |> symbol("int.disrupt", &Map.put(&1, "excludes", ["coupling:glow"])) |> catalog()

    # 驱散脉冲偏移 19 是 n_qual：改为〈辉〉100 W +〈乱〉。
    dispel =
      binary_part(c.bytes["dispel_pulse"], 0, 19) <>
        <<2, 0x0010::16, 100::16>> <> binary_part(c.bytes["dispel_pulse"], 20, 13)

    assert violations(catalog, dispel) == [
             violation("int.disrupt", 3, :excludes, ["coupling:glow"])
           ]
  end

  test "refs（组）：〈附〉to_group 只能指向严格在前的组", c do
    catalog =
      c.data
      |> enable_ref("anchor.surface", "to_group")
      |> put_in(["limits", "counts", "n_grp"], 2)
      |> catalog()

    # 驱散脉冲的组字节从偏移 3 起，组内偏移 2 是 to_group。
    group = fn to_group ->
      <<0x0008::16, to_group>> <> binary_part(c.bytes["dispel_pulse"], 6, 27)
    end

    ref = [%{param: "to_group", kind: :group}]

    assert {:ok, _} = Program.diagnose_ir(<<2, 1, 2>> <> group.(0xFF) <> group.(0), catalog)

    assert violations(catalog, <<2, 1, 2>> <> group.(0) <> group.(0xFF)) == [
             violation("anchor.surface", 0, :refs, ref)
           ]

    assert violations(catalog, <<2, 1, 2>> <> group.(0xFF) <> group.(1)) == [
             violation("anchor.surface", 0, :refs, ref, 1)
           ]

    # S4：越界（只有 2 组却引用 7）不另设检查，字节层放行，签名层同样以 refs 报出。
    assert violations(catalog, <<2, 1, 2>> <> group.(0xFF) <> group.(7)) == [
             violation("anchor.surface", 0, :refs, ref, 1)
           ]
  end

  test "refs（规则）：〈时〉from 只能指向本组严格在前的规则", c do
    catalog = c.data |> enable_ref("cond.timer", "from") |> catalog()

    # 定时火种偏移 26 是 n_rule；改为两条规则：当〈时 3000 cs，from〉则〈散〉。
    rule = fn priority, from -> <<priority, 1, 0x0023::16, 3000::16, from, 1, 0x002C::16, 0>> end

    ember = fn from0, from1 ->
      binary_part(c.bytes["timed_ember"], 0, 26) <> <<2>> <> rule.(0, from0) <> rule.(1, from1)
    end

    assert {:ok, _} = Program.diagnose_ir(ember.(0xFF, 0), catalog)

    # 部件序号：〈附〉0〈形〉1〈蓄〉2，规则 0：〈时〉3〈散〉4，规则 1：〈时〉5〈散〉6。
    ref = [%{param: "from", kind: :rule}]
    assert violations(catalog, ember.(0, 0xFF)) == [violation("cond.timer", 3, :refs, ref)]
    # S4：越界（只有 2 条规则却引用 9）同样以 refs 报出。
    assert violations(catalog, ember.(0xFF, 9)) == [violation("cond.timer", 5, :refs, ref)]
  end

  test "S2：数值取值键按内部单位比较（J 槽按 mJ）", c do
    # 灯的〈蓄〉为 50 kJ = 50 000 000 mJ；〈辉〉要求只有该装载才提供的标签。
    keyed = fn key ->
      c.data
      |> symbol(
        "energy.load",
        &Map.put(&1, "provides_by_param", %{"energy_j" => %{key => ["load:50kJ"]}})
      )
      |> symbol("cpl.glow", &Map.put(&1, "requires_all", ["load:50kJ"]))
      |> catalog()
    end

    assert {:ok, _} = Program.diagnose_ir(c.bytes["lamp"], keyed.("50000000"))
    # 以槽单位 J 写的键不命中。
    assert violations(keyed.("50000"), c.bytes["lamp"]) == [
             violation("cpl.glow", 2, :requires_all, ["load:50kJ"])
           ]
  end

  test "S3：一个程序的全部违规都输出，各带组序号、部件序号、符号、原因码与未满足的标签", c do
    # 灯去掉〈蓄〉并加规则〈遇〉→〈散〉：组缺 energy:load，〈遇〉缺读数来源。部件序号：〈握〉0〈形〉1〈辉〉2〈遇〉3〈散〉4。
    lamp = binary_part(c.bytes["lamp"], 0, 23) <> <<0, 0, 1, 0, 1, 0x0022::16, 1, 0x002C::16, 0>>

    assert violations(c.catalog, lamp) == [
             violation(nil, nil, :group_requires_all, ["energy:load"]),
             violation("cond.contact", 3, :requires_any, [
               ["coupling:contact"],
               ["coupling:thermal"],
               ["motion:throw"],
               ["motion:transmit"]
             ])
           ]
  end
end
