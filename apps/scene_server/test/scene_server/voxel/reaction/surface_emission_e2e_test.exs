defmodule SceneServer.Voxel.Reaction.SurfaceEmissionE2ETest do
  # 形态轨 · 表面元件层 M5:表面元件物理参与端到端——火炬(ember 材料,heat_output>0)挂在 stone 墙面,
  # 每 tick 向宿主格注热(属性派生、复用 emit_heat 原语),经守恒热扩散传给相邻冷冰 → 熔化。证表面元件是
  # 第一类属性载体、只经 truth 耦合、无 per-element 规则;并与 S1-S4 热/相变涌现组合。负例:rust_decal
  # (无 heat_output)不发热。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.ReactionKernel
  alias SceneServer.Voxel.Field.SystemActor
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.SurfaceCatalog
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

  defp temperature_at(chunk, macro) do
    storage = ChunkProcess.debug_state(chunk).storage
    Storage.effective_attribute_at(storage, macro, "temperature") / 65_536
  end

  defp drive_reaction(chunk, region, ticks) do
    Enum.reduce(1..ticks, region, fn _i, region ->
      storage = ChunkProcess.debug_state(chunk).storage
      context = KernelContext.new(region, 9, storage, dt_ms: 100)
      {_status, region, effects} = ReactionKernel.tick(region, context, %{})
      {:ok, _} = ChunkProcess.apply_field_effects(chunk, effects, %{})
      region
    end)
  end

  defp region(region_id) do
    FieldRegion.new(%{
      region_id: region_id,
      chunk_coord: {0, 0, 0},
      aabb: {{1, 0, 0}, {2, 0, 0}},
      kernels: [%{id: :reaction, module: ReactionKernel, opts: %{}}]
    })
  end

  # 墙 stone(1,0,0)+ 相邻冰(2,0,0)。**受控:墙与冰均起 -10℃**——无热源时扩散无温差不熔(基线干净),
  # 唯一显著热源是火炬表面元件,排除"暖墙扩散熔冰"的混淆。
  defp build_wall_and_ice(chunk) do
    wall = Types.macro_index!({1, 0, 0})
    ice = Types.macro_index!({2, 0, 0})

    {:ok, _} =
      ChunkProcess.put_solid_block(chunk, wall, NormalBlockData.new(MaterialCatalog.material_id(:stone)))

    {:ok, _} =
      ChunkProcess.put_solid_block(chunk, ice, NormalBlockData.new(MaterialCatalog.material_id(:ice)))

    for macro <- [wall, ice] do
      {:ok, _} =
        ChunkProcess.write_temperature_attribute(chunk, %{
          macro_index: macro,
          target_temperature_celsius: -10.0
        })
    end

    {wall, ice}
  end

  test "火炬(ember 热源)挂墙 → 注热宿主 → 守恒扩散熔相邻冷冰(表面元件经 truth 接热/相变)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 9, chunk_coord: {0, 0, 0}})
    {wall, ice} = build_wall_and_ice(chunk)
    ice_id = MaterialCatalog.material_id(:ice)
    water_id = MaterialCatalog.material_id(:water)
    steam_id = MaterialCatalog.material_id(:steam)

    {:ok, _} =
      ChunkProcess.put_surface_element(chunk, %{
        macro_index: wall,
        face: :x_pos,
        surface_type_id: SurfaceCatalog.surface_type_id(:torch)
      })

    assert material_at(chunk, ice) == ice_id

    drive_reaction(chunk, region(9501), 120)

    # 宿主墙被火炬持续注热到高温(证热源是表面元件属性派生,非环境)。
    assert temperature_at(chunk, wall) > 200.0,
           "挂火炬的墙应被表面元件 heat_output 注热到高温;墙温=#{temperature_at(chunk, wall)}℃"

    # 热经守恒扩散熔相邻冷冰(可进而汽化)。
    assert material_at(chunk, ice) in [water_id, steam_id],
           "火炬热经扩散应熔(可进而汽化)相邻冷冰;墙温=#{temperature_at(chunk, wall)}℃ 冰温=#{temperature_at(chunk, ice)}℃ 冰格材料=#{material_at(chunk, ice)}"
  end

  test "负例:rust_decal(无 heat_output)挂墙不发热,冰不熔(属性派生分流)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 9, chunk_coord: {0, 0, 0}})
    {wall, ice} = build_wall_and_ice(chunk)
    ice_id = MaterialCatalog.material_id(:ice)

    {:ok, _} =
      ChunkProcess.put_surface_element(chunk, %{
        macro_index: wall,
        face: :x_pos,
        surface_type_id: SurfaceCatalog.surface_type_id(:rust_decal)
      })

    drive_reaction(chunk, region(9502), 120)

    # rust_decal 无 heat_output → 不注热;墙保持常温区间(扩散本身不造热)。
    assert temperature_at(chunk, wall) < 50.0,
           "rust_decal 不应发热;墙温=#{temperature_at(chunk, wall)}℃"

    assert material_at(chunk, ice) == ice_id, "无热源,相邻冰不应熔化"
  end
end
