defmodule SceneServer.Voxel.Reaction.OrganicHeatDiffuseE2ETest do
  # 世界内容驱动场 provisioning · 生产 e2e(step5,热半程):在**真 ChunkProcess**(auto
  # provisioning 默认开)里挂一个**火炬表面元件**(借 ember 材料,本征热源 heat_output>0),
  # **有机地**:Emergence provisioner 扫 surface_elements 检出火炬 → 起
  # [temperature_diffusion, light_propagation, reaction] region(本地 AABB)→ ReactionKernel
  # 注火炬 heat_output 到宿主格 → TemperatureDiffusionKernel 把热铺到相邻惰性格 → 相邻
  # 格 truth 温度升高。证明组织玩法里「挂火炬 → 热自发扩散」(无手动起 worker、无 dev
  # 端点),热场与光/反应同 region 跑。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.SystemActor
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.SurfaceCatalog
  alias SceneServer.Voxel.TagCatalog
  alias SceneServer.Voxel.Types

  @ambient_celsius 20.0

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

  test "有机热扩散:挂火炬 → Emergence 起含温度扩散的 region → 宿主与相邻格温度自发升高" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    host = Types.macro_index!({1, 0, 0})
    neighbor = Types.macro_index!({2, 0, 0})

    # 火炬宿主须实心(挂墙);相邻放一块惰性 stone 当「被加热体」(导热、不反应)。
    for macro <- [host, neighbor] do
      {:ok, _} =
        ChunkProcess.put_solid_block(
          chunk,
          macro,
          NormalBlockData.new(MaterialCatalog.material_id(:stone))
        )
    end

    # 初始:宿主与相邻都在环境温度附近。
    assert cell_temperature(chunk, host) <= @ambient_celsius + 0.5
    assert cell_temperature(chunk, neighbor) <= @ambient_celsius + 0.5

    # 挂火炬(surface_type torch → 借 ember 材料,heat_output>0)。表面元件放置触发
    # provisioning sweep → Emergence 扫 surface_elements 检出 → 起含温度扩散的 region。
    {:ok, _} =
      ChunkProcess.put_surface_element(chunk, %{
        macro_index: host,
        face: :z_pos,
        surface_type_id: SurfaceCatalog.surface_type_id(:torch)
      })

    # 有机跑(SimRuntime 10Hz 驱动 auto region):火炬注热宿主 → 宿主升温。
    assert poll_until(fn -> cell_temperature(chunk, host) > @ambient_celsius + 5.0 end, 15_000),
           "火炬宿主格应被有机注热升温 > 环境+5℃;实际 #{cell_temperature(chunk, host)}℃"

    # 温度扩散:热从宿主铺到相邻惰性 stone(temperature_diffusion 真在 region 内跑)。
    assert poll_until(
             fn -> cell_temperature(chunk, neighbor) > @ambient_celsius + 1.0 end,
             15_000
           ),
           "相邻 stone 应被温度扩散有机加热 > 环境+1℃;实际 #{cell_temperature(chunk, neighbor)}℃"

    # region 真起来了(含温度扩散的涌现 region)。
    assert ChunkProcess.debug_state(chunk).field_region_count == 1
  end

  defp cell_temperature(chunk, macro_index) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.effective_attribute_at(storage, macro_index, "temperature") / 65_536
  end

  defp poll_until(fun, timeout_ms, waited \\ 0) do
    cond do
      fun.() ->
        true

      waited >= timeout_ms ->
        false

      true ->
        Process.sleep(50)
        poll_until(fun, timeout_ms, waited + 50)
    end
  end
end
