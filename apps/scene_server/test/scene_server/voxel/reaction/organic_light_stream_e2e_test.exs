defmodule SceneServer.Voxel.Reaction.OrganicLightStreamE2ETest do
  # 世界内容驱动场 provisioning · 生产 e2e(任务 #38):在**真 ChunkProcess**(auto
  # provisioning 默认开)里放一个 glowstone(纯发光体),订阅者**有机地**收到权威光场的
  # 0x73 FieldRegionSnapshot —— 证明放下光源 → Emergence provisioner 起 [light_propagation,
  # reaction] region → FieldTickWorker fanout 0x73 → 订阅者真收到 :light/:light_color 真流。
  # 这是「涌现真流到客户端」服务端半程的有机闭环(无手动起 worker、无 dev 端点)。
  use ExUnit.Case, async: false

  import Bitwise

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Field.FieldCodec
  alias SceneServer.Voxel.Field.SystemActor
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
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

  test "有机光真流:放 glowstone → Emergence 自动起光场 region → 订阅者收 0x73 含 :light/:light_color" do
    # auto provisioning 默认开(不传 auto_field_provisioning)。
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    # 先订阅(收初始 chunk 快照),再放光源——这样光场 region 起来后 fanout 能投到我们。
    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 77)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    glowstone = Types.macro_index!({1, 0, 0})

    {:ok, _} =
      ChunkProcess.put_solid_block(
        chunk,
        glowstone,
        NormalBlockData.new(MaterialCatalog.material_id(:glowstone))
      )

    # 先确认 Emergence sweep 真起了 region(全套并发下 SimRuntime 有负载,放宽超时)。
    assert poll_until(fn -> ChunkProcess.debug_state(chunk).field_region_count == 1 end, 5_000),
           "Emergence 应在块变更去抖 sweep 后起一个 [light_propagation, reaction] region;" <>
             "实际 field_region_count=#{ChunkProcess.debug_state(chunk).field_region_count}"

    # 放下 glowstone(纯发光体)→ 块变更去抖 sweep → Emergence active → 起
    # [light_propagation, reaction] region(本地 AABB)→ 每 tick fanout 0x73 给订阅者。
    assert_receive {:voxel_field_region_snapshot_payload, field_payload}, 8_000

    decoded = FieldCodec.decode_snapshot_payload!(field_payload)

    # 权威光场真上 wire:light(0x10)+ light_color(0x20)层都在。
    assert band(decoded.field_mask, FieldCodec.field_mask_light()) != 0,
           "0x73 必须带 :light 层(权威光强真流到订阅者)"

    assert band(decoded.field_mask, FieldCodec.field_mask_light_color()) != 0,
           "0x73 必须带 :light_color 层(彩色光真流)"

    # glowstone 自身是光源 → 其 cell 取最亮光强;flood 出的光场非空。
    assert Enum.max(decoded.light_values) > 0,
           "光场非空:glowstone 经 LightPropagationKernel flood 出 > 0 的权威光强"

    # 冷蓝 glowstone(0x60A0FF):光色层里出现其 packed 颜色(光源最亮 cell 的颜色)。
    assert MaterialCatalog.material_id(:glowstone) > 0

    assert 0x60A0FF in decoded.light_color_values,
           "光色层带 glowstone 冷蓝(0x60A0FF)——颜色由材料 light_color 属性涌现"

    # ChunkProcess 真起了一个 Emergence 场 region。
    assert ChunkProcess.debug_state(chunk).field_region_count == 1
  end

  defp poll_until(fun, timeout_ms, waited \\ 0) do
    cond do
      fun.() ->
        true

      waited >= timeout_ms ->
        false

      true ->
        Process.sleep(25)
        poll_until(fun, timeout_ms, waited + 25)
    end
  end
end
