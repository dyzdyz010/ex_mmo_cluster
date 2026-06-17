defmodule SceneServer.Voxel.Reaction.OxidationE2ETest do
  # 功能完善 · 正交架构 S4(化学/氧化):铁→锈端到端——iron 块在常温(>起锈门 0℃)由 ChemicalReactions
  # 的氧化 recipe 驱动:起锈(:rusting)→ 逐 tick 推进 oxidation_progress → 满则相变成 rust。全程纯
  # recipe 数据涌现,无 per-device 规则/coded kernel。并证「化学 × 电磁」经 truth 组合:iron 氧化成 rust
  # (不导电)后自然退出电导投影(锈断路),无任何「锈了断电」规则。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.ReactionKernel
  alias SceneServer.Voxel.Field.ParticipantProjection
  alias SceneServer.Voxel.Field.SystemActor
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

  defp material_at(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.normal_block_at(storage, macro).material_id
  end

  defp oxidation_progress_at(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.effective_attribute_at(storage, macro, "oxidation_progress") / 65_536
  end

  # 同步逐 tick 驱动 ReactionKernel(确定性、隔离;同 circuit_joule_heating e2e 范式)。
  defp drive_reaction(chunk, region, ticks) do
    Enum.reduce(1..ticks, region, fn _i, region ->
      storage = ChunkProcess.debug_state(chunk).storage
      context = KernelContext.new(region, 7, storage, dt_ms: 100)
      {_status, region, effects} = ReactionKernel.tick(region, context, %{})
      {:ok, _} = ChunkProcess.apply_field_effects(chunk, effects, %{})
      region
    end)
  end

  defp single_cell_region(region_id) do
    FieldRegion.new(%{
      region_id: region_id,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {0, 0, 0}},
      kernels: [%{id: :reaction, module: ReactionKernel, opts: %{}}]
    })
  end

  test "iron 常温缓慢氧化成 rust(纯 recipe 数据涌现,无 per-device 规则)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 7, chunk_coord: {0, 0, 0}})
    iron = Types.macro_index!({0, 0, 0})
    iron_id = MaterialCatalog.material_id(:iron)
    rust_id = MaterialCatalog.material_id(:rust)

    {:ok, _} = ChunkProcess.put_solid_block(chunk, iron, NormalBlockData.new(iron_id))
    assert material_at(chunk, iron) == iron_id

    # 起锈门 0℃,默认温度 20℃ ≥ 0℃ → 持续氧化;rate=0.005 → ~200 tick 锈成,驱 220 留余量。
    drive_reaction(chunk, single_cell_region(8801), 220)

    assert material_at(chunk, iron) == rust_id,
           "iron 应缓慢氧化成 rust;实际材料=#{material_at(chunk, iron)} 进度=#{oxidation_progress_at(chunk, iron)}"
  end

  test "惰性材料(stone,起锈门=哨兵)不氧化" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 7, chunk_coord: {0, 0, 0}})
    stone = Types.macro_index!({0, 0, 0})
    stone_id = MaterialCatalog.material_id(:stone)

    {:ok, _} = ChunkProcess.put_solid_block(chunk, stone, NormalBlockData.new(stone_id))

    drive_reaction(chunk, single_cell_region(8802), 220)

    assert material_at(chunk, stone) == stone_id, "惰性 stone 不应氧化"
    assert oxidation_progress_at(chunk, stone) == 0.0, "惰性 stone 氧化进度应为 0"
  end

  test "[化学 × 电磁涌现] iron 氧化成 rust 后退出电导投影(锈断路,无『锈了断电』规则)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 7, chunk_coord: {0, 0, 0}})
    iron = Types.macro_index!({0, 0, 0})
    iron_id = MaterialCatalog.material_id(:iron)
    rust_id = MaterialCatalog.material_id(:rust)

    {:ok, _} = ChunkProcess.put_solid_block(chunk, iron, NormalBlockData.new(iron_id))

    # 氧化前:iron 导电 → 在电导投影里。
    storage_before = ChunkProcess.debug_state(chunk).storage
    projection_before = ParticipantProjection.build(storage_before)
    assert ParticipantProjection.electric_conductive_cell?(projection_before, iron),
           "iron 氧化前应导电(在电导投影内)"

    drive_reaction(chunk, single_cell_region(8803), 220)
    assert material_at(chunk, iron) == rust_id

    # 氧化后:rust(electric_conductivity=0)→ 退出电导投影。这是化学(material 转变)经 committed
    # truth 改变了电磁系统的输入——纯涌现,无任何耦合化学与电的规则。
    storage_after = ChunkProcess.debug_state(chunk).storage
    projection_after = ParticipantProjection.build(storage_after)

    refute ParticipantProjection.electric_conductive_cell?(projection_after, iron),
           "iron 锈成 rust 后应不导电(退出电导投影)→ 涉其电路自然断开"
  end
end
