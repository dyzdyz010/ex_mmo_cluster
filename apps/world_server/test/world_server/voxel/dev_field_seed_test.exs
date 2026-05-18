defmodule WorldServer.Voxel.DevFieldSeedTest do
  use ExUnit.Case, async: true

  alias DataService.Voxel.WriteTokenStore
  alias WorldServer.Voxel.DevFieldSeed
  alias WorldServer.Voxel.MapLedger

  defmodule FakeSceneFieldCreate do
    @moduledoc false

    def conduct_path(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:conduct_path, opts})
      {:ok, %{created: true, region_id: 42}}
    end
  end

  defmodule FakeRejectingSceneFieldCreate do
    @moduledoc false

    def conduct_path(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:conduct_path, opts})
      {:error, {:conduction_path_failed, :source_not_conductive}}
    end
  end

  test "routes conduction creation through the source chunk lease owner" do
    token_store = start_supervised!(WriteTokenStore)
    ledger_name = :"dev_field_seed_ledger_#{System.unique_integer([:positive])}"
    ledger = start_supervised!({MapLedger, name: ledger_name, write_token_store: token_store})

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 101,
               region_id: 101_001,
               bounds_chunk_min: {1, 0, 0},
               bounds_chunk_max: {2, 1, 1},
               owner_scene_instance_ref: 7,
               owner_epoch: 1,
               assigned_scene_node: node()
             })

    assert {:ok, lease} =
             MapLedger.issue_lease(ledger, 101_001, 7, owner_epoch: 1, ttl_ms: 60_000)

    assert {:ok, summary} =
             DevFieldSeed.ensure_conduction_path(
               ledger: ledger,
               scene_module: FakeSceneFieldCreate,
               test_pid: self(),
               logical_scene_id: 101,
               source_world_macro: {17, 0, 0},
               target_world_macro: {18, 0, 0},
               source_potential: 120
             )

    assert summary.scene_node == Atom.to_string(node())
    assert summary.region_id == 42

    assert_receive {:conduct_path, opts}
    assert Keyword.fetch!(opts, :lease).lease_id == lease.lease_id
    assert Keyword.fetch!(opts, :source_world_macro) == {17, 0, 0}
    assert Keyword.fetch!(opts, :target_world_macro) == {18, 0, 0}
  end

  test "rejects conduction creation when source chunk has no lease route" do
    missing_ledger = :"missing_dev_field_seed_ledger_#{System.unique_integer([:positive])}"

    assert {:error, {:source_chunk_route_unavailable, {:ledger_unavailable, _reason}}} =
             DevFieldSeed.ensure_conduction_path(
               ledger: missing_ledger,
               scene_module: FakeSceneFieldCreate,
               test_pid: self(),
               logical_scene_id: 102,
               source_world_macro: {0, 0, 0},
               target_world_macro: {1, 0, 0},
               source_potential: 120
             )

    refute_receive {:conduct_path, _opts}
  end

  test "preserves scene-side conduction rejection reasons" do
    token_store = start_supervised!(WriteTokenStore)
    ledger_name = :"dev_field_seed_reject_ledger_#{System.unique_integer([:positive])}"
    ledger = start_supervised!({MapLedger, name: ledger_name, write_token_store: token_store})

    assert {:ok, _assignment} =
             MapLedger.put_region(ledger, %{
               logical_scene_id: 103,
               region_id: 103_001,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {1, 1, 1},
               owner_scene_instance_ref: 7,
               owner_epoch: 1,
               assigned_scene_node: node()
             })

    assert {:ok, lease} =
             MapLedger.issue_lease(ledger, 103_001, 7, owner_epoch: 1, ttl_ms: 60_000)

    assert {:error, {:conduction_path_failed, :source_not_conductive}} =
             DevFieldSeed.ensure_conduction_path(
               ledger: ledger,
               scene_module: FakeRejectingSceneFieldCreate,
               test_pid: self(),
               logical_scene_id: 103,
               source_world_macro: {0, 0, 0},
               target_world_macro: {1, 0, 0},
               source_potential: 120
             )

    assert_receive {:conduct_path, opts}
    assert Keyword.fetch!(opts, :lease).lease_id == lease.lease_id
  end
end
