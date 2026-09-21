# 只测试（Test-only）测量：NPC 设计稿 §7.1。真实 GeneratedStore 地形的一个流送窗口，
# 独立构建 N 份 native collision world 与克隆共享 N 份的构建耗时、进程私有内存、单角色步进耗时。
# 运行（apps/scene_server 下）：
#   NPC_MEASURE_MANIFEST=<worldgen-manifest.json> NPC_MEASURE_PROFILE=<demo-config.json> mix test ../../docs/10-active/cross-cutting/tools/collision_share_measure_test.exs
defmodule CollisionShareMeasure do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.CollisionUpdates
  alias SceneServer.Native.VoximMovement, as: Native
  alias VoxelRegion.{CollisionStream, GeneratedStore, World}

  @probe {57.5, 520.0, 60.5}
  @counts [1, 10, 50]

  defp private_mb do
    :erlang.garbage_collect()

    {out, 0} =
      System.cmd("powershell", [
        "-NoProfile",
        "-Command",
        "(Get-Process -Id #{:os.getpid()}).PrivateMemorySize64"
      ])

    String.to_integer(String.trim(out)) / 1_048_576
  end

  defp profile(path) do
    p = path |> File.read!() |> Jason.decode!() |> Map.fetch!("profile")

    ~w(radius half_height speed acceleration braking air_braking friction braking_friction_factor air_control gravity jump_speed step_height snap_distance skin slope_radians)
    |> Enum.map(&(Map.fetch!(p, &1) / 1))
    |> List.to_tuple()
  end

  @tag timeout: 1_800_000
  test "independent vs shared-shape collision worlds over one real streaming window" do
    root = Path.join(System.tmp_dir!(), "npc_measure_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    world =
      start_supervised!(
        {World,
         root: root,
         name: :npc_measure_world,
         source: GeneratedStore,
         manifest_path: System.fetch_env!("NPC_MEASURE_MANIFEST")}
      )

    box = CollisionStream.box(@probe, 1)
    request = make_ref()
    {snapshot_us, :ok} = :timer.tc(fn -> World.canonical_snapshot_and_subscribe(world, box, self(), request) end)
    assert_receive {:canonical_snapshot, ^request, snapshot}, 600_000

    request2 = make_ref()
    {warm_us, :ok} = :timer.tc(fn -> World.canonical_snapshot_and_subscribe(world, box, self(), request2) end)
    assert_receive {:canonical_snapshot, ^request2, _}, 600_000

    IO.puts("RESULT window box=#{inspect(box)} chunks=#{length(snapshot.chunks)} snapshot_cold_ms=#{div(snapshot_us, 1000)} snapshot_warm_ms=#{div(warm_us, 1000)}")

    build = fn -> CollisionUpdates.initialize_stream(CollisionUpdates.new(Native), snapshot) end
    first = build.()
    IO.puts("RESULT world_stats(colliders,compounds,children)=#{inspect(Native.world_stats(first.world))} first_build_ms=#{div(first.build_us, 1000)}")

    for n <- @counts do
      before = private_mb()
      {us, held} = :timer.tc(fn -> for _ <- 1..n, do: build.().world end)
      grown = private_mb() - before
      IO.puts("RESULT independent n=#{n} total_ms=#{div(us, 1000)} per_world_ms=#{Float.round(us / n / 1000, 1)} private_mb_delta=#{Float.round(grown, 1)} per_world_mb=#{Float.round(grown / n, 2)}")
      assert length(held) == n
    end

    for n <- @counts do
      before = private_mb()
      # 空操作的 set_chunks = 克隆 collider/BVH 索引、SharedShape 继续共享：路线 A 的下界。
      {us, held} = :timer.tc(fn -> for _ <- 1..n, do: Native.set_chunks(first.world, []) end)
      grown = private_mb() - before
      IO.puts("RESULT shared n=#{n} total_ms=#{div(us, 1000)} per_world_ms=#{Float.round(us / n / 1000, 2)} private_mb_delta=#{Float.round(grown, 1)} per_world_mb=#{Float.round(grown / n, 3)}")
      assert length(held) == n
    end

    p = profile(System.fetch_env!("NPC_MEASURE_PROFILE"))
    {:ok, start} = Native.find_spawn(first.world, p, @probe, 452.0)

    {us, _} =
      :timer.tc(fn ->
        # 每 2 s 折返，留在窗口内。
        Enum.reduce(1..6000, start, fn t, s ->
          axis = if rem(div(t, 120), 2) == 0, do: 1.0, else: -1.0
          [{1, next}] = Native.step_characters(first.world, p, [{1, s, {axis, 0.0, 0}}])
          next
        end)
      end)

    IO.puts("RESULT step walking 6000 ticks total_ms=#{div(us, 1000)} per_step_us=#{Float.round(us / 6000, 1)}")
  end
end
