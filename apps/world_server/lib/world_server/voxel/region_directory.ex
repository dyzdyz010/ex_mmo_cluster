defmodule WorldServer.Voxel.RegionDirectory do
  @moduledoc """
  World-side adapter between `WorldServer.Voxel.MapLedger`'s in-memory structs
  (`RegionAssignment` / `SceneLease`) and the durable per-region directory
  (`DataService.Voxel.RegionDirectoryStore`, 阶段2)。

  Lives in `world_server` (not `data_service`) because only this side may build
  the world structs — `data_service` must not depend back on `world_server`.
  Converts an assignment (+ optional lease) into a flat directory-row map for the
  store, and rebuilds `{assignment, lease}` from a loaded row so a restarted World
  node recovers materialized region ownership instead of relying on lazy
  re-materialization (CELL-23 重启自愈).
  """

  alias WorldServer.Voxel.RegionAssignment
  alias WorldServer.Voxel.SceneLease

  @doc "Flattens an assignment (+ optional lease) into a `RegionDirectoryStore` row map."
  @spec to_attrs(RegionAssignment.t(), SceneLease.t() | nil) :: map()
  def to_attrs(%RegionAssignment{} = assignment, lease) do
    {min_x, min_y, min_z} = assignment.bounds_chunk_min
    {max_x, max_y, max_z} = assignment.bounds_chunk_max

    %{
      region_id: assignment.region_id,
      logical_scene_id: assignment.logical_scene_id,
      bounds_chunk_min_x: min_x,
      bounds_chunk_min_y: min_y,
      bounds_chunk_min_z: min_z,
      bounds_chunk_max_x: max_x,
      bounds_chunk_max_y: max_y,
      bounds_chunk_max_z: max_z,
      owner_scene_instance_ref: assignment.owner_scene_instance_ref,
      owner_epoch: assignment.owner_epoch,
      lease_id: assignment.lease_id,
      assigned_scene_node: node_to_string(assignment.assigned_scene_node),
      region_state: Atom.to_string(assignment.state),
      region_version: assignment.version,
      expires_at_ms: lease && lease.expires_at_ms
    }
  end

  @doc "Rebuilds `{assignment, lease | nil}` from a loaded directory-row map."
  @spec from_row(map()) :: {RegionAssignment.t(), SceneLease.t() | nil}
  def from_row(row) do
    assignment =
      RegionAssignment.new(%{
        region_id: row.region_id,
        logical_scene_id: row.logical_scene_id,
        bounds_chunk_min: {row.bounds_chunk_min_x, row.bounds_chunk_min_y, row.bounds_chunk_min_z},
        bounds_chunk_max: {row.bounds_chunk_max_x, row.bounds_chunk_max_y, row.bounds_chunk_max_z},
        owner_scene_instance_ref: row.owner_scene_instance_ref,
        owner_epoch: row.owner_epoch,
        lease_id: row.lease_id,
        assigned_scene_node: string_to_node(row.assigned_scene_node),
        state: state_atom(row.region_state),
        version: row.region_version
      })

    lease =
      if not is_nil(row.lease_id) and not is_nil(row.expires_at_ms) do
        SceneLease.from_assignment(assignment, row.lease_id, row.expires_at_ms)
      end

    {assignment, lease}
  end

  @doc """
  Loads the durable directory into the `%{assignments: map, leases: map}` shape
  `MapLedger.init` merges — the boot-time restore of materialized regions.

  `store` is the `RegionDirectoryStore` module; `opts` is forwarded (e.g. `:repo`).
  """
  @spec load_state(module(), keyword()) :: %{assignments: map(), leases: map()}
  def load_state(store, opts \\ []) do
    store.load_all(opts)
    |> Enum.reduce(%{assignments: %{}, leases: %{}}, fn row, acc ->
      {assignment, lease} = from_row(row)
      acc = put_in(acc, [:assignments, assignment.region_id], assignment)

      if lease do
        put_in(acc, [:leases, assignment.region_id], lease)
      else
        acc
      end
    end)
  end

  defp node_to_string(nil), do: nil
  defp node_to_string(node) when is_atom(node), do: Atom.to_string(node)

  # Node names are a bounded set (cluster membership); to_atom is acceptable and
  # necessary because a peer World node loading the directory may not yet hold the
  # scene node's atom.
  defp string_to_node(nil), do: nil
  defp string_to_node(string) when is_binary(string), do: String.to_atom(string)

  # The region state atoms (:active/:migrating/:draining/:inactive) are defined by
  # RegionAssignment, so they always exist — to_existing_atom guards against a
  # corrupted row injecting an arbitrary atom.
  defp state_atom(nil), do: :active
  defp state_atom(string) when is_binary(string), do: String.to_existing_atom(string)
end
