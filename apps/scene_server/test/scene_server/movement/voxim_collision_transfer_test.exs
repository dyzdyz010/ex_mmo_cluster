defmodule SceneServer.Movement.VoximCollisionTransferTest do
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel.{CanonicalDelta, CanonicalSnapshot, ChunkOccupancy}
  alias SceneServer.Movement.CollisionUpdates
  alias SceneServer.Native.VoximMovement, as: P1

  # 仅观察构建边界；几何构建、出生查询都调用真实 Native。
  defmodule Native do
    defdelegate new_world(), to: P1
    def set_chunks(world, operations) do
      send(self(), {:native_install, operations})
      P1.set_chunks(world, operations)
    end
  end

  test "source cut and already published future survive an ahead or behind target" do
    baseline = initialized()
    {source, _} = publish(baseline, 5, delta(41, [chunk(0, :floor)]))
    {source, _} = publish(source, 9, delta(42, [chunk(0, :air)]))
    checkpoint = CollisionUpdates.export_checkpoint(source, 6)
    assert pure_data?(checkpoint)
    decoded = checkpoint |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    assert checkpoint == decoded
    assert Enum.map(checkpoint.revisions, fn {t, r, _} -> {t, r} end) == [{9, 3}, {5, 2}]

    {ahead, _} = publish(baseline, 2, delta(41, [chunk(0, :floor)]))
    {ahead, _} = publish(ahead, 3, delta(42, [chunk(0, :air)]))
    {ahead, _} = publish(ahead, 4, delta(43, [chunk(1, :floor)]))
    assert supported?(ahead, 6, 2.5)

    for target <- [baseline, ahead] do
      assert {:ok, imported} = CollisionUpdates.import_checkpoint(target, checkpoint)
      assert {imported.transaction_seq, imported.revision} == {42, 3}
      assert supported?(imported, 6, 0.5)
      assert supported?(imported, 8, 0.5)
      refute supported?(imported, 9, 0.5)
      refute supported?(imported, 6, 2.5)
      assert supported?(imported, 6, 4.5)
      assert elem(CollisionUpdates.at_tick(imported, 6), 1) == 2
      assert elem(CollisionUpdates.at_tick(imported, 9), 1) == 3
    end

    assert supported?(source, 6, 0.5)
    refute supported?(source, 9, 0.5)
  end

  test "material-only sequence survives transfer and the next canonical delta advances once" do
    {source, _} = publish(initialized(), 7, delta(41, []))
    checkpoint = CollisionUpdates.export_checkpoint(source, 7)
    assert {checkpoint.transaction_seq, checkpoint.revision} == {41, 1}
    assert checkpoint.revisions == [{0, 1, %{}}]
    target = CollisionUpdates.enqueue(initialized(), delta(41, [chunk(1, :floor)]), 1)
    installs()
    assert {:ok, imported} = CollisionUpdates.import_checkpoint(target, checkpoint)
    assert installs() == []
    assert :queue.is_empty(imported.queue)
    {next, events} = publish(imported, 8, delta(42, [chunk(0, :floor)]))
    assert [{:delta, %CanonicalDelta{transaction_seq: 42}, 2, _}] = events
    assert {next.transaction_seq, next.revision} == {42, 2}
    refute supported?(next, 7, 0.5)
    assert supported?(next, 8, 0.5)
  end

  test "checkpoint rebuilds refined occupancy and only changed chunks across revisions" do
    baseline = initialized()
    lower = refined_chunk(0)
    upper = refined_chunk(1)
    {source, _} = publish(baseline, 5, delta(41, [lower, chunk(1, :floor)]))
    {source, _} = publish(source, 9, delta(42, [upper]))
    checkpoint = CollisionUpdates.export_checkpoint(source, 6)
    installs()
    assert {:ok, imported} = CollisionUpdates.import_checkpoint(baseline, checkpoint)
    assert [first, second] = installs()
    assert Enum.map(first, &elem(&1, 1)) == [{0, 0, 0}, {1, 0, 0}]
    assert Enum.map(second, &elem(&1, 1)) == [{0, 0, 0}]
    assert [{:set, {0, 0, 0}, 4, 0.5, {0.0, 0.0, 0.0}, _}] = second
    assert spawn_y(imported, 9) - spawn_y(imported, 6) > 0.49
    assert_in_delta spawn_y(source, 6), spawn_y(imported, 6), 0.000001
    assert_in_delta spawn_y(source, 9), spawn_y(imported, 9), 0.000001
    assert supported?(imported, 9, 2.5)
  end

  test "publication retains transferable artifacts without rebuilding shared native worlds" do
    follower = initialized()
    {scene, events} = publish(follower, 5, delta(41, [chunk(0, :floor)]))
    versions = Enum.filter(scene.revisions, fn {tick, _, _} -> tick == 5 end)
    publication = Enum.map(events, fn {:delta, delta, revision, _} ->
      {<<>>, delta.transaction_seq, revision, delta.chunks, delta}
    end)
    installs()
    follower = CollisionUpdates.ingest_publication(follower, 5, 41, 2, versions, publication)
    assert installs() == []
    assert follower.world == scene.world
    assert CollisionUpdates.export_checkpoint(follower, 5) ==
             CollisionUpdates.export_checkpoint(scene, 5)
    assert supported?(follower, 5, 0.5)

    {follower, _} = publish(follower, 9, delta(42, [chunk(0, :air)]))
    retired = CollisionUpdates.retire_before(follower, 9)
    assert Map.keys(retired.artifacts) == [3]
    assert [{9, 3, _}] = retired.revisions
    assert {:ok, imported} =
             CollisionUpdates.import_checkpoint(initialized(), CollisionUpdates.export_checkpoint(retired, 9))
    refute supported?(imported, 9, 0.5)
  end

  test "a different initial canonical sequence cannot serve as checkpoint baseline" do
    checkpoint = CollisionUpdates.export_checkpoint(initialized(), 0)
    assert {:error, :incompatible_collision_baseline} =
             CollisionUpdates.import_checkpoint(initialized(39), checkpoint)
  end

  defp initialized(seq \\ 40) do
    CollisionUpdates.new(Native)
    |> CollisionUpdates.initialize(%CanonicalSnapshot{
      content_version: 7, transaction_seq: seq,
      l0_min: {0, 0, 0}, l0_max_exclusive: {1, 1, 1}, regions: [],
      chunks: [chunk(0, :air), chunk(1, :air), chunk(2, :floor)]
    })
  end

  defp delta(seq, chunks),
    do: %CanonicalDelta{transaction_seq: seq, transaction: %{seq: seq}, chunks: chunks}

  defp publish(updates, tick, delta) do
    {updates, events} = updates |> CollisionUpdates.enqueue(delta, tick) |> CollisionUpdates.consume(tick)
    {CollisionUpdates.record_tick(updates, tick, events), events}
  end

  defp chunk(x, kind) do
    cells = case kind do
      :air -> <<0, 0, 0, 0, 0, 0, 0, 0>>
      :floor -> <<1, 1, 0, 0, 1, 1, 0, 0>>
    end
    %ChunkOccupancy{coord: {x, 0, 0}, n: 2, scale_m: 1.0,
      origin_m: {x * 2.0, 0.0, 0.0}, cells: cells}
  end

  defp refined_chunk(y) do
    cells = for _z <- 0..3, cy <- 0..3, _x <- 0..3, into: <<>>,
      do: <<if(cy == y, do: 1, else: 0)>>
    %ChunkOccupancy{coord: {0, 0, 0}, n: 4, scale_m: 0.5,
      origin_m: {0.0, 0.0, 0.0}, cells: cells}
  end

  defp supported?(updates, tick, x) do
    {world, _} = CollisionUpdates.at_tick(updates, tick)
    match?({:ok, _}, P1.find_spawn(world, profile(), {x, 8.0, 0.5}, -4.0))
  end

  defp spawn_y(updates, tick) do
    {world, _} = CollisionUpdates.at_tick(updates, tick)
    {:ok, {{_, y, _}, _, _}} = P1.find_spawn(world, profile(), {0.5, 8.0, 0.5}, -4.0)
    y
  end

  defp profile do
    root = Path.expand("../../../../../../Voxim", __DIR__)
    p = root |> Path.join("Docs/M0/fixtures/suite.json") |> File.read!() |> Jason.decode!() |> Map.fetch!("profile")
    ~w(radius half_height speed acceleration braking air_braking friction braking_friction_factor air_control gravity jump_speed step_height snap_distance skin slope_radians)
    |> Enum.map(&(Map.fetch!(p, &1) / 1)) |> List.to_tuple()
  end

  defp installs(acc \\ []) do
    receive do
      {:native_install, operations} -> installs([operations | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp pure_data?(term) when is_map(term), do: term |> Map.to_list() |> Enum.all?(fn {k, v} -> pure_data?(k) and pure_data?(v) end)
  defp pure_data?(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.all?(&pure_data?/1)
  defp pure_data?(term) when is_list(term), do: Enum.all?(term, &pure_data?/1)
  defp pure_data?(term), do: is_atom(term) or is_number(term) or is_binary(term)
end
