defmodule SceneServer.Voxel.Reaction.CircuitJouleHeatingE2ETest do
  # 功能完善 · 正交架构 S1(电磁):I²R 焦耳热端到端——搭一个真实闭环电路(电源 + 导体 + 高电阻
  # 发热负载 electric_load),CircuitCurrentKernel 按 I²R 对载流的发热负载注热(无 powered_heater
  # 规则),热经 ReactionKernel 守恒扩散传给相邻冷冰 → 冰升过 0℃ 熔为水。证「载流 × 电阻 → 热」
  # 的物理涌现替代了凭空断言的加热器规则。受控:冰起于 -10℃,唯一显著能量源是 I²R(负载升至高温)。
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext, SystemActor}
  alias SceneServer.Voxel.Field.Kernels.{CircuitCurrentKernel, ReactionKernel}
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  setup do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    Application.delete_env(:scene_server, :cli_observe_log)

    for cat <- [AttributeCatalog, SceneServer.Voxel.TagCatalog] do
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

  defp set_temperature(chunk, macro, celsius) do
    {:ok, _} =
      ChunkProcess.write_temperature_attribute(chunk, %{
        macro_index: macro,
        target_temperature_celsius: celsius
      })
  end

  # 闭环电路:电源(power_block)→ 导体(iron)环 → 发热负载(electric_load,2,0,0)→ 导体环回电源。
  defp circuit_blocks do
    [
      {{0, 0, 0}, :power_block},
      {{1, 0, 0}, :iron},
      {{2, 0, 0}, :electric_load},
      {{2, 1, 0}, :iron},
      {{2, 2, 0}, :iron},
      {{1, 2, 0}, :iron},
      {{0, 2, 0}, :iron},
      {{0, 1, 0}, :iron}
    ]
  end

  test "I²R 焦耳热:闭环载流的高电阻负载发热 → 热扩散熔化相邻冷冰(无 powered_heater 规则)" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 7, chunk_coord: {0, 0, 0}})

    for {coord, material} <- circuit_blocks() do
      {:ok, _} =
        ChunkProcess.put_solid_block(
          chunk,
          Types.macro_index!(coord),
          NormalBlockData.new(MaterialCatalog.material_id(material))
        )
    end

    load = Types.macro_index!({2, 0, 0})
    ice = Types.macro_index!({3, 0, 0})
    ice_id = MaterialCatalog.material_id(:ice)
    water_id = MaterialCatalog.material_id(:water)
    steam_id = MaterialCatalog.material_id(:steam)

    {:ok, _} = ChunkProcess.put_solid_block(chunk, ice, NormalBlockData.new(ice_id))

    # 受控:冰起 -10℃,扩散本身不熔(R3 已证);唯一显著能量源是发热负载的 I²R。
    set_temperature(chunk, ice, -10.0)

    assert material_at(chunk, ice) == ice_id

    region =
      FieldRegion.new(%{
        region_id: 7701,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {3, 2, 0}},
        kernels: [
          %{id: :circuit_current, module: CircuitCurrentKernel},
          %{id: :reaction, module: ReactionKernel, opts: %{}}
        ],
        source_points: [
          %{
            macro_index: Types.macro_index!({0, 0, 0}),
            field_type: :electric_potential,
            value: 120.0
          }
        ]
      })

    # 同步逐 tick 驱动(确定性、隔离):每 tick 以当前 truth 快照跑 CircuitCurrentKernel(发 I²R 热)
    # + ReactionKernel(守恒扩散 + 相变规则),合并效果直接 apply 到本 chunk。刻意不经异步
    # FieldTickWorker + 节点级共享 SystemActor——后者在全套并发下会被其他测试泄漏的 worker 争用/污染
    # (commit 丢失),使本积分测试 order-flaky;同步驱动复现同一物理链路而无共享态竞争。
    Enum.reduce(1..80, region, fn _i, region ->
      # 电路:以当前 truth 算 I²R 热并提交(单独 apply,让热先落 truth)。
      circuit_storage = ChunkProcess.debug_state(chunk).storage
      circuit_context = KernelContext.new(region, 7, circuit_storage, dt_ms: 100)
      {_status, region, circuit_effects} = CircuitCurrentKernel.tick(region, circuit_context, %{})
      {:ok, _} = ChunkProcess.apply_field_effects(chunk, circuit_effects, %{})

      # 反应:再以更新后的 truth 跑守恒扩散 + 相变,单独提交(避免同格温度写在一批里互相覆盖)。
      reaction_storage = ChunkProcess.debug_state(chunk).storage
      reaction_context = KernelContext.new(region, 7, reaction_storage, dt_ms: 100)
      {_status, region, reaction_effects} = ReactionKernel.tick(region, reaction_context, %{})
      {:ok, _} = ChunkProcess.apply_field_effects(chunk, reaction_effects, %{})

      region
    end)

    # 发热负载被 I²R 加热到高温(证热源是电阻耗散,而非环境扩散)。
    assert temperature_at(chunk, load) > 200.0,
           "闭环载流的发热负载应被 I²R 加热到高温;负载温=#{temperature_at(chunk, load)}℃"

    # 热经守恒扩散把相邻冷冰熔化(热量充足时进而汽化)——不再是冷冰即证 I²R → 扩散 → 相变涌现。
    assert material_at(chunk, ice) in [water_id, steam_id],
           "I²R 热经扩散应熔(可进而汽化)相邻冷冰;负载温=#{temperature_at(chunk, load)}℃ 冰温=#{temperature_at(chunk, ice)}℃ 冰格材料=#{material_at(chunk, ice)}"
  end
end
