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
    assert %{status: :ready, attempts: 1} = DefaultRegionBootstrapper.snapshot(bootstrapper)
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
