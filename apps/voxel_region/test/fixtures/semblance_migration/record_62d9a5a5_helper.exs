# 只测试（Test-only）：拟态迁移夹具的录制器，不在当前分支上运行（_helper.exs 被 mix test 忽略）。
#
# 用途：魔法 v2 去掉了 v1 的“拟态”（semblance），旧存档 thermal.semblances 里仍可能有活着的拟态。
# 决定 Q4-6：恢复时每个旧拟态按旧规则散解，剩余能量 Semblance.stored_j 记入账 semblance_released_j，并删除 thermal.semblances 键。
# 所以用 master 62d9a5a5（Hello 45，魔法 v1）的服务端源码，经正式施法入口（TestSupport.spell → World.spell_intent/3，
# 同 master 自己的 magic_semblance_world_test）录一份 overlay 日志：
#   作者编辑铺地（石 11）与蓄能石 42 → 停机后经持久化边界安装蓄能石 10 MJ 作者初态一次（与 master 拟态世界测试相同；
#   蓄能石储能在 v1 只能由热电回路数小时充电）→ energy.draw 取能 2 MJ（眼睛射线命中蓄能石）
#   → hot_throw 预设斜向下投向石地面（2 kg、2000 K、r 0.4 m、12 m/s，落地有接触）
#   → light_orb 预设手边静止光球（100 W、寿命 120 s，不投掷）→ 显式热提交 3 次（每次 0.5 模拟秒）使热球落地 → 停机。
# 时钟用 master 测试夹具 WorldClock（手动，不推进）：没有墙钟热提交，只有上面 3 次显式提交；不配投射物后端。
# 期望值一律取自停机后按 master 回放方式读出的持久化最后一份 thermal（OverlayLog.File.replay 中最后一条带 :thermal 的事务）。
#
# 复现（WSL；master 源码不放进主检出，用 git archive；Spatial 编译期读同级 Voxim/ 头文件）：
#   B=$HOME/magic-v2-20261126; M=$B/master-fixture
#   mkdir -p $M/ex_mmo_cluster && git -C /mnt/d/hemifuture/ex_mmo_cluster archive 62d9a5a5 | tar -x -C $M/ex_mmo_cluster
#   ln -sfn $B/src/Voxim $M/Voxim; cp -a $B/src/ex_mmo_cluster/deps $M/ex_mmo_cluster/   # mix.lock 与分支相同
#   source $B/env.sh   # PATH、MIX_ENV=test
#   cp record_62d9a5a5_helper.exs $M/ex_mmo_cluster/apps/voxel_region/test/semblance_migration_record_test.exs
#   cd $M/ex_mmo_cluster/apps/voxel_region
#   OUT=<本目录> mix test --no-start test/semblance_migration_record_test.exs
# 输入：master 的 test/fixtures/combustion/b1aca503…json（材料）、environment-radiation.json（热环境），
#   test/fixtures/magic/19c513f9…json（v1 魔法目录）；前两者须与分支 fixtures/combustion/ 同名文件逐字节相同（录制时断言）。
# 输出：overlay.log、world.json（拟态 id、持久化记录、stored_j 及其和、账值），并把 v1 魔法目录拷入本目录（仅作来源记录）。
defmodule VoxelRegion.SemblanceMigrationRecordTest do
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.Magic.Semblance
  alias VoxelRegion.TestSupport.{Actor, Log, Source, WorldClock}

  @master "62d9a5a5"
  @catalog "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @environment "environment-radiation.json"
  @magic "19c513f9ceb29b327ae1f5fb07edcea8e8001adc1a6f938078095e214aceba88"
  @fixtures Path.expand("fixtures", __DIR__)
  @stone 11
  @battery 42
  @cid 1001
  @stone_micro {20, 12, 4}
  @simulation_box {{-2, 0, -2}, {9, 6, 9}}
  @box {{-2, -2, -2}, {2, 2, 2}}

  test "record a master (magic v1) world with a held glowing semblance and a landed hot thrown semblance" do
    out = System.fetch_env!("OUT")
    root = Path.join(System.tmp_dir!(), "semblance_record_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    sources = %{
      properties: Path.join([@fixtures, "combustion", @catalog <> ".json"]),
      environment: Path.join([@fixtures, "combustion", @environment]),
      magic: Path.join([@fixtures, "magic", @magic <> ".json"])
    }

    # 分支复用自己的材料与热环境夹具：必须与本次录制用的字节相同。
    assert File.read!(sources.properties) ==
             File.read!(Path.join([out, "..", "combustion", @catalog <> ".json"]))

    assert File.read!(sources.environment) ==
             File.read!(Path.join([out, "..", "combustion", @environment]))

    File.cp!(sources.properties, Path.join(root, "properties.json"))
    File.cp!(sources.environment, Path.join(root, "environment.json"))
    File.cp!(sources.magic, Path.join(root, "magic.json"))
    clock = start_supervised!({WorldClock, 0})

    start = fn ->
      start_supervised!(
        {World,
         [
           source: Source,
           log: Log,
           root: root,
           observer: self(),
           name: nil,
           clock: {WorldClock, clock},
           property_catalog_path: Path.join(root, "properties.json"),
           thermal_environment_path: Path.join(root, "environment.json"),
           magic_catalog_path: Path.join(root, "magic.json")
         ]},
        id: :world
      )
    end

    a = %{
      cid: @cid,
      gate: self(),
      identity: make_ref(),
      refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5},
      feet: {0.5, 1.0, 0.5},
      tick_us: 16_667
    }

    a = Map.put(a, :player, start_supervised!({Actor, a}, id: :actor))

    w = start.()

    {:ok, _} =
      World.apply_edits(
        w,
        for(x <- -2..8, z <- -2..8, do: {{x, 0, z}, @stone}) ++ [{{2, 1, 0}, @battery}]
      )

    {:ok, row} = World.tool_intent(w, a, query(a, @stone_micro))
    seq = World.seq(w)
    :ok = stop_supervised(:world)

    OverlayLog.File.append(Path.join(root, "overlay.log"), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]
    })

    w = start.()
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    digest = Base.decode16!(@magic, case: :lower)

    presets =
      Map.new(Jason.decode!(File.read!(sources.magic))["presets"], &{&1["id"], &1["program"]})

    draw = %{
      v: 1,
      target: %{kind: "aim"},
      emit: "at_target",
      steps: [%{sym: "energy.draw", args: %{energy_j: 2_000_000}}]
    }

    {:ok, target} = World.tool_intent(w, a, query(a, @stone_micro))

    request =
      Map.merge(
        spell(digest, draw, query(a, @stone_micro).direction),
        Map.take(target, [:micro, :granularity, :incarnation, :owner, :material])
      )

    assert {:ok, %{outcome: nil}} = VoxelRegion.TestSupport.spell(w, stamp(a, 1_000_000), request)

    assert {:ok, %{outcome: nil, seq: thrown}} =
             VoxelRegion.TestSupport.spell(
               w,
               stamp(a, 2_000_000),
               spell(digest, presets["hot_throw"], {0.0, -0.6, 0.8})
             )

    assert {:ok, %{outcome: nil, seq: held}} =
             VoxelRegion.TestSupport.spell(
               w,
               stamp(a, 3_000_000),
               spell(digest, presets["light_orb"], {0.0, 0.0, 1.0})
             )

    for _ <- 1..3,
        do:
          (
            send(w, :thermal_commit)
            VoxelRegion.TestSupport.observe(w, [@cid], @box)
          )

    live = VoxelRegion.TestSupport.observe(w, [@cid], @box)
    assert %{contact: %{cell: {_, 0, _}}, kinetic_j: +0.0} = live.semblances[{thrown, 0}]
    assert %{contact: nil, velocity: {+0.0, +0.0, +0.0}} = live.semblances[{held, 0}]
    final_seq = World.seq(w)
    :ok = stop_supervised(:world)

    log = Path.join(root, "overlay.log")

    thermal =
      OverlayLog.File.replay(log)
      |> Enum.filter(&Map.has_key?(&1, :thermal))
      |> List.last()
      |> Map.fetch!(:thermal)

    # 环境温度同 World（thermal.config["ambient_kelvin"]，来自热环境目录）；持久化记录若带 config 须一致。
    ambient = Jason.decode!(File.read!(sources.environment))["ambient_kelvin"]
    assert get_in(thermal, [Access.key(:config, %{}), "ambient_kelvin"]) in [nil, ambient]
    assert map_size(thermal.semblances) == 2
    assert thermal.semblances[{thrown, 0}].temperature_k > ambient

    rows =
      for {kind, id} <- [held: {held, 0}, thrown: {thrown, 0}] do
        s = Map.fetch!(thermal.semblances, id)

        %{
          id: Tuple.to_list(id),
          kind: kind,
          landed: Semblance.landed?(s),
          contact: inspect(s.contact),
          temperature_k: s.temperature_k,
          age_s: s.age_s,
          stored_j: Semblance.stored_j(s, ambient),
          thermal_j: Semblance.thermal_j(s, ambient),
          kinetic_j: s.kinetic_j,
          glow_j: Semblance.glow_j(s),
          fields: inspect(s, limit: :infinity, printable_limit: :infinity)
        }
      end

    File.cp!(log, Path.join(out, "overlay.log"))
    File.cp!(sources.magic, Path.join(out, @magic <> ".json"))

    File.write!(
      Path.join(out, "world.json"),
      Jason.encode!(
        %{
          recorded_by:
            "ex_mmo_cluster #{@master} (master, Hello 45, magic v1), test/fixtures/semblance_migration/record_62d9a5a5_helper.exs",
          master_commit: @master,
          catalogs: %{
            properties: %{file: "combustion/#{@catalog}.json", sha256: sha256(sources.properties)},
            thermal_environment: %{
              file: "combustion/#{@environment}",
              sha256: sha256(sources.environment)
            },
            magic_v1: %{file: "semblance_migration/#{@magic}.json", sha256: sha256(sources.magic)}
          },
          final_seq: final_seq,
          cid: @cid,
          ambient_kelvin: ambient,
          semblances: rows,
          stored_j_sum: Enum.sum(Enum.map(rows, & &1.stored_j)),
          ledger: %{
            semblance_created_j: Map.get(thermal, :semblance_created_j, 0),
            semblance_released_j: Map.get(thermal, :semblance_released_j, 0)
          }
        },
        pretty: true
      )
    )

    File.rm_rf!(root)
  end

  defp stamp(a, at), do: Map.merge(a, %{received_us: at, clock_node: node()})

  # 手边发出不读眼睛射线目标，目标字段按线格式填 0；取能由调用方覆盖目标字段。
  defp spell(digest, program, direction) do
    seq = System.unique_integer([:positive, :monotonic])

    %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: 1,
      catalog_digest: digest,
      direction: normalize(direction),
      micro: {0, 0, 0},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0,
      semblance: {0, 0},
      program: Jason.encode!(program)
    }
  end

  defp normalize({x, y, z}),
    do:
      (
        n = :math.sqrt(x * x + y * y + z * z)
        {x / n, y / n, z / n}
      )

  defp query(a, {x, y, z} = micro) do
    {ex, ey, ez} = a.eye
    seq = System.unique_integer([:positive, :monotonic])

    %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: normalize({(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}),
      micro: micro,
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }
  end

  defp sha256(path), do: Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower)
end
