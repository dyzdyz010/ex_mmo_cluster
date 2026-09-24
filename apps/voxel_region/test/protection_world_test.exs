defmodule VoxelRegion.ProtectionWorldTest do
  @moduledoc """
  只测试：受保护区域（R8-03 增量 1，服务端）经真实 World 入口。

  目录夹具 `fixtures/protection/<digest>.json` = 已发布 5be2e8c7（`fixtures/combustion/`，DA_MaterialCoverageV1 字节）
  原样加一个 Test-only 认领工具行（tool 20，action protection.claim，region_max_count 5、region_max_area_m2 1 000 000）
  与同名标签；材料与其余工具逐字节不变（下方第一个测试核对）。增量 2 由 UE 发布正式目录后替换本夹具。
  热环境 = Test-only 辐射环境 ε 0.9（`fixtures/combustion/environment-radiation.json`）。

  场景地形只经作者编辑入口建立；材料只经 material_supply；区域经认领工具（正式玩家路径）或作者入口 author_regions；
  玩家动作经 tool/production/attachment/prefab 四个正式意图入口；时间只经 :thermal_commit / :liquid_commit 推进。
  每个物理边界测试都有同一场景的无区域对照，证明被阻断的现象在没有区域时确实发生。
  期望来自目录算术、账目恒等式或设计阈值（设计：边界是理想绝热镜面，野外↔区域同样是边界），不取自内核输出。
  """
  use ExUnit.Case, async: false
  @moduletag :protection
  alias VoxelRegion.{World, Protection}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @digest "ab44556b0f1d93167f7f0f958c809cfe3281d22f25209b55f0eb2f9601168b7b"
  @base "5be2e8c79d8789a29aa17e023294c8aafbff51ff4b8c07a945035dbfcf91fe57"
  @fixtures Path.expand("fixtures", __DIR__)
  @grass 1
  @clay 8
  @stone 11
  @coal 15
  @ore 16
  @wood 19
  @ice 20
  @water 21
  @copper 24
  @a 1001
  @b 1002
  @claim 20
  @materials [@grass, @clay, @stone, @coal, @ore, @wood, @ice, @water, @copper]

  setup do
    root = Path.join(System.tmp_dir!(), "protection_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(@fixtures, "protection/#{@digest}.json")
    data = Jason.decode!(File.read!(path))
    env = Jason.decode!(File.read!(Path.join(@fixtures, "combustion/environment-radiation.json")))
    %{root: root, path: path, data: data, ambient: env["ambient_kelvin"],
      materials: Map.new(data["materials"], &{&1["material_id"], &1}), tools: Map.new(data["tools"], &{&1["tool_id"], &1})}
  end

  defp start(c, name, opts \\ []) do
    root = Path.join(c.root, "#{name}")
    File.mkdir_p!(root)
    catalog = Path.join(root, "properties.json")
    File.cp!(c.path, catalog)
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "combustion/environment-radiation.json"), env)
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    opts = Keyword.merge([source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env, prefab_catalog_path: prefabs,
      production_materials: @materials], opts)
    w = start_supervised!({World, opts}, id: name)
    for cid <- [@a, @b], do: {:ok, _} = World.material_supply(w, cid, "fixture", Map.new(@materials, &{&1, 60_000_000}))
    w
  end

  defp next, do: System.unique_integer([:positive, :monotonic])

  defp actor(cid) do
    a = %{cid: cid, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: {0.5, 3.5, 0.5}, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp move(a, eye) do
    :ok = GenServer.call(a.player, {:eye, eye})
    %{a | eye: eye}
  end

  defp stamp(a, seq), do: Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()})

  # 正式工具路径：眼睛在目标格正上方 2.5 m 向下看，先查询命中，再以同一身份执行。
  defp use_tool(w, a, {x, y, z}, tool, opts \\ []) do
    {ox, oz} = Keyword.get(opts, :offset, {0.5, 0.5})
    a = move(a, {x + ox, y + 2.5, z + oz})
    seq = next()
    q = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: tool,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}

    case World.tool_intent(w, a, q) do
      {:ok, t} ->
        r = Map.merge(q, Map.take(t, [:micro, :granularity, :incarnation, :owner, :material]))
        World.tool_intent(w, stamp(a, seq), %{r | action: Keyword.get(opts, :action, 1)})

      error ->
        error
    end
  end

  defp claim(w, a, {x0, z0}, {x1, z1}) do
    settle(w)
    s = World.seq(w)
    assert {:ok, ^s} = use_tool(w, a, {x0, 0, z0}, @claim)
    use_tool(w, a, {x1, 0, z1}, @claim)
  end

  defp regions(w), do: World.simulation_snapshot(w, [], {{-100, -1, -100}, {100, 1, 100}}).protection
  defp micro({x, y, z}), do: {x * 8, y * 8, z * 8}
  defp cell(row), do: row.micro |> Tuple.to_list() |> Enum.map(&Integer.floor_div(&1, 8)) |> List.to_tuple()
  defp observe(w, box \\ {{-2, -2, -2}, {2, 2, 2}}), do: VoxelRegion.TestSupport.observe(w, [@a, @b], box)
  defp row(s, c), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == micro(c)))
  defp snapshot(w), do: {World.seq(w), World.simulation_snapshot(w, [@a, @b], {{-2, -2, -2}, {2, 2, 2}})}

  # 拒绝：原因固定为 :protected_region，且序号、余额与同一窗口的完整模拟快照（属性、液量、热账、区域）逐项不变。
  defp denied(w, fun) do
    settle(w)
    before = snapshot(w)
    assert {:error, :protected_region} = fun.()
    assert snapshot(w) == before
  end

  # 热活动期间后台提交照常推进，拒绝只能证明：没有余额、几何、区域或属性事务来自这次请求。
  defp denied_while_active(w, fun) do
    from = World.seq(w)
    balances = World.simulation_snapshot(w, [@a, @b], {{0, 0, 0}, {0, 0, 0}}).material_balances
    assert {:error, :protected_region} = fun.()
    for txn <- World.entries_after(w, from) do
      assert txn.entries == [] and txn.coarse == [] and not Map.has_key?(txn, :material_balances) and
        not Map.has_key?(txn, :protection)
    end
    assert World.simulation_snapshot(w, [@a, @b], {{0, 0, 0}, {0, 0, 0}}).material_balances == balances
  end

  defp settle(w) do
    send(w, :thermal_commit)
    if World.simulation_snapshot(w, [], {{0, 0, 0}, {0, 0, 0}}).thermal_accounting.active, do: settle(w), else: :ok
  end

  test "夹具 = 5be2e8c7 原字节加一行认领工具；材料与其余工具不变", c do
    assert Base.encode16(:crypto.hash(:sha256, File.read!(c.path)), case: :lower) == @digest
    base = Jason.decode!(File.read!(Path.join(@fixtures, "combustion/#{@base}.json")))
    assert c.data["materials"] == base["materials"]
    assert Enum.reject(c.data["tools"], &(&1["tool_id"] == @claim)) == base["tools"]
    assert %{"action" => "protection.claim", "region_max_count" => 5, "region_max_area_m2" => 1_000_000} = c.tools[@claim]
  end

  describe "认领工具（玩家适配）" do
    test "两次点击建区域，同格再点取消，区域内再点释放；重叠与占用拒绝，自己放下的格不算占用", c do
      w = start(c, :claim)
      ground = for x <- -10..40, z <- -10..12, do: {{x, 0, z}, @stone}
      {:ok, _} = World.apply_edits(w, ground)
      settle(w)
      a = actor(@a)
      b = actor(@b)

      # 取消：同一格点两次，不产生事务，不建区域。
      s = World.seq(w)
      assert {:ok, ^s} = use_tool(w, a, {0, 0, 0}, @claim)
      assert {:ok, ^s} = use_tool(w, a, {0, 0, 0}, @claim)
      assert regions(w) == %{}

      assert {:ok, seq} = claim(w, a, {9, 9}, {0, 0})
      assert seq == s + 1
      assert [{{^seq, 1}, %{holder: {:character, @a}, min: {0, 0}, max: {9, 9}, created_seq: ^seq, created_by: @a}}] =
        Map.to_list(regions(w))

      # 别人：角点落在区域内立即拒绝；两角都在外但矩形覆盖区域在第二次点击拒绝。自己重叠也拒绝（不合并）。
      assert {:error, :region_overlap} = use_tool(w, b, {5, 0, 5}, @claim)
      assert {:error, :region_overlap} = claim(w, b, {-5, -5}, {12, 12})
      assert {:error, :region_overlap} = claim(w, a, {-5, -5}, {12, 12})
      assert map_size(regions(w)) == 1

      # 占用：B 花材料放下的格在矩形内，A 不能认领；B 自己可以。
      bb = move(b, {30.5, 2.5, 0.5})
      q = next()
      assert {:ok, _} = World.production_intent(w, stamp(bb, q), %{request_id: q, client_intent_seq: q, logical_scene_id: 1,
        action: 1, material: @stone, tool_id: 1, coord: {30, 1, 0}})
      settle(w)
      s = World.seq(w)
      assert {:error, :region_occupied} = claim(w, a, {25, -5}, {35, 5})
      assert World.seq(w) == s
      assert {:ok, _} = claim(w, b, {25, -5}, {35, 5})

      # 释放：无待定角时点自己区域内任一格。
      settle(w)
      s = World.seq(w)
      assert {:ok, released} = use_tool(w, a, {3, 0, 3}, @claim)
      assert released == s + 1
      assert [%{holder: {:character, @b}}] = Map.values(regions(w))
    end

    test "面积上限恰好 1 km² 通过、多 1 行拒绝；数量上限第 5 个通过、第 6 个拒绝", c do
      w = start(c, :limits)
      corners = [{0, 0}, {999, 999}, {2000, 0}, {2999, 1000}] ++ for(i <- 0..5, do: [{i * 10, 3000}, {i * 10 + 1, 3001}])
      {:ok, _} = World.apply_edits(w, for({x, z} <- List.flatten(corners), do: {{x, 0, z}, @stone}))
      a = actor(@a)
      b = actor(@b)
      # 1000 × 1000 格 = 1 000 000 m²；1000 × 1001 = 1 001 000 m²。
      assert {:ok, _} = claim(w, a, {0, 0}, {999, 999})
      assert {:error, :region_too_large} = claim(w, a, {2000, 0}, {2999, 1000})
      assert [%{min: {0, 0}, max: {999, 999}}] = Map.values(World.simulation_snapshot(w, [], {{-1, -1, -1}, {20, 1, 20}}).protection)

      for i <- 0..4, do: assert({:ok, _} = claim(w, b, {i * 10, 3000}, {i * 10 + 1, 3001}))
      assert {:error, :region_limit} = claim(w, b, {50, 3000}, {51, 3001})
      held = World.simulation_snapshot(w, [], {{-1, -1, 40}, {20, 1, 60}}).protection
      assert Enum.count(held, fn {_, r} -> r.holder == {:character, @b} end) == 5
    end

    test "作者保留区域：玩家不能改、不能认领；作者写给某角色的区域只有该角色能改", c do
      w = start(c, :reserved)
      {:ok, _} = World.apply_edits(w, for(x <- 0..30, do: {{x, 0, 0}, @stone}))
      assert {:error, :region_overlap} = World.author_regions(w, [
        %{holder: :reserved, min: {0, 0}, max: {9, 9}}, %{holder: :reserved, min: {9, 0}, max: {12, 0}}])
      assert regions(w) == %{}
      settle(w)
      s = World.seq(w)
      assert {:ok, seq} = World.author_regions(w, [%{holder: :reserved, min: {0, -5}, max: {9, 5}},
        %{holder: {:character, @a}, min: {20, -5}, max: {30, 5}}])
      assert seq == s + 1
      assert %{{^seq, 1} => %{holder: :reserved, created_by: nil}, {^seq, 2} => %{holder: {:character, @a}}} = regions(w)
      a = actor(@a)
      b = actor(@b)
      denied(w, fn -> use_tool(w, b, {4, 0, 0}, 1) end)
      denied(w, fn -> use_tool(w, a, {4, 0, 0}, 1) end)
      assert {:error, :region_overlap} = use_tool(w, b, {4, 0, 0}, @claim)
      denied(w, fn -> use_tool(w, b, {25, 0, 0}, 1) end)
      assert {:ok, _} = use_tool(w, a, {25, 0, 0}, 1)
      assert {:ok, _} = use_tool(w, b, {15, 0, 0}, 1)
    end
  end

  # 每类动作一条车道：B 区域内一格（x=4）与野外一格（x=20），A 的区域在 x<0。
  # 顺序：先在静止世界里逐项验证 A 对 B 区域的请求被拒绝且一切不变；再由 B 在自己区域、A 在野外执行同一请求并成功。
  describe "许可：每个动作 × 自己区域 / 邻居区域 / 野外" do
    @lanes ~w(build mine f_macro f_leaf prefab_place prefab_remove prefab_replace attach_place attach_remove
      pour scoop fire heater cool heat install toggle feed)a
    defp lane(name), do: Enum.find_index(@lanes, &(&1 == name)) * 3 + 1

    defp macro_prefab(dir, material) do
      bytes = <<"VXPD", 3::32-little, 0::32-little, 0::32-little, 0::32-little, 1::32-little,
        0::signed-little-32, 0::signed-little-32, 0::signed-little-32, material::16-little>>
      File.write!(Path.join(dir, "macro_#{material}.vxpd"), bytes)
      :crypto.hash(:sha256, bytes)
    end

    defp leaf_prefab(dir) do
      bytes = <<"VXPD", 1::32-little, 2::32-little, 0::signed-little-32, 0::signed-little-32, 0::signed-little-32,
        @stone::16-little, 1::signed-little-32, 0::signed-little-32, 0::signed-little-32, @wood::16-little, 0::32-little>>
      File.write!(Path.join(dir, "leaf.vxpd"), bytes)
      :crypto.hash(:sha256, bytes)
    end

    defp prefab(w, a, kind, request) do
      a = move(a, {Keyword.get(request, :x, 0) + 0.5, 3.5, Keyword.get(request, :z, 0) + 0.5})
      seq = next()
      r = request |> Keyword.drop([:x, :z]) |> Map.new() |> Map.merge(%{request_id: seq, client_intent_seq: seq, logical_scene_id: 1})
      World.prefab_intent(w, a, kind, r)
    end

    defp place(w, a, id, {x, _, z}), do: prefab(w, a, :voxel_prefab_place_v1, x: x, z: z, definition_id: id, anchor: {x * 8, 8, z * 8}, orientation: 0)
    defp place_leaf(w, a, id, {x, _, z}), do: prefab(w, a, :voxel_prefab_place_v1, x: x, z: z, definition_id: id, anchor: {x * 8, 8, z * 8}, orientation: 0)

    defp production(w, a, action, material, tool, {x, y, z} = coord) do
      a = move(a, {x + 0.5, y + 2.5, z + 0.5})
      seq = next()
      World.production_intent(w, stamp(a, seq), %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1,
        action: action, material: material, tool_id: tool, coord: coord})
    end

    # 铜面附件贴在宿主格 {x, y, z} 的顶面。
    defp face(w, a, {x, y, z}, action, id \\ 0) do
      a = move(a, {x + 0.5, y + 2.5, z + 0.5})
      seq = next()
      World.attachment_intent(w, a, %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: action,
        kind: 0, axis: 1, size: 8, anchor: {x * 8, (y + 1) * 8, z * 8}, id: id, material: @copper, tool_id: 1})
    end

    defp device(w, a, {x, y, z}, id, tool) do
      a = move(a, {x + 0.5, y + 2.5, z + 0.5})
      seq = next()
      World.tool_intent(w, stamp(a, seq), %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1,
        tool_id: tool, direction: {0.0, -1.0, 0.0}, micro: {x * 8, (y + 1) * 8, z * 8}, granularity: 3, incarnation: id,
        owner: {id, 1}, material: @copper})
    end

    defp cup(x, z), do: [{{x, 0, z}, @stone} | for({dx, dz} <- [{-1, 0}, {1, 0}, {0, -1}, {0, 1}], do: {{x + dx, 1, z + dz}, @stone})]

    test "拒绝一律 :protected_region 且无副作用；同一请求由持有者在自己区域、任何人在野外都成功", c do
      w = start(c, :matrix, liquid_bounds: {{-40, 0, -10}, {40, 8, 70}})
      dir = Path.join([c.root, "matrix", "prefabs"])
      wood_def = macro_prefab(dir, @wood)
      stone_def = macro_prefab(dir, @stone)
      leaf_def = leaf_prefab(dir)
      :ok = World.publish_prefabs(w, dir)
      a = actor(@a)
      b = actor(@b)
      xs = [4, 20]
      at = fn name, x -> {x, 1, lane(name)} end
      ground = for x <- [-16, -1, 0, 15 | xs], z <- 0..58, do: {{x, 0, z}, @stone}
      blocks = for x <- xs, {name, m} <- [mine: @stone, fire: @wood, heater: @ore], do: {at.(name, x), m}
      cups = for x <- xs, name <- [:pour, :scoop, :cool, :heat], do: cup(x, lane(name))
      {:ok, _} = World.apply_edits(w, ground ++ blocks ++ List.flatten(cups))
      assert {:ok, _} = claim(w, a, {-16, 0}, {-1, 58})
      assert {:ok, _} = claim(w, b, {0, 0}, {15, 58})
      water = Path.join(c.root, "water.json")
      File.write!(water, Jason.encode!(%{classification: "Test-only",
        deposits: for(x <- xs, name <- [:scoop, :cool], do: %{macro: Tuple.to_list(at.(name, x)), material: @water})}))
      {:ok, _} = World.liquid_experiment(w, water)
      # B 在两处预置被操作对象：宏格/微格 Prefab 与铜面附件。
      prefabs = for x <- xs, into: %{} do
        {:ok, macro} = place(w, b, wood_def, at.(:f_macro, x))
        {:ok, leaf} = place_leaf(w, b, leaf_def, at.(:f_leaf, x))
        {:ok, removed} = place(w, b, wood_def, at.(:prefab_remove, x))
        {:ok, replaced} = place(w, b, wood_def, at.(:prefab_replace, x))
        {x, %{macro: macro, leaf: leaf, remove: removed, replace: replaced}}
      end
      faces = for x <- xs, into: %{} do
        ids = for name <- [:attach_remove, :install, :toggle, :feed], into: %{} do
          {:ok, id} = face(w, b, {x, 0, lane(name)}, 0)
          {name, id}
        end
        {x, ids}
      end
      settle(w)

      # 一次请求的全部形状，参数 x 选择 B 区域（4）或野外（20）。
      requests = [
        build: fn who, x -> production(w, who, 1, @stone, 1, at.(:build, x)) end,
        mine: fn who, x -> use_tool(w, who, at.(:mine, x), 1) end,
        f_macro: fn who, x -> use_tool(w, who, at.(:f_macro, x), 1, action: 2) end,
        f_leaf: fn who, x -> use_tool(w, who, at.(:f_leaf, x), 1, action: 2, offset: {0.0625, 0.0625}) end,
        prefab_place: fn who, x -> place(w, who, stone_def, at.(:prefab_place, x)) end,
        prefab_remove: fn who, x ->
          prefab(w, who, :voxel_prefab_remove_v1, x: x, z: lane(:prefab_remove), instance_id: {prefabs[x].remove, 0}) end,
        prefab_replace: fn who, x ->
          prefab(w, who, :voxel_prefab_replace_v1, x: x, z: lane(:prefab_replace), instance_id: {prefabs[x].replace, 0},
            definition_id: stone_def) end,
        attach_place: fn who, x -> face(w, who, {x, 0, lane(:attach_place)}, 0) end,
        attach_remove: fn who, x -> face(w, who, {x, 0, lane(:attach_remove)}, 1, faces[x].attach_remove) end,
        pour: fn who, x -> production(w, who, 3, @water, 12, at.(:pour, x)) end,
        scoop: fn who, x -> production(w, who, 2, @water, 11, at.(:scoop, x)) end,
        ignite: fn who, x -> use_tool(w, who, at.(:fire, x), 9) end,
        extinguish: fn who, x -> use_tool(w, who, at.(:fire, x), 10) end,
        heater: fn who, x -> use_tool(w, who, at.(:heater, x), 2) end,
        cool: fn who, x -> use_tool(w, who, at.(:cool, x), 13) end,
        install: fn who, x -> device(w, who, {x, 0, lane(:install)}, faces[x].install, 3) end,
        toggle: fn who, x -> device(w, who, {x, 0, lane(:toggle)}, faces[x].toggle, 7) end,
        feed: fn who, x -> device(w, who, {x, 0, lane(:feed)}, faces[x].feed, 8) end
      ]

      for {name, request} <- requests do
        denied(w, fn ->
          result = request.(a, 4)
          IO.puts("PROTECTION_DENY #{name} #{inspect(result)}")
          result
        end)
      end

      # 放行：B 在自己区域、A 在野外；开关与投料先安装对应设备，灭火先点火，化冰先在杯里放冰。
      for {name, request} <- requests, name not in [:toggle, :feed, :extinguish], who <- [{b, 4}, {a, 20}] do
        {actor, x} = who
        assert {:ok, _} = request.(actor, x), "#{name} by #{actor.cid} at x=#{x}"
      end
      for {actor, x} <- [{b, 4}, {a, 20}] do
        assert {:ok, _} = requests[:extinguish].(actor, x)
        assert {:ok, _} = device(w, actor, {x, 0, lane(:toggle)}, faces[x].toggle, 4)
        assert {:ok, _} = requests[:toggle].(actor, x)
        assert {:ok, _} = device(w, actor, {x, 0, lane(:feed)}, faces[x].feed, 3)
        assert {:ok, _} = requests[:feed].(actor, x)
        assert {:ok, _} = production(w, actor, 1, @ice, 1, at.(:heat, x))
      end
      # 化冰（phase.heat）的对象只能在热活动开始后建立，拒绝用活动期判据。
      denied_while_active(w, fn -> use_tool(w, a, at.(:heat, 4), 14) end)
      assert {:ok, _} = use_tool(w, b, at.(:heat, 4), 14)
      assert {:ok, _} = use_tool(w, a, at.(:heat, 20), 14)
    end
  end

  describe "物理边界（理想绝热镜面，野外↔区域同样是边界）" do
    # 只测试：K 一次（工具 9）。
    defp ignite(w, who, c), do: {:ok, _} = use_tool(w, who, c, 9)

    # 燃烧期间逐次提交记录首次燃烧时刻与消失；返回稳定后快照。
    defp burn(w, box, limit \\ 20_000) do
      Enum.reduce_while(1..100_000, %{lit: %{}, seen: MapSet.new(), gone: MapSet.new()}, fn _, acc ->
        send(w, :thermal_commit)
        s = observe(w, box)
        now = for {_, r} <- s.damage, r.granularity == 0, into: %{}, do: {cell(r), r}
        acc = %{acc | lit: Enum.reduce(now, acc.lit, fn {p, r}, lit ->
                  if Map.get(r, :burning, false), do: Map.put_new(lit, p, s.thermal.elapsed_s), else: lit end),
                gone: MapSet.union(acc.gone, MapSet.difference(acc.seen, MapSet.new(Map.keys(now)))),
                seen: MapSet.union(acc.seen, MapSet.new(Map.keys(now)))}
        if not s.thermal.active or s.thermal.elapsed_s > limit,
          do: {:halt, Map.put(acc, :state, s)},
          else: {:cont, acc}
      end)
    end

    defp assert_ledgers(c, s) do
      sensible = for {_, r} <- s.damage, r.granularity == 0, Map.has_key?(r, :temperature_kelvin), reduce: 0.0,
        do: (sum -> sum + c.materials[r.material]["heat_capacity_per_macro"] * (r.temperature_kelvin - c.ambient))
      ledger = s.thermal.supplied_j + s.thermal.environment_j - Map.get(s.thermal, :removed_j, 0.0) -
        Map.get(s.thermal, :transform_j, 0.0)
      assert_in_delta sensible, ledger, 1.0e-6 * s.thermal.supplied_j
      left = for {_, r} <- s.damage, reduce: 0.0, do: (sum -> sum + Map.get(r, :remaining_fuel_j, 0.0))
      assert_in_delta s.thermal.fuel_initialized_j, s.thermal.combustion_j + Map.get(s.thermal, :discarded_fuel_j, 0.0) +
        Map.get(s.thermal, :transform_reductant_fuel_j, 0.0) + left, 1.0e-6 * s.thermal.fuel_initialized_j
    end

    # 两个角色各认领一块多 chunk 矩形，边界在 x=20|21（不对齐 16）。
    defp two_regions(w, claims?) do
      a = actor(@a)
      b = actor(@b)
      if claims? do
        {:ok, _} = World.apply_edits(w, for(p <- [{-20, 0, -3}, {20, 0, 6}, {21, 0, -3}, {40, 0, 6}], do: {p, @stone}))
        assert {:ok, _} = claim(w, a, {-20, -3}, {20, 6})
        assert {:ok, _} = claim(w, b, {21, -3}, {40, 6})
      end
      {a, b}
    end

    for claims? <- [true, false] do
      test "边界两侧相邻木头：A 点燃自己的木头烧尽#{if claims?, do: "；B 的木头与地面没有任何属性行（满血、环境温度）", else: "（对照：无区域时 60 s 内引燃 B 的木头）"}", c do
        w = start(c, :"fire_#{unquote(claims?)}")
        {:ok, _} = World.apply_edits(w, for(x <- 17..24, z <- 0..4, do: {{x, 0, z}, @grass}) ++
          [{{20, 1, 2}, @wood}, {{21, 1, 2}, @wood}])
        {a, _b} = two_regions(w, unquote(claims?))
        ignite(w, a, {20, 1, 2})
        acc = burn(w, {{-1, -1, -1}, {1, 1, 1}})
        s = acc.state
        refute s.thermal.active
        assert MapSet.member?(acc.gone, {20, 1, 2})
        assert_ledgers(c, s)
        if unquote(claims?) do
          assert Enum.filter(Map.values(s.damage), &(elem(cell(&1), 0) >= 21)) == []
          refute Map.has_key?(acc.lit, {21, 1, 2})
          refute MapSet.member?(acc.seen, {21, 1, 2})
        else
          assert acc.lit[{21, 1, 2}] - acc.lit[{20, 1, 2}] <= 60.0
        end
        IO.puts("PROTECTION_FIRE claims=#{unquote(claims?)} lit=#{inspect(Enum.sort(acc.lit))} settled_at=#{s.thermal.elapsed_s}")
      end

      test "空气间隙辐射：A 的燃烧木头隔一格空气面对 B 的石头#{if claims?, do: "，石头不升温", else: "（对照：石头升温）"}", c do
        w = start(c, :"radiation_#{unquote(claims?)}")
        {:ok, _} = World.apply_edits(w, [{{20, 5, 2}, @wood}, {{22, 5, 2}, @stone}])
        {a, _} = two_regions(w, unquote(claims?))
        ignite(w, a, {20, 5, 2})
        acc = burn(w, {{-1, -1, -1}, {1, 1, 1}})
        stone = acc.state.damage |> Map.values() |> Enum.find(&(cell(&1) == {22, 5, 2}))
        assert_ledgers(c, acc.state)
        if unquote(claims?),
          do: assert(stone == nil and not MapSet.member?(acc.seen, {22, 5, 2})),
          else: assert(MapSet.member?(acc.seen, {22, 5, 2}))
      end
    end

    for claims? <- [true, false] do
      test "液体：野外紧贴边界倒水#{if claims?, do: "，0 单位进入 B 的区域，总量不变", else: "（对照：水流进 x=21）"}", c do
        w = start(c, :"liquid_#{unquote(claims?)}", liquid_bounds: {{14, 0, -2}, {28, 4, 3}})
        channel = for x <- 16..26, do: [{{x, 0, 0}, @stone}, {{x, 1, -1}, @stone}, {{x, 1, 1}, @stone}]
        {:ok, _} = World.apply_edits(w, List.flatten(channel) ++ [{{15, 1, 0}, @stone}, {{27, 1, 0}, @stone}])
        if unquote(claims?), do: {:ok, _} = World.author_regions(w, [%{holder: {:character, @b}, min: {21, -2}, max: {30, 2}}])
        a = actor(@a)
        total = fn ->
          s = World.simulation_snapshot(w, [@a], {{0, 0, -1}, {1, 1, 1}})
          Enum.sum(Map.values(s.liquid_quantities)) + Enum.find(s.material_balances, &(&1.material == @water)).units
        end
        before = total.()
        assert {:ok, _} = production(w, a, 3, @water, 12, {20, 1, 0})
        for _ <- 1..60, do: send(w, :liquid_commit)
        q = World.simulation_snapshot(w, [@a], {{0, 0, -1}, {1, 1, 1}}).liquid_quantities
        inside = for {{x, _, _}, units} <- q, x >= 21, reduce: 0, do: (n -> n + units)
        assert total.() == before
        if unquote(claims?), do: assert(inside == 0), else: assert(inside > 0)
        IO.puts("PROTECTION_LIQUID claims=#{unquote(claims?)} quantities=#{inspect(Enum.sort(q))}")
      end

      test "电路：边界两侧的源与加热器串成回路#{if claims?, do: "，跨边界不连通，加热器电流 0", else: "（对照：有电流）"}", c do
        w = start(c, :"circuit_#{unquote(claims?)}")
        row = [{{18, 1, 0}, @copper}, {{19, 1, 0}, @wood}, {{20, 1, 0}, @copper}, {{21, 1, 0}, @wood}, {{22, 1, 0}, @copper}]
        back = [{{18, 1, 1}, @copper}, {{22, 1, 1}, @copper}] ++ for(x <- 18..22, do: {{x, 1, 2}, @copper})
        {:ok, _} = World.apply_edits(w, row ++ back)
        if unquote(claims?), do: {:ok, _} = World.author_regions(w, [
          %{holder: {:character, @a}, min: {10, -5}, max: {20, 5}}, %{holder: {:character, @b}, min: {21, -5}, max: {30, 5}}])
        a = actor(@a)
        b = actor(@b)
        {:ok, source} = face(w, a, {19, 1, 0}, 0)
        {:ok, heater} = face(w, b, {21, 1, 0}, 0)
        assert {:ok, _} = device(w, a, {19, 1, 0}, source, 3)
        assert {:ok, _} = device(w, b, {21, 1, 0}, heater, 6)
        assert {:ok, _} = device(w, a, {19, 1, 0}, source, 8)
        send(w, :thermal_commit)
        devices = for {_, %{granularity: 3, circuit: d}} <- observe(w).damage, into: %{}, do: {d.tool_id, d}
        if unquote(claims?),
          do: assert(devices[6].current_a == 0.0 and devices[3].remaining_j == c.tools[8]["circuit_energy_j"]),
          else: assert(devices[6].current_a > 0.1)
        IO.puts("PROTECTION_CIRCUIT claims=#{unquote(claims?)} heater_a=#{devices[6].current_a}")
      end

      test "冶炼：A 的铜矿被加热过转化温度，B 的煤紧贴#{if claims?, do: "，矿不取煤、不转化，煤无属性行", else: "（对照：转化为铜）"}", c do
        w = start(c, :"ore_#{unquote(claims?)}")
        {:ok, _} = World.apply_edits(w, [{{20, 5, 0}, @ore}, {{21, 5, 0}, @coal}])
        if unquote(claims?), do: {:ok, _} = World.author_regions(w, [
          %{holder: {:character, @a}, min: {10, -5}, max: {20, 5}}, %{holder: {:character, @b}, min: {21, -5}, max: {30, 5}}])
        # Test-only 热源（ε 0 实验环境，只看接触与还原剂）：26 MJ @ 1 MW，26 s 内升温 ≈ 26 MJ / 21 360 J/K ≈ 1200 K，
        # 孤立或贴煤（接触导热约 34 W/K）都越过 X = 1373.15 K，且低于矿的热阻 1600 K。
        path = Path.join(c.root, "heat_#{unquote(claims?)}.json")
        File.write!(path, Jason.encode!(%{classification: "Test-only", source_macro: [20, 5, 0], ambient_kelvin: c.ambient,
          environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0, view_range_cells: 8,
          power_w: 1.0e6, energy_j: 2.6e7}))
        :ok = World.thermal_experiment(w, path)
        {peak, s} = Enum.reduce_while(1..20_000, {0.0, nil}, fn _, {peak, _} ->
          send(w, :thermal_commit)
          s = observe(w)
          ore = row(s, {20, 5, 0})
          peak = max(peak, if(ore, do: Map.get(ore, :temperature_kelvin, 0.0), else: 0.0))
          done = not s.thermal.active or s.thermal.elapsed_s > 3000 or Map.get(s.thermal, :transform_units, 0) > 0
          if done, do: {:halt, {peak, s}}, else: {:cont, {peak, s}}
        end)
        converted = Map.get(s.thermal, :transform_units, 0) > 0
        IO.puts("PROTECTION_ORE claims=#{unquote(claims?)} peak=#{peak} converted=#{converted} elapsed=#{s.thermal.elapsed_s} active=#{s.thermal.active} rows=#{inspect(for {_, r} <- s.damage, do: {cell(r), r.material, r.hp, Map.get(r, :temperature_kelvin), Map.get(r, :burning)})}")
        if unquote(claims?) do
          assert peak >= c.materials[@ore]["transform_kelvin"]
          refute converted
          assert row(s, {21, 5, 0}) == nil
        else
          assert converted
        end
      end
    end

    test "野外林火在野外蔓延，停在 B 区域边缘", c do
      w = start(c, :forest)
      {:ok, _} = World.apply_edits(w, for(x <- 14..24, z <- 0..4, do: {{x, 0, z}, @grass}) ++
        for(x <- 15..22, do: {{x, 1, 2}, @wood}))
      {:ok, _} = World.author_regions(w, [%{holder: {:character, @b}, min: {21, -5}, max: {40, 10}}])
      ignite(w, actor(@a), {15, 1, 2})
      acc = burn(w, {{-1, -1, -1}, {1, 1, 1}})
      for x <- 15..20, do: assert(Map.has_key?(acc.lit, {x, 1, 2}) and MapSet.member?(acc.gone, {x, 1, 2}))
      assert Enum.filter(Map.values(acc.state.damage), &(elem(cell(&1), 0) >= 21)) == []
      assert_ledgers(c, acc.state)
      IO.puts("PROTECTION_FOREST lit=#{inspect(Enum.sort(acc.lit))} settled_at=#{acc.state.thermal.elapsed_s}")
    end
  end

  test "区域随日志重放、压实检查点与冷重启保留；释放同样持久；待定角不持久", c do
    w = start(c, :persist)
    {:ok, _} = World.apply_edits(w, [{{0, 0, -2}, @stone}, {{9, 0, 2}, @stone} | for(x <- 0..12, do: {{x, 0, 0}, @stone})])
    a = actor(@a)
    b = actor(@b)
    assert {:ok, _} = claim(w, a, {0, -2}, {9, 2})
    held = regions(w)
    assert {:ok, _} = use_tool(w, a, {11, 0, 0}, @claim)
    restart = fn ->
      stop_supervised!(:persist)
      start(c, :persist)
    end
    w = restart.()
    assert regions(w) == held
    denied(w, fn -> use_tool(w, b, {5, 0, 0}, 1) end)
    # 待定角随进程消失：重启后第一次点击重新记角，不建区域。
    settle(w)
    s = World.seq(w)
    assert {:ok, ^s} = use_tool(w, a, {12, 0, 0}, @claim)
    assert :ok = World.compact(w)
    w = restart.()
    assert regions(w) == held
    denied(w, fn -> use_tool(w, b, {5, 0, 0}, 1) end)
    assert {:ok, _} = use_tool(w, a, {5, 0, 0}, @claim)
    assert regions(w) == %{}
    w = restart.()
    assert regions(w) == %{}
    assert {:ok, _} = use_tool(w, b, {5, 0, 0}, 1)
  end

  test "索引：查询、重叠、删除后桶清空；1 km² 方形与 1 m 宽长条的桶数" do
    p = Protection.apply(Protection.new(), %{{1, 1} => %{holder: :reserved, min: {-10, -10}, max: {300, 5}},
      {1, 2} => %{holder: {:character, 7}, min: {301, -10}, max: {301, -10}}})
    assert Protection.holder(p, {-10, 99, -10}) == :reserved
    assert Protection.holder(p, {300, -99, 5}) == :reserved
    assert Protection.holder(p, {301, 0, -10}) == {:character, 7}
    assert Protection.holder(p, {301, 0, -9}) == nil
    assert Protection.holder(p, {-11, 0, 0}) == nil
    assert Protection.overlaps?(p, {300, 5}, {400, 400})
    refute Protection.overlaps?(p, {302, -10}, {400, 400})
    refute Protection.same_holder?(p, {300, 0, 0}, {301, 0, -10})
    assert Protection.same_holder?(Protection.new(), {300, 0, 0}, {301, 0, -10})
    assert Protection.apply(p, %{{1, 1} => nil, {1, 2} => nil}) == Protection.new()
    square = Protection.apply(Protection.new(), %{{1, 1} => %{holder: :reserved, min: {0, 0}, max: {999, 999}}})
    strip = Protection.apply(Protection.new(), %{{1, 1} => %{holder: :reserved, min: {0, 0}, max: {999_999, 0}}})
    IO.puts("PROTECTION_INDEX square_buckets=#{map_size(square.index)} square_words=#{:erts_debug.size(square)} " <>
      "strip_buckets=#{map_size(strip.index)} strip_words=#{:erts_debug.size(strip)}")
    assert map_size(square.index) == 16
    assert map_size(strip.index) == 3907
  end
end
