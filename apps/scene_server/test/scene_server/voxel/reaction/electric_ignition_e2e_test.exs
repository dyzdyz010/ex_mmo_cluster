defmodule SceneServer.Voxel.Reaction.ElectricIgnitionE2ETest do
  # 功能完善 · 反应层 R6c:电→火跨系统涌现端到端——导电 kernel 把 Joule 热写回 truth 加热导电铁,反应
  # kernel(同 region)守恒热扩散把铁的热传给相邻木 → 木达 ignition 点燃。证电+热扩散+燃烧组合涌现。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.{FieldRegion, FieldTickWorker, SystemActor}
  alias SceneServer.Voxel.Field.Kernels.{ConductionPathKernel, ReactionKernel}
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

  defp burning_id, do: with({:ok, id, _} <- TagCatalog.lookup_by_name("burning"), do: id)

  defp burning?(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    block = Storage.normal_block_at(storage, macro)

    case block.tag_set_ref do
      0 -> false
      ref -> burning_id() in Enum.at(storage.tag_sets, ref - 1).tag_ids
    end
  end

  defp temperature_at(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.effective_attribute_at(storage, macro, "temperature") / 65_536
  end

  test "电→火:导电加热铁 → 铁热扩散点燃相邻木(跨系统涌现)" do
    # 手动建 region + 自驱(下方 FieldTickWorker),关掉 auto field provisioning:本测专注
    # 电→热→燃烧链,不要正交的力学坍塌 provisioner 介入(导电把作地锚的源铁烧熔成 molten_iron
    # 即 structural=0,会令其上木块失支撑坍塌——那是另一条合理涌现链,但会干扰本测点火断言)。
    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 7, chunk_coord: {0, 0, 0}, auto_field_provisioning: false}
      )
    source = Types.macro_index!({0, 0, 0})
    iron_target = Types.macro_index!({1, 0, 0})
    wood = Types.macro_index!({0, 1, 0})

    iron = MaterialCatalog.material_id(:iron)

    # 导电铁(源 + 靶,相邻)被导电 Joule 加热;相邻可燃木受铁热扩散。沿用 field_tick_worker 导电热设置。
    {:ok, _} = ChunkProcess.put_solid_block(chunk, source, NormalBlockData.new(iron))
    {:ok, _} = ChunkProcess.put_solid_block(chunk, iron_target, NormalBlockData.new(iron))

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        wood,
        NormalBlockData.new(MaterialCatalog.material_id(:wood))
      )

    refute burning?(chunk, wood)

    region =
      FieldRegion.new(%{
        region_id: 9401,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {1, 1, 0}},
        kernels: [
          %{
            id: :conduction_path,
            module: ConductionPathKernel,
            opts: %{
              target_macro_index: iron_target,
              max_frontier: 32,
              power_source: %{
                output_mode: :dc,
                voltage: 120.0,
                current_limit_amps: 20.0,
                load_current_amps: 20.0
              },
              # R6 调平后的 production 电热增益(= field_source @conduction_heat_response_gain 1e9),
              # 验证"电→火"在生产默认值下成立(持续导电加热铁→热扩散点燃相邻木)。
              thermal_coupling: %{enabled: true, joule_scale: 1.0e9}
            }
          },
          %{id: :reaction, module: ReactionKernel, opts: %{}}
        ],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}],
        max_ticks: 30
      })

    {:ok, pid} =
      FieldTickWorker.start_link(
        region: region,
        chunk_pid: chunk,
        storage_fn: fn -> ChunkProcess.debug_state(chunk).storage end,
        logical_scene_id: 7,
        tick_interval_ms: 1
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 30_000

    assert burning?(chunk, wood),
           "导电加热的铁应经热扩散点燃相邻木(电→火);铁温=#{temperature_at(chunk, source)}℃ 木温=#{temperature_at(chunk, wood)}℃"
  end
end
