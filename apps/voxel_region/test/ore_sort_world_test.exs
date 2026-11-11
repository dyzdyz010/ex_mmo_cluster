defmodule VoxelRegion.OreSortWorldTest do
  @moduledoc """
  只测试：Items 增量 1 混合矿与徒手分选（Voxim `Docs/Items.md` §3，冻结契约 2026-11-09）的 World 侧，经真实 World 入口。

  目录 = UE 发布字节 f105c1bb（`fixtures/items/`，原样复制、按 sha256 核对）加 Test-only 夹具行：贫铜矿 89、富铜矿 90、
  工具 24 `ore.sort` 与同名标签。混合矿除成分外的物理参数按成分从铜精矿 16（密度 4200、热容 21360、导热 25、耐热 1600）
  与砾石 6（1600、15437、12.35、1000）按单位加权手算、取整写入（作者脚本是正式来源，这里只为让行完整）：

      贫 89 = {16: 205, 6: 3891}：密度 (4200·205 + 1600·3891)/4096 = 7086600/4096 ≈ 1730；热容 64444167/4096 ≈ 15733；
             导热 53178.85/4096 ≈ 12.98；耐热 4219000/4096 ≈ 1030
      富 90 = {16: 1229, 6: 2867}：密度 9749000/4096 ≈ 2380；热容 70509319/4096 ≈ 17214；导热 66132.45/4096 ≈ 16.15；
             耐热 4833400/4096 ≈ 1180

  没有 drops（镐采入账矿本身）、没有冶炼规则（混合矿不进炉）。余额只经 Test-only 供料入口 `material_supply/4` 一次写入；
  分选经 Player 发给 World 的同一对消息（本进程扮 Player）。期望的独立依据：一份 = 每微格 4096 单位，成分即冻结契约整数。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Log, Source, WorldClock}

  @digest "f105c1bb718e039347a66d4fc8507b77be2a03a8272766bc7658cfd80664ae29"
  @fixtures Path.expand("fixtures", __DIR__)
  @gravel 6
  @stone 11
  @copper_concentrate 16
  @lean 89
  @rich 90
  @sort 24
  @pick 1
  @a 1001
  @b 1002

  @responses [
    %{"action" => "damage", "multiplier" => 1},
    %{"action" => "damage.impact", "multiplier" => 1},
    %{"action" => "damage.impact.pick", "multiplier" => 1}
  ]
  @ore %{
    "loose_threshold_units" => 1_572_864,
    "tags" => ["material.ore"],
    "max_hp_per_macro" => 100,
    "defense" => 8,
    "responses" => @responses
  }
  @lean_row Map.merge(@ore, %{
              "material_id" => @lean,
              "display_name" => "贫铜矿",
              "density_kg_m3" => 1730,
              "heat_capacity_per_macro" => 15733,
              "thermal_conductivity" => 12.98,
              "heat_resistance_kelvin" => 1030,
              "composition" => [
                %{"material_id" => 16, "units" => 205},
                %{"material_id" => 6, "units" => 3891}
              ]
            })
  @rich_row Map.merge(@ore, %{
              "material_id" => @rich,
              "display_name" => "富铜矿",
              "density_kg_m3" => 2380,
              "heat_capacity_per_macro" => 17214,
              "thermal_conductivity" => 16.15,
              "heat_resistance_kelvin" => 1180,
              "composition" => [
                %{"material_id" => 16, "units" => 1229},
                %{"material_id" => 6, "units" => 2867}
              ]
            })
  @tool %{"tool_id" => @sort, "id" => "ore.sort", "display_name" => "徒手分选", "action" => "ore.sort", "windup_base_s" => 3}

  setup do
    root = Path.join(System.tmp_dir!(), "ore_sort_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    bytes = File.read!(Path.join(@fixtures, "items/#{@digest}.json"))
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == @digest
    base = Jason.decode!(bytes)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(with_ores(base, @lean_row, @rich_row)))

    File.cp!(
      Path.join(@fixtures, "combustion/environment-radiation.json"),
      Path.join(root, "environment.json")
    )

    File.mkdir_p!(Path.join(root, "prefabs"))
    clock = start_supervised!({WorldClock, 0})
    %{root: root, catalog: catalog, clock: clock, base: base}
  end

  defp with_ores(base, lean, rich) do
    %{
      base
      | "materials" => base["materials"] ++ [lean, rich],
        "tools" => base["tools"] ++ [@tool],
        "tags" => base["tags"] ++ [%{"id" => "ore.sort", "display_name" => "分选"}]
    }
  end

  defp start(c) do
    opts = [
      source: Source,
      log: Log,
      clock: {WorldClock, c.clock},
      root: c.root,
      observer: self(),
      name: nil,
      property_catalog_path: c.catalog,
      thermal_environment_path: Path.join(c.root, "environment.json"),
      prefab_catalog_path: Path.join(c.root, "prefabs"),
      production_materials: [@gravel, @stone, @copper_concentrate, @lean, @rich]
    ]

    start_supervised!({World, opts}, id: :world)
  end

  defp restart(c),
    do:
      (
        :ok = stop_supervised(:world)
        start(c)
      )

  defp balances(w, cid), do: Map.new(World.material_balances(w, cid), &{&1.material, &1.balance})

  # 本进程扮 Player：开始校验回读条秒数，结束校验整笔提交回事务 seq。
  defp sort(w, message, cid, material, tool \\ @sort) do
    key = make_ref()
    seq = System.unique_integer([:positive, :monotonic])

    request = %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: 6,
      coord: {0, 0, 0},
      tool_id: tool,
      material: material
    }

    send(w, {message, key, %{cid: cid, player: self()}, request})
    reply = if message == :prepare_sort, do: :sort_prepared, else: :sort_committed
    assert_receive {^reply, ^key, result}, 5_000
    result
  end

  test "目录：混合矿成分按冻结契约加载；和 ≠ 4096、成分是自身、成分不存在、重复、空表、非正整数均拒绝", c do
    properties = VoxelRegion.Damage.load(c.catalog)

    assert properties.materials[@lean]["composition"] == [
             %{"material_id" => 16, "units" => 205},
             %{"material_id" => 6, "units" => 3891}
           ]

    assert properties.materials[@rich]["composition"] == [
             %{"material_id" => 16, "units" => 1229},
             %{"material_id" => 6, "units" => 2867}
           ]

    assert properties.tools[@sort] == @tool
    # 和恰为每微格单位（独立核对：205 + 3891 = 1229 + 2867 = 4096）。
    assert VoxelRegion.Damage.material_units(properties) == 4096
    refute Map.has_key?(properties.materials[@copper_concentrate], "composition")

    bad = fn composition ->
      path = Path.join(c.root, "bad_#{System.unique_integer([:positive])}.json")

      File.write!(
        path,
        Jason.encode!(with_ores(c.base, %{@lean_row | "composition" => composition}, @rich_row))
      )

      path
    end

    for composition <- [
          [%{"material_id" => 16, "units" => 205}, %{"material_id" => 6, "units" => 3890}],
          [%{"material_id" => 16, "units" => 206}, %{"material_id" => 6, "units" => 3891}],
          [%{"material_id" => @lean, "units" => 205}, %{"material_id" => 6, "units" => 3891}],
          [%{"material_id" => 999, "units" => 205}, %{"material_id" => 6, "units" => 3891}],
          [%{"material_id" => 0, "units" => 205}, %{"material_id" => 6, "units" => 3891}],
          [%{"material_id" => 6, "units" => 205}, %{"material_id" => 6, "units" => 3891}],
          [%{"material_id" => 16, "units" => 0}, %{"material_id" => 6, "units" => 4096}],
          [%{"material_id" => 16, "units" => 205.0}, %{"material_id" => 6, "units" => 3891}],
          []
        ] do
      assert_raise MatchError, fn -> VoxelRegion.Damage.load(bad.(composition)) end
    end
  end

  test "分选一份：贫铜矿 −4096／铜精矿 +205／砾石 +3891，富铜矿 −4096／+1229／+2867；零头保留，各材料单位和守恒，重启后不变", c do
    w = start(c)
    {:ok, _} = World.material_supply(w, @a, "fixture", %{@lean => 2 * 4096 + 7, @rich => 4096})
    before = balances(w, @a)

    assert before == %{
             @gravel => 0,
             @stone => 0,
             @copper_concentrate => 0,
             @lean => 8199,
             @rich => 4096
           }

    seq = World.seq(w)

    assert {:ok, 3} = sort(w, :prepare_sort, @a, @lean)
    assert World.seq(w) == seq and balances(w, @a) == before
    assert {:ok, lean_seq} = sort(w, :commit_sort, @a, @lean)
    assert lean_seq == seq + 1 and World.seq(w) == lean_seq

    assert balances(w, @a) == %{
             @gravel => 3891,
             @stone => 0,
             @copper_concentrate => 205,
             @lean => 4103,
             @rich => 4096
           }

    assert {:ok, 3} = sort(w, :prepare_sort, @a, @rich)
    assert {:ok, rich_seq} = sort(w, :commit_sort, @a, @rich)
    assert rich_seq == lean_seq + 1
    after_sort = balances(w, @a)

    assert after_sort == %{
             @gravel => 3891 + 2867,
             @stone => 0,
             @copper_concentrate => 205 + 1229,
             @lean => 4103,
             @rich => 0
           }

    assert Enum.sum(Map.values(after_sort)) == Enum.sum(Map.values(before))
    # 别的角色不受影响。
    assert Enum.all?(balances(w, @b), fn {_, units} -> units == 0 end)

    w = restart(c)
    assert balances(w, @a) == after_sort
    assert World.seq(w) == rich_seq
  end

  test "拒绝：不足一份（4095）、非混合矿、非分选工具，余额与事务序号不变", c do
    w = start(c)

    {:ok, _} =
      World.material_supply(w, @a, "fixture", %{
        @lean => 4095,
        @copper_concentrate => 8192,
        @rich => 4096
      })

    before = balances(w, @a)
    seq = World.seq(w)

    for message <- [:prepare_sort, :commit_sort] do
      assert {:error, :insufficient_material} = sort(w, message, @a, @lean)
      assert {:error, :not_sortable} = sort(w, message, @a, @copper_concentrate)
      assert {:error, :not_sortable} = sort(w, message, @a, @stone)
      assert {:error, :invalid_tool} = sort(w, message, @a, @rich, @pick)
    end

    assert balances(w, @a) == before
    assert World.seq(w) == seq
  end

  # 分选工具没有射程：放置按射程取工具时不能借它（去掉 build_material 的射程保护，World 会在 build_reach 算术处崩溃，已反向验证）；
  # 附件入口在 attachment_intent 的 tool_range 预检就拒绝，这里只证明公共入口行为。
  test "分选工具不能用于放置或装附件", c do
    w = start(c)
    {:ok, _} = World.material_supply(w, @a, "fixture", %{@stone => 4096 * 512})

    actor = %{
      cid: @a,
      gate: self(),
      identity: make_ref(),
      refresh: &VoxelRegion.TestSupport.Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5},
      position: {0.5, 2.5, 0.5},
      tick_us: 16_667
    }

    actor = Map.put(actor, :player, start_supervised!({VoxelRegion.TestSupport.Actor, actor}))
    seq = World.seq(w)

    build = %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 1,
      action: 1,
      coord: {0, 1, 0},
      tool_id: @sort,
      material: @stone
    }

    assert {:error, :invalid_tool} = World.production_intent(w, actor, build)

    assert {:ok, _} =
             World.production_intent(w, actor, %{
               build
               | request_id: 2,
                 client_intent_seq: 2,
                 tool_id: @pick
             })

    assert World.seq(w) == seq + 1

    # 附件：同一请求形状（取自 area_tool_world_test），拒绝发生在取工具处，不扣料、不推进事务。
    before = balances(w, @a)
    seq = World.seq(w)

    attach = %{
      request_id: 3,
      client_intent_seq: 3,
      logical_scene_id: 1,
      action: 0,
      kind: 0,
      axis: 0,
      size: 8,
      anchor: {16, 8, 0},
      id: 0,
      material: @stone,
      tool_id: @sort
    }

    assert {:error, :invalid_tool} = World.attachment_intent(w, actor, attach)
    assert World.seq(w) == seq
    assert balances(w, @a) == before
  end

  # 工具 24 没有 power／range_macro／interval_seconds（此前每个工具都有）。客户端能在任何工具意图里写任意 tool_id，
  # 所以挖掘（g0）与范围段（g6）这两个世界入口必须拒绝它，而不是在算术处使 World 崩溃。
  # 人物射线（g5）不在这里测：真实入口 `SceneServer.Movement.ToolAction` 要求工具带 body_impact（工具 24 没有），
  # 在到达 `World.body_tool` 之前就回 :unsupported_body_tool；直接调 `World.body_tool` 绕过了该边界（试过：会在
  # world.ex 的 interval 算术处崩溃），不是客户端可达路径，故不为它加防御。
  test "分选工具不能用于挖掘或范围段", c do
    w = start(c)

    actor = %{
      cid: @a,
      gate: self(),
      identity: make_ref(),
      refresh: &VoxelRegion.TestSupport.Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5},
      position: {0.5, 2.5, 0.5},
      life_generation: 1,
      tick_us: 16_667,
      yaw: 0,
      received_us: 1_000_000,
      clock_node: node()
    }

    actor = Map.put(actor, :player, start_supervised!({VoxelRegion.TestSupport.Actor, actor}))
    seq = World.seq(w)

    dig = %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 1,
      action: 1,
      granularity: 0,
      direction: {1.0, 0.0, 0.0},
      micro: {0, 0, 0},
      incarnation: 0,
      owner: {0, 0},
      material: 0,
      tool_id: @sort
    }

    for granularity <- [0, 6] do
      assert {:error, :invalid_tool} = World.tool_intent(w, actor, %{dig | granularity: granularity})
    end

    assert Process.alive?(w) and World.seq(w) == seq
  end

  test "开始校验不预扣或预占；结算时余额不足则整笔拒绝，不重复发产物", c do
    w = start(c)
    {:ok, _} = World.material_supply(w, @a, "fixture", %{@lean => 4096})
    assert {:ok, 3} = sort(w, :prepare_sort, @a, @lean)
    assert {:ok, 3} = sort(w, :prepare_sort, @a, @lean)
    assert {:ok, seq} = sort(w, :commit_sort, @a, @lean)
    expected = %{@gravel => 3891, @stone => 0, @copper_concentrate => 205, @lean => 0, @rich => 0}
    assert balances(w, @a) == expected
    assert {:error, :insufficient_material} = sort(w, :commit_sort, @a, @lean)
    assert World.seq(w) == seq
    assert balances(w, @a) == expected
  end

  test "分选日志写入失败不扣矿、不入任何产物、不推进事务；冷恢复与重试保持整笔守恒", c do
    w = start(c)
    {:ok, _} = World.material_supply(w, @a, "fixture", %{@rich => 4096 + 7})
    before = balances(w, @a)
    seq = World.seq(w)
    assert {:ok, 3} = sort(w, :prepare_sort, @a, @rich)
    # 复用现有日志夹具的写入故障入口，不修改 World 私有状态。
    reject = Log.open(c.root, World.content_version(w)) <> ".reject"
    File.write!(reject, "reject")
    assert {:error, :test_disk_failure} = sort(w, :commit_sort, @a, @rich)
    assert World.seq(w) == seq
    assert balances(w, @a) == before
    File.rm!(reject)

    w = restart(c)
    assert World.seq(w) == seq
    assert balances(w, @a) == before
    assert {:ok, next} = sort(w, :commit_sort, @a, @rich)
    assert next == seq + 1
    after_sort = balances(w, @a)

    assert after_sort == %{
             @gravel => 2867,
             @stone => 0,
             @copper_concentrate => 1229,
             @lean => 0,
             @rich => 7
           }

    assert Enum.sum(Map.values(after_sort)) == Enum.sum(Map.values(before))
    w = restart(c)
    assert World.seq(w) == next
    assert balances(w, @a) == after_sort
  end
end
