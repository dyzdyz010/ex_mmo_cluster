defmodule WorldServer.Voxel.DefaultRegionBootstrapperTest do
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.DefaultRegionBootstrapper

  test "prepares the default region after the service starts" do
    parent = self()

    seed_fun = fn opts ->
      send(parent, {:seed_called, opts})
      {:ok, %{status: :created}}
    end

    bootstrapper =
      start_supervised!(
        {DefaultRegionBootstrapper,
         enabled?: true,
         logical_scene_id: 77,
         seed_fun: seed_fun,
         retry_ms: 10,
         refresh_ms: :timer.hours(1)}
      )

    assert_receive {:seed_called, opts}, 500
    assert Keyword.fetch!(opts, :logical_scene_id) == 77
    assert Keyword.fetch!(opts, :seed_terrain?) == true
    assert Keyword.fetch!(opts, :rebuild_lod_projection?) == true
    assert Keyword.fetch!(opts, :lod_projection_rebuild_opts) == []

    baseline = Keyword.fetch!(opts, :baseline_footprint_chunks)
    assert length(baseline) == 343
    assert {0, 0, 0} in baseline
    assert {-3, -3, -3} in baseline
    assert {3, 3, 3} in baseline

    assert %{status: :ready, attempts: 1, baseline_chunk_count: 343} =
             DefaultRegionBootstrapper.snapshot(bootstrapper)
  end

  test "can prepare a custom active baseline window" do
    parent = self()

    seed_fun = fn opts ->
      send(parent, {:seed_called, opts})
      {:ok, %{status: :created}}
    end

    start_supervised!(
      {DefaultRegionBootstrapper,
       enabled?: true,
       logical_scene_id: 79,
       seed_fun: seed_fun,
       baseline_center_chunk: {2, 1, -1},
       baseline_radius: 1,
       retry_ms: 10,
       refresh_ms: :timer.hours(1)}
    )

    assert_receive {:seed_called, opts}, 500
    baseline = Keyword.fetch!(opts, :baseline_footprint_chunks)
    assert length(baseline) == 27
    assert {2, 1, -1} in baseline
    assert {1, 0, -2} in baseline
    assert {3, 2, 0} in baseline
  end

  test "can explicitly disable terrain seed and LOD rebuild" do
    parent = self()

    seed_fun = fn opts ->
      send(parent, {:seed_called, opts})
      {:ok, %{status: :created}}
    end

    start_supervised!(
      {DefaultRegionBootstrapper,
       enabled?: true,
       logical_scene_id: 78,
       seed_fun: seed_fun,
       seed_terrain?: false,
       rebuild_lod_projection?: false,
       retry_ms: 10,
       refresh_ms: :timer.hours(1)}
    )

    assert_receive {:seed_called, opts}, 500
    assert Keyword.fetch!(opts, :logical_scene_id) == 78
    assert Keyword.fetch!(opts, :seed_terrain?) == false
    assert Keyword.fetch!(opts, :rebuild_lod_projection?) == false
  end

  test "retries until scene ownership is ready" do
    parent = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    seed_fun = fn _opts ->
      attempt = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
      send(parent, {:seed_attempt, attempt})

      case attempt do
        1 -> {:error, :scene_node_unassigned}
        _ -> {:ok, %{status: :renewed}}
      end
    end

    bootstrapper =
      start_supervised!(
        {DefaultRegionBootstrapper,
         enabled?: true,
         logical_scene_id: 1,
         seed_fun: seed_fun,
         retry_ms: 10,
         refresh_ms: :timer.hours(1)}
      )

    assert_receive {:seed_attempt, 1}, 500
    assert_receive {:seed_attempt, 2}, 500
    assert %{status: :ready, attempts: 2} = DefaultRegionBootstrapper.snapshot(bootstrapper)
  end

  test "stays inert when disabled" do
    parent = self()

    seed_fun = fn _opts ->
      send(parent, :unexpected_seed)
      {:ok, %{}}
    end

    bootstrapper =
      start_supervised!(
        {DefaultRegionBootstrapper,
         enabled?: false,
         logical_scene_id: 1,
         seed_fun: seed_fun,
         retry_ms: 10,
         refresh_ms: :timer.hours(1)}
      )

    refute_receive :unexpected_seed, 30
    assert %{status: :disabled, attempts: 0} = DefaultRegionBootstrapper.snapshot(bootstrapper)
  end
end
