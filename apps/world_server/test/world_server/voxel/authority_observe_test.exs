defmodule WorldServer.Voxel.AuthorityObserveTest do
  use ExUnit.Case, async: false

  alias DataService.Voxel.WriteTokenStore
  alias WorldServer.Voxel.AuthorityObserve
  alias WorldServer.Voxel.MapLedger

  setup do
    previous = Application.fetch_env(:world_server, :cli_observe_log)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:world_server, :cli_observe_log, value)
        :error -> Application.delete_env(:world_server, :cli_observe_log)
      end
    end)

    :ok
  end

  test "runs a logical scene lease, route, migration, and token validation observe flow" do
    token_store = start_supervised!(WriteTokenStore)
    ledger = start_supervised!({MapLedger, write_token_store: token_store})
    observe_log = observe_log_path("authority-observe")

    assert {:ok, result} =
             AuthorityObserve.run(
               logical_scene_id: 77,
               observe_log: observe_log,
               ledger: ledger,
               write_token_store: token_store
             )

    assert result.logical_scene_id == 77
    assert result.observe_log == observe_log
    assert result.leases.before_migration.lease_id == 100
    assert result.leases.after_migration.lease_id == 101
    assert result.routes.before_migration.owner_scene_instance_ref == 1_000
    assert result.routes.after_migration.owner_scene_instance_ref == 2_000
    assert result.migration.plan.state == :prewarming
    assert result.migration.plan.source_scene_instance_ref == 1_000
    assert result.migration.plan.target_scene_instance_ref == 2_000
    assert result.migration.slice.bounds_chunk_min == [0, 0, 0]
    assert result.migration.slice.bounds_chunk_max == [2, 4, 4]
    assert result.migration.handoff.old_lease.lease_id == 100
    assert result.migration.handoff.new_lease.lease_id == 101
    assert length(result.migration.acked_slices) == 2
    assert Enum.all?(result.migration.acked_slices, &(&1.state == :prewarmed))
    assert length(result.migration.final_catchup_slices) == 2

    assert Enum.all?(
             result.migration.final_catchup_slices,
             &Map.has_key?(&1, :final_catchup_ack)
           )

    assert result.migration.prewarmed_snapshot.state == :prewarmed
    assert result.migration.completed.state == :completed
    assert result.validations.current_before_migration == %{world: :ok, data_service: :ok}

    assert result.validations.stale_after_migration == %{
             world: {:error, :lease_id_mismatch},
             data_service: {:error, :lease_id_mismatch}
           }

    assert result.validations.current_after_migration == %{world: :ok, data_service: :ok}

    assert event?(observe_log, "voxel_authority_acceptance_started")
    assert event?(observe_log, "voxel_region_put")
    assert event?(observe_log, "voxel_lease_issued")
    assert event?(observe_log, "voxel_authority_write_token_published")
    assert event?(observe_log, "voxel_authority_chunk_routed")
    assert event?(observe_log, "voxel_migration_begun")
    assert event?(observe_log, "voxel_migration_slice_planned")
    assert event?(observe_log, "voxel_migration_slice_prewarmed")
    assert event?(observe_log, "voxel_migration_handoff_read")
    assert event?(observe_log, "voxel_migration_prewarmed")
    assert event?(observe_log, "voxel_authority_migration_snapshot")
    assert event?(observe_log, "voxel_migration_slice_final_caught_up")
    assert event?(observe_log, "voxel_migration_cutover")
    assert event?(observe_log, "voxel_region_migrated")
    assert event?(observe_log, "voxel_migration_completed")
    assert event?(observe_log, "voxel_authority_write_token_validated")
    assert event?(observe_log, "voxel_authority_acceptance_completed")

    lines = read_observe_lines(observe_log)
    assert Enum.any?(lines, &String.contains?(&1, "logical_scene_id: 77"))
    assert Enum.any?(lines, &String.contains?(&1, "world_status: \"error:lease_id_mismatch\""))

    assert Enum.any?(
             lines,
             &String.contains?(&1, "data_service_status: \"error:lease_id_mismatch\"")
           )
  end

  defp observe_log_path(name) do
    dir =
      Path.join([
        System.tmp_dir!(),
        "world-server-observe-tests",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "#{name}.log")
  end

  defp event?(observe_log, event) do
    observe_log
    |> read_observe_lines()
    |> Enum.any?(fn line -> String.contains?(line, ~s(event="#{event}")) end)
  end

  defp read_observe_lines(observe_log) do
    observe_log
    |> File.read!()
    |> String.split("\n", trim: true)
  end
end
