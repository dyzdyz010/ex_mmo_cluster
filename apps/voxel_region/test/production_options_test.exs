defmodule VoxelRegion.ProductionOptionsTest do
  @moduledoc """
  只测试：进食 / 合成的可行性门槛只由 World 定义一次（`VoxelRegion.World.Production.consumable/3`、`craftable/3`），
  提交（生产意图 action 5 / 4）与只读查询 `World.production_options/2` 共用（NPC 稿 A 批 1 评审修正，
  `docs/10-active/cross-cutting/2026-11-18-npc-full-capability-coverage-decision.md` §7 “2026-11-19 批 1 评审修正”）。

  契约：同一 World 状态下，某材料出现在 `production_options` 的 `eat` / `craft` 里，当且仅当此刻对它提交进食 / 合成会被接受；
  只读查询不改世界（seq 不变）。两处曾经的 NPC 侧镜像偏差以 World 的语义为准：
  - **配方输入不是生产材料**：按角色的真实余额比较（World 一直如此；NPC 原来只看生产材料的余额行、把它当 0）。反例的
    前提由产品路径做出：铜作为生产材料时经作者入口供给，之后部署收窄生产材料（铜不再是）并重启，余额随日志恢复。
  - **配方输入重复**：World 逐条比较；但目录加载（`VoxelRegion.Damage.load/1`）拒绝输入里重复的材料，产品做不出这样的目录，
    所以不拿手写的重复配方下结论，只锁住“加载即拒绝”这一前提。

  层次：真实 World 集成（`../Voxim/Docs/Testing.md` §2.2），文件日志、测试数据源、每例独占一个世界目录；不起数据库。
  材料行取真实目录 Voxim `Content/Voxel/Properties/Playable/Published/e6db8dee…json`（2026-11-10 最新一份）的目录字段
  （`display_name`、`food`、`place_units`、`recipe_inputs`、`recipe_units`）：可食只有 Fern 34 / Dandelion 36 / Allium 39，
  配方取 Switch 41（铜 24 × 8192 + 石 11 × 4096）、灰褐砌石 46（石 × 2097152）、石质饰面 47（石灰石 10 × 2097152）。
  其余属性用同一组基础属性（同 `damage_world_test`）。余额只经 `World.material_supply/4` 一次供给，之后只经正式生产意图消费。

  执行：`cd apps/voxel_region && mix test test/production_options_test.exs`。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{Damage, World}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @cid 1001
  @limestone 10
  @stone 11
  @copper 24
  @fern 34
  @dandelion 36
  @allium 39
  @switch 41
  @masonry 46
  @facing 47
  @serving 262_144
  @macro 2_097_152

  # 真实目录的目录字段（见 moduledoc）。
  @rows %{
    @limestone => %{display_name: "Limestone"},
    @stone => %{display_name: "Stone"},
    @copper => %{display_name: "Copper"},
    @fern => %{
      display_name: "Fern",
      food: %{protein_g: 1.38, energy_j: 42_705.36},
      place_units: @serving
    },
    @dandelion => %{
      display_name: "Dandelion",
      food: %{protein_g: 1.08, energy_j: 75_362.4},
      place_units: @serving
    },
    @allium => %{
      display_name: "Allium",
      food: %{protein_g: 0.6, energy_j: 102_157.92},
      place_units: @serving
    },
    @switch => %{
      display_name: "Switch",
      recipe_inputs: [%{material_id: @copper, units: 8192}, %{material_id: @stone, units: 4096}],
      recipe_units: 4096
    },
    @masonry => %{
      display_name: "灰褐砌石",
      recipe_inputs: [%{material_id: @stone, units: @macro}],
      recipe_units: @macro
    },
    @facing => %{
      display_name: "石质饰面",
      recipe_inputs: [%{material_id: @limestone, units: @macro}],
      recipe_units: @macro
    }
  }

  @produced [@limestone, @stone, @copper, @fern, @dandelion, @allium, @switch, @masonry, @facing]

  setup do
    root =
      Path.join(System.tmp_dir!(), "production_options_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(catalog(@rows)))
    %{root: root, catalog: catalog}
  end

  defp catalog(rows) do
    base = %{
      max_hp_per_macro: 100.0,
      defense: 2.0,
      tags: [],
      responses: [%{action: "damage", multiplier: 1.0}]
    }

    materials =
      for id <- Enum.uniq(Enum.to_list(0..23) ++ Enum.sort(Map.keys(rows))),
          do:
            base
            |> Map.put(:material_id, id)
            |> Map.merge(if(id == 0, do: %{max_hp_per_macro: 0.0}, else: %{}))
            |> Map.merge(Map.get(rows, id, %{}))

    %{
      schema_version: 1,
      tags: [%{id: "damage"}],
      materials: materials,
      tools: [
        %{
          id: "pickaxe",
          tool_id: 1,
          action: "damage",
          power: 30.0,
          range_macro: 6.0,
          interval_seconds: 0.5
        }
      ],
      definitions: []
    }
  end

  defp start(c, production) do
    start_supervised!(
      {World,
       [
         source: Source,
         log: Log,
         root: c.root,
         observer: self(),
         name: nil,
         property_catalog_path: c.catalog,
         production_materials: production
       ]},
      id: :world
    )
  end

  defp restart(c, production) do
    :ok = stop_supervised(:world)
    start(c, production)
  end

  defp actor do
    a = %{
      cid: @cid,
      gate: self(),
      identity: make_ref(),
      refresh: &Actor.tool_context/2,
      eye: {0.5, 3.5, 0.5},
      tick_us: 16_667
    }

    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  # 正式生产意图（与 Scene / NPC Body 发出的同一种请求）：5 = 进食，4 = 合成。
  defp commit(w, a, action, material) do
    seq = System.unique_integer([:positive, :monotonic])

    World.production_intent(
      w,
      Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()}),
      %{
        request_id: seq,
        client_intent_seq: seq,
        logical_scene_id: 1,
        action: action,
        coord: {0, 0, 0},
        tool_id: 1,
        material: material
      }
    )
  end

  defp listed(options, key), do: Enum.map(options[key], & &1.material)

  test "只读查询与提交同一判定：列出的恰是此刻提交会被接受的；配方输入不是生产材料时按真实余额判；查询不改世界", c do
    w = start(c, @produced)

    # 一次作者供给：Fern 两份、Dandelion 差一个单位、Allium 一份；铜与石恰够一个开关、石比砌石差一个单位；石灰石恰够一份饰面。
    {:ok, _} =
      World.material_supply(w, @cid, "options-fixture", %{
        @fern => 2 * @serving,
        @dandelion => @serving - 1,
        @allium => @serving,
        @copper => 8192,
        @stone => @macro - 1,
        @limestone => @macro
      })

    # 部署收窄生产材料后重启：铜与 Allium 不再是生产材料，余额随日志恢复（产品能做出“非生产材料有余额”的唯一路径）。
    w = restart(c, @produced -- [@copper, @allium])
    a = actor()
    seq = World.seq(w)

    assert World.production_options(w, @cid) == %{
             seq: seq,
             eat: [%{material: @fern, name: "Fern", units: @serving}],
             # 反例（偏差一）：开关的输入铜已不是生产材料，但真实余额 8192 够——World 列出它，提交也接受。
             craft: [
               %{
                 material: @switch,
                 name: "Switch",
                 units: 4096,
                 inputs: [%{material: @copper, units: 8192}, %{material: @stone, units: 4096}]
               },
               %{
                 material: @facing,
                 name: "石质饰面",
                 units: @macro,
                 inputs: [%{material: @limestone, units: @macro}]
               }
             ]
           }

    # 只读：不改世界。
    assert World.seq(w) == seq

    # 逐个材料（两遍：成功的提交会改变余额，每次提交前都重读）：列出 ⇔ 提交被接受；拒绝原因同提交的原因。
    probes = [@stone, @fern, @dandelion, @allium, @copper, @switch, @masonry, @facing]

    results =
      for _round <- 1..2, material <- probes, {action, key} <- [{5, :eat}, {4, :craft}] do
        listed? = material in listed(World.production_options(w, @cid), key)
        result = commit(w, a, action, material)

        assert listed? == match?({:ok, _}, result),
               "#{key} #{material}：查询 #{listed?}、提交 #{inspect(result)}"

        {key, material, elem(result, 0) == :ok || elem(result, 1)}
      end

    accepted = for {key, material, true} <- results, do: {key, material}
    # Fern 两份各吃一次；开关、饰面各合成一次（第二遍输入已用完）。
    assert Enum.sort(accepted) ==
             Enum.sort([{:eat, @fern}, {:eat, @fern}, {:craft, @switch}, {:craft, @facing}])

    refused =
      Map.new(
        for {key, material, reason} <- results, reason != true, do: {{key, material}, reason}
      )

    assert refused[{:eat, @dandelion}] == :insufficient_material
    assert refused[{:eat, @allium}] == :not_edible
    assert refused[{:eat, @stone}] == :not_edible
    assert refused[{:craft, @masonry}] == :insufficient_material
    assert refused[{:craft, @stone}] == :unknown_recipe
    assert refused[{:craft, @copper}] == :unknown_recipe

    # 都用完：什么都不列。
    assert %{eat: [], craft: []} = World.production_options(w, @cid)
  end

  test "配方输入重复的目录在加载时就被拒绝：逐条比较与合并比较的分歧在产品里做不出来", c do
    duplicate = %{
      @switch => %{
        display_name: "Switch",
        recipe_inputs: [%{material_id: @stone, units: 4096}, %{material_id: @stone, units: 2048}],
        recipe_units: 4096
      }
    }

    path = Path.join(c.root, "duplicate.json")
    File.write!(path, Jason.encode!(catalog(Map.merge(@rows, duplicate))))
    assert_raise MatchError, fn -> Damage.load(path) end
    # 对照：只差这一处的同一份目录（真实的开关配方）可以加载。
    assert %{materials: %{@switch => _}} = Damage.load(c.catalog)
  end
end
