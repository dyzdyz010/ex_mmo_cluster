defmodule SceneServer.Voxel.RegionRoutingTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{ChunkDirectory, RegionRouting}

  # `RegionRouting` flips between two backends:
  # * production → BeaconServer.Client (Horde-backed)
  # * stub → static `:persistent_term` map keyed by region_id
  #
  # The scene_server test_helper does not boot `BeaconServer.DistributedRegistry`,
  # so production-path assertions start it ad-hoc here. Stub-path assertions
  # don't need the registry.

  setup do
    case Horde.Registry.start_link(
           name: BeaconServer.DistributedRegistry,
           keys: :unique,
           members: :auto
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn ->
      RegionRouting.__clear_stub__()
    end)

    :ok
  end

  describe "production path (BeaconServer-backed)" do
    test "register_local_region → resolve_scene_node hits this node" do
      region_id = unique_region_id()
      assert :ok = RegionRouting.register_local_region(region_id)
      assert {:ok, node} = RegionRouting.resolve_scene_node(region_id, _lease = nil)
      assert node == node()
    end

    test "register is idempotent" do
      region_id = unique_region_id()
      assert :ok = RegionRouting.register_local_region(region_id)
      assert :ok = RegionRouting.register_local_region(region_id)
    end

    test "unresolved region returns :error from resolve_scene_node" do
      assert :error = RegionRouting.resolve_scene_node(unique_region_id(), nil)
    end

    test "unregister_local_region from a child process clears the entry" do
      region_id = unique_region_id()
      parent = self()

      pid =
        spawn(fn ->
          :ok = RegionRouting.register_local_region(region_id)
          send(parent, :registered)

          receive do
            :withdraw ->
              :ok = RegionRouting.unregister_local_region(region_id)
              send(parent, :withdrawn)
          end
        end)

      assert_receive :registered, 1_000
      assert {:ok, _} = RegionRouting.resolve_scene_node(region_id, nil)

      send(pid, :withdraw)
      assert_receive :withdrawn, 1_000

      assert :error = RegionRouting.resolve_scene_node(region_id, nil)
    end

    test "resolve_chunk_directory of local region returns the bare module atom" do
      region_id = unique_region_id()
      :ok = RegionRouting.register_local_region(region_id)

      assert ChunkDirectory ==
               RegionRouting.resolve_chunk_directory({region_id, _lease_id = nil})
    end

    test "resolve_chunk_directory of unknown region returns nil" do
      assert is_nil(RegionRouting.resolve_chunk_directory({unique_region_id(), nil}))
    end
  end

  describe "stub path (:persistent_term snapshot)" do
    test "stub takes precedence over BeaconServer for resolve" do
      registered_region = unique_region_id()
      stubbed_region = unique_region_id()
      remote_node = :"sim_remote@127.0.0.1"

      # First register normally to prove the stub overrides production
      :ok = RegionRouting.register_local_region(registered_region)

      :ok =
        RegionRouting.__install_stub__(%{
          stubbed_region => remote_node
        })

      # registered_region exists in BeaconServer but stub doesn't list it →
      # resolve treats it as missing
      assert :error = RegionRouting.resolve_scene_node(registered_region, nil)

      # Stubbed region resolves to the fake remote node
      assert {:ok, ^remote_node} = RegionRouting.resolve_scene_node(stubbed_region, nil)
    end

    test "stub mode makes register / unregister no-ops" do
      region_id = unique_region_id()
      :ok = RegionRouting.__install_stub__(%{})

      assert :ok = RegionRouting.register_local_region(region_id)
      assert :ok = RegionRouting.unregister_local_region(region_id)

      # No BeaconServer side effects: clearing stub leaves the region
      # unresolved.
      :ok = RegionRouting.__clear_stub__()
      assert :error = RegionRouting.resolve_scene_node(region_id, nil)
    end

    test "resolve_chunk_directory: local node → atom, remote → tuple, miss → nil" do
      local_region = unique_region_id()
      remote_region = unique_region_id()
      missing_region = unique_region_id()
      remote_node = :"other_scene@127.0.0.1"

      :ok =
        RegionRouting.__install_stub__(%{
          local_region => node(),
          remote_region => remote_node
        })

      assert ChunkDirectory ==
               RegionRouting.resolve_chunk_directory({local_region, nil})

      assert {ChunkDirectory, ^remote_node} =
               RegionRouting.resolve_chunk_directory({remote_region, nil})

      assert is_nil(RegionRouting.resolve_chunk_directory({missing_region, nil}))
    end

    test "__clear_stub__ returns to production behaviour" do
      :ok = RegionRouting.__install_stub__(%{99_999 => :"x@127.0.0.1"})
      assert RegionRouting.__stub_active__?()

      :ok = RegionRouting.__clear_stub__()
      refute RegionRouting.__stub_active__?()

      # Clearing twice is safe.
      assert :ok = RegionRouting.__clear_stub__()
    end
  end

  defp unique_region_id, do: System.unique_integer([:positive, :monotonic])
end
