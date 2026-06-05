defmodule DataService.Repo.Migrations.CreateVoxelSceneNodeRegistry do
  use Ecto.Migration

  @moduledoc """
  Single-row durable backing store for
  `WorldServer.Voxel.SceneNodeRegistry`.

  `payload` carries the serialized registry snapshot (join_order,
  region_assignments, round_robin_cursor) as a `:erlang.term_to_binary/1` blob.
  We keep the table to a single row keyed by a fixed `id`, matching the
  `voxel_map_ledger_snapshots` / `voxel_transaction_coordinator_snapshots`
  layout so the same single-row snapshot facility backs all three World-side
  control-plane processes behind the
  `DataService.Voxel.SceneNodeRegistryStore` API.

  Architecture note (Phase 3 — process identity registration, S1): the
  Postgres row is the *authoritative* record of which scene_node owns which
  region. The in-memory `SceneNodeRegistry` GenServer state is a derived,
  rebuildable cache hydrated from this row on (re)start — never a second
  source of truth.
  """

  def change do
    create table(:voxel_scene_node_registry_snapshots, primary_key: false) do
      add :id, :integer, primary_key: true
      add :payload, :binary, null: false

      timestamps()
    end
  end
end
