defmodule SceneServer.Voxel.Reaction.LightTruthE2ETest do
  # 光学正交系统 e2e(光成真机制,**全 DB 路径**):ember 光源 + 相邻 photo_sensor 在真实
  # ChunkProcess 中,经 FieldTickWorker → [LightPropagationKernel 写 :light 层 →
  # ReactionKernel 读 :light gate 光敏] → SystemActor → ChunkProcess,把 :illuminated tag
  # **落进实际 chunk truth**。这是「光改世界态」最强证据:光真正 mutate 了权威 truth。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.{FieldRegion, FieldTickWorker, SystemActor}
  alias SceneServer.Voxel.Field.Kernels.{LightPropagationKernel, ReactionKernel}
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.TagCatalog
  alias SceneServer.Voxel.Types

  setup do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    Application.delete_env(:scene_server, :cli_observe_log)

    for cat <- [AttributeCatalog, TagCatalog] do
      case start_supervised({cat, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    SceneServer.TestVoxelRuntime.ensure_started!()
    SystemActor.reset()

    on_exit(fn ->
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end)

    :ok
  end

  # 跑一次 [光传播, 反应] field tick(光 kernel 排反应前——同 tick region 线程光层先写后读)。
  defp run_light_reaction_tick(chunk, region_id, aabb) do
    region =
      FieldRegion.new(%{
        region_id: region_id,
        chunk_coord: {0, 0, 0},
        aabb: aabb,
        kernels: [
          %{id: :light_propagation, module: LightPropagationKernel, opts: %{}},
          %{id: :reaction, module: ReactionKernel, opts: %{}}
        ],
        max_ticks: 1
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 1,
        tick_interval_ms: 1
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  defp cell_material(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage

    case Storage.normal_block_at(storage, macro) do
      %NormalBlockData{material_id: id} -> id
      _ -> nil
    end
  end

  defp cell_temperature(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.effective_attribute_at(storage, macro, "temperature") / 65_536
  end

  defp blocking?(chunk, macro) do
    {:ok, result} =
      ChunkProcess.collision_query(chunk, %{samples: [%{macro: macro, micro_slot: 0}]})

    result.occupied_count > 0
  end

  # 读某 cell 在 truth 中的 tag 名集合。
  defp cell_tags(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage

    case Storage.normal_block_at(storage, macro) do
      %NormalBlockData{tag_set_ref: ref} when ref > 0 ->
        case Enum.at(storage.tag_sets, ref - 1) do
          %{tag_ids: ids} ->
            Enum.map(ids, fn id ->
              case TagCatalog.lookup_by_id(id) do
                {:ok, %{name: name}} -> name
                _ -> nil
              end
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  test "光成真机制(全 DB):ember 光照亮相邻 photo_sensor → :illuminated 落 chunk truth" do
    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {0, 0, 0}, auto_field_provisioning: false}
      )

    ember = Types.macro_index!({0, 0, 0})
    sensor = Types.macro_index!({1, 0, 0})

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        ember,
        NormalBlockData.new(MaterialCatalog.material_id(:ember))
      )

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        sensor,
        NormalBlockData.new(MaterialCatalog.material_id(:photo_sensor))
      )

    # 初始:未照亮。
    refute "illuminated" in cell_tags(chunk, sensor)

    # 光传播 + 反应 tick → photo_sensor 被 ember 光照亮 → :illuminated 落 truth。
    run_light_reaction_tick(chunk, 9701, {{0, 0, 0}, {1, 0, 0}})

    assert "illuminated" in cell_tags(chunk, sensor),
           "ember 光经权威光场照亮 photo_sensor → :illuminated 真正落进 chunk truth(光改世界态)"
  end

  test "遮光(全 DB):不透明墙挡光 → photo_sensor 不被点亮(truth 无 :illuminated)" do
    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {0, 0, 0}, auto_field_provisioning: false}
      )

    ember = Types.macro_index!({0, 0, 0})
    wall = Types.macro_index!({1, 0, 0})
    sensor = Types.macro_index!({2, 0, 0})

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        ember,
        NormalBlockData.new(MaterialCatalog.material_id(:ember))
      )

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        wall,
        NormalBlockData.new(MaterialCatalog.material_id(:stone))
      )

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        sensor,
        NormalBlockData.new(MaterialCatalog.material_id(:photo_sensor))
      )

    run_light_reaction_tick(chunk, 9702, {{0, 0, 0}, {2, 0, 0}})

    refute "illuminated" in cell_tags(chunk, sensor),
           "不透明墙后 photo_sensor 不被照亮 → truth 无 :illuminated(遮光正确)"
  end

  test "光门(全 DB):光照打开 photo_sensor 闸门(可通行)—— 与电门完全对称" do
    # 光 → :illuminated(tick1)→ 光门执行器置 :open(tick2)→ TagPhysics 视为可通行。
    # 证「光」是一等 device trigger,纯数据组合复用整套 actuator/passability(同电门 :powered→:open)。
    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {0, 0, 0}, auto_field_provisioning: false}
      )

    ember = Types.macro_index!({0, 0, 0})
    gate = Types.macro_index!({1, 0, 0})

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        ember,
        NormalBlockData.new(MaterialCatalog.material_id(:ember))
      )

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        gate,
        NormalBlockData.new(MaterialCatalog.material_id(:photo_sensor))
      )

    # 初始:实心闸门阻挡。
    assert blocking?(chunk, gate)

    # tick1:光 → :illuminated。tick2::illuminated → 光门 :open。
    run_light_reaction_tick(chunk, 9801, {{0, 0, 0}, {1, 0, 0}})
    run_light_reaction_tick(chunk, 9802, {{0, 0, 0}, {1, 0, 0}})

    assert "illuminated" in cell_tags(chunk, gate)
    assert "open" in cell_tags(chunk, gate)

    refute blocking?(chunk, gate),
           "光照打开 photo_sensor 闸门 → 碰撞视为可通行(光→:illuminated→:open→passable 全链落 truth)"
  end

  test "光合(全 DB):sprout 幼苗在光照+相邻水下生长 → 成熟为 wood(光长生命,三系统组合)" do
    # 布局:ember(光源,0)— sprout(1)— water(2)。sprout 受光(0→1)且相邻水(2)→ 光合生长。
    # 组合权威光场 × 多反应物(相邻水)× 生长进度累进/transform。光是有状态多 tick 生长过程的真机制。
    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {0, 0, 0}, auto_field_provisioning: false}
      )

    ember = Types.macro_index!({0, 0, 0})
    sprout = Types.macro_index!({1, 0, 0})
    water = Types.macro_index!({2, 0, 0})

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        ember,
        NormalBlockData.new(MaterialCatalog.material_id(:ember))
      )

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        sprout,
        NormalBlockData.new(MaterialCatalog.material_id(:sprout))
      )

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        water,
        NormalBlockData.new(MaterialCatalog.material_id(:water))
      )

    assert cell_material(chunk, sprout) == MaterialCatalog.material_id(:sprout)

    # 多 tick 光合(rate 0.05 → ~20 tick 成熟)。跑到成熟或 30 tick 上限。
    wood_id = MaterialCatalog.material_id(:wood)

    matured? =
      Enum.reduce_while(1..30, false, fn i, _acc ->
        run_light_reaction_tick(chunk, 9900 + i, {{0, 0, 0}, {2, 0, 0}})

        if cell_material(chunk, sprout) == wood_id do
          {:halt, true}
        else
          {:cont, false}
        end
      end)

    assert matured?, "sprout 在光照+相邻水下持续光合 growth_progress 累进满 → 成熟为 wood(光长生命)"
    assert cell_material(chunk, sprout) == wood_id
  end

  test "光→热桥(全 DB,放大镜效应):强光照 photo_sensor → 自身温度在 truth 中升高(光桥接热系统)" do
    # ember 强光(相邻 178 ≥ 128 放热阈)照 photo_sensor → 吸光放热 → 自身温度升。光→热→(扩散)熔/燃。
    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {0, 0, 0}, auto_field_provisioning: false}
      )

    ember = Types.macro_index!({0, 0, 0})
    sensor = Types.macro_index!({1, 0, 0})

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        ember,
        NormalBlockData.new(MaterialCatalog.material_id(:ember))
      )

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        sensor,
        NormalBlockData.new(MaterialCatalog.material_id(:photo_sensor))
      )

    initial_temp = cell_temperature(chunk, sensor)

    # 数 tick 太阳能加热(光→emit_heat → ChunkProcess 注热升温)。
    for i <- 1..5 do
      run_light_reaction_tick(chunk, 9950 + i, {{0, 0, 0}, {1, 0, 0}})
    end

    final_temp = cell_temperature(chunk, sensor)

    assert final_temp > initial_temp + 50.0,
           "强光照 photo_sensor 吸光放热 → 温度显著升(光→热落 truth);#{initial_temp}→#{final_temp}℃"
  end
end
