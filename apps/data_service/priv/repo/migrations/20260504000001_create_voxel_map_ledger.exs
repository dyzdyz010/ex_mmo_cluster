defmodule DataService.Repo.Migrations.CreateVoxelMapLedger do
  use Ecto.Migration

  @moduledoc """
  Single-row durable backing store for `WorldServer.Voxel.MapLedger`.

  `payload` carries the serialized ledger snapshot (assignments, leases,
  chunk_summaries, migrations) as a `:erlang.term_to_binary/1` blob. We keep
  the table to a single row keyed by a fixed `id` so the on-disk layout matches
  the original file backend (`<path>.tmp -> rename`) one-to-one. A future
  multi-node split will replace this with per-record tables behind the same
  `DataService.Voxel.MapLedgerStore` API.
  """

  def change do
    create table(:voxel_map_ledger_snapshots, primary_key: false) do
      add :id, :integer, primary_key: true
      add :payload, :binary, null: false

      timestamps()
    end
  end
end
