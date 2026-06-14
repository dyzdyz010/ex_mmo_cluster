defmodule DataService.Voxel.ChunkSnapshotStore do
  # PERS-5:durable_authoritative(chunk 权威快照,CELL-19 条件写)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

  @moduledoc """
  Canonical voxel chunk snapshot persistence backed by `DataService.Repo`.

  Phase 1d turned this module from an in-memory GenServer into a thin wrapper
  around `voxel_chunks` rows. Each `put_snapshot/2` runs inside a single
  `Repo.transaction/1`. The transaction first takes a per-chunk PostgreSQL
  advisory transaction lock, then performs the row-level check:

      SELECT chunk_version, chunk_hash, data
      FROM voxel_chunks
      WHERE (logical_scene_id, coord_x, coord_y, coord_z) = ($1, $2, $3, $4)
      FOR UPDATE;

  The row lock + serialized cmp inside the transaction enforces the
  canonical `chunk_version` invariant (see protocol design §11):

  * row missing → `INSERT` → `:inserted`
  * `next.chunk_version > current.chunk_version` → `UPDATE` → `:updated`
  * `next.chunk_version == current` AND `(chunk_hash, data)` exact match →
    rollback → `:unchanged`
  * `next.chunk_version == current` AND content differs → rollback →
    `{:error, :chunk_version_conflict}`
  * `next.chunk_version < current` → rollback →
    `{:error, :stale_chunk_version}`

  The lease fields on the incoming attrs are validated by
  `DataService.Voxel.WriteTokenStore` *before* the database round trip; this
  preserves the "world-issued token gates every persistence write" invariant.

  Reads (`get_snapshot/2`) return the canonical persisted row. `snapshot/0`
  is a CLI/debug helper that returns the entire table keyed by
  `{logical_scene_id, chunk_coord}`.
  """

  import Ecto.Query, only: [from: 2]

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkSnapshot
  alias DataService.Voxel.WriteTokenStore

  @type chunk_coord :: {integer(), integer(), integer()}
  @type snapshot :: %{
          required(:logical_scene_id) => non_neg_integer(),
          required(:chunk_coord) => chunk_coord(),
          required(:schema_version) => non_neg_integer(),
          required(:chunk_size_in_macro) => non_neg_integer(),
          required(:micro_resolution) => non_neg_integer(),
          required(:region_id) => non_neg_integer(),
          required(:lease_id) => non_neg_integer(),
          required(:owner_scene_instance_ref) => non_neg_integer(),
          required(:owner_epoch) => non_neg_integer(),
          required(:chunk_version) => non_neg_integer(),
          required(:chunk_hash) => binary(),
          required(:data) => binary()
        }
  @type put_result :: {:ok, :inserted | :updated | :unchanged} | {:error, atom()}
  @type get_result :: {:ok, snapshot()} | {:error, atom()}

  @doc """
  Persists a chunk snapshot to PostgreSQL.

  `attrs` carries the lease fencing fields (`region_id`, `lease_id`,
  `owner_scene_instance_ref`, `owner_epoch`), the location triple
  (`logical_scene_id`, `chunk_coord`), the canonical sizing
  (`schema_version`, `chunk_size_in_macro`, `micro_resolution`), the
  monotonic version (`chunk_version`), the 8-byte hash digest
  (`chunk_hash`), and the full ChunkStorage binary (`data`).

  `opts[:write_token_store]` overrides the named token-store used to
  validate the lease, primarily for tests. `opts[:repo]` overrides the
  default repo (also test-only).
  """
  @spec put_snapshot(map(), keyword()) :: put_result()
  def put_snapshot(attrs, opts \\ [])

  def put_snapshot(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, snapshot} <- normalize_snapshot(attrs),
         :ok <- validate_write_token(opts, snapshot) do
      run_put_transaction(opts, snapshot)
    end
  end

  def put_snapshot(_attrs, _opts), do: {:error, :invalid_snapshot_attrs}

  @doc """
  Reads the persisted snapshot for a logical scene chunk.

  Returns `{:error, :snapshot_not_found}` when no row exists. `chunk_coord`
  may be a `{x, y, z}` tuple or a `[x, y, z]` list.
  """
  @spec get_snapshot(non_neg_integer(), chunk_coord() | [integer()], keyword()) :: get_result()
  def get_snapshot(logical_scene_id, chunk_coord, opts \\ []) do
    with :ok <- validate_non_neg_integer(logical_scene_id, :invalid_logical_scene_id),
         {:ok, {x, y, z}} <- normalize_coord(chunk_coord) do
      repo = repo(opts)

      case repo.get_by(VoxelChunkSnapshot,
             logical_scene_id: logical_scene_id,
             coord_x: x,
             coord_y: y,
             coord_z: z
           ) do
        nil -> {:error, :snapshot_not_found}
        row -> {:ok, to_snapshot(row)}
      end
    end
  end

  @doc """
  Returns every persisted snapshot keyed by `{logical_scene_id, chunk_coord}`.

  CLI/debug helper. The returned map is built in process memory; do not
  call from hot paths or with large schemes.
  """
  @spec snapshot(keyword()) :: %{optional({non_neg_integer(), chunk_coord()}) => snapshot()}
  def snapshot(opts \\ []) do
    repo = repo(opts)

    repo.all(VoxelChunkSnapshot)
    |> Map.new(fn row ->
      snap = to_snapshot(row)
      {{snap.logical_scene_id, snap.chunk_coord}, snap}
    end)
  end

  defp run_put_transaction(opts, snapshot) do
    repo = repo(opts)

    case repo.transaction(fn -> do_put(repo, snapshot) end) do
      {:ok, {:ok, _} = reply} -> reply
      {:ok, {:error, _} = reply} -> reply
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_put(repo, snapshot) do
    :ok = lock_snapshot_key(repo, snapshot)

    case lock_existing_row(repo, snapshot) do
      nil ->
        insert_row(repo, snapshot)

      %VoxelChunkSnapshot{} = row ->
        compare_and_update(repo, row, snapshot)
    end
  end

  defp lock_snapshot_key(repo, snapshot) do
    {x, y, z} = snapshot.chunk_coord

    lock_a =
      :erlang.phash2({:voxel_chunk_snapshot, snapshot.logical_scene_id, x}, 2_147_483_647)

    lock_b = :erlang.phash2({y, z}, 2_147_483_647)

    _result =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT pg_advisory_xact_lock($1, $2)",
        [lock_a, lock_b]
      )

    :ok
  end

  defp lock_existing_row(repo, snapshot) do
    {x, y, z} = snapshot.chunk_coord

    query =
      from(c in VoxelChunkSnapshot,
        where:
          c.logical_scene_id == ^snapshot.logical_scene_id and
            c.coord_x == ^x and c.coord_y == ^y and c.coord_z == ^z,
        lock: "FOR UPDATE"
      )

    repo.one(query)
  end

  defp insert_row(repo, snapshot) do
    changeset =
      VoxelChunkSnapshot.changeset(%VoxelChunkSnapshot{}, snapshot_to_attrs(snapshot))

    case repo.insert(changeset) do
      {:ok, _row} -> {:ok, :inserted}
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_snapshot_attrs}
    end
  end

  defp compare_and_update(repo, current, next) do
    cond do
      next.chunk_version > current.chunk_version ->
        update_row(repo, current, next)

      next.chunk_version < current.chunk_version ->
        {:error, :stale_chunk_version}

      same_content?(current, next) ->
        {:ok, :unchanged}

      true ->
        {:error, :chunk_version_conflict}
    end
  end

  defp update_row(repo, current, next) do
    changeset = VoxelChunkSnapshot.changeset(current, snapshot_to_attrs(next))

    case repo.update(changeset) do
      {:ok, _row} -> {:ok, :updated}
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_snapshot_attrs}
    end
  end

  defp same_content?(current, next) do
    current.chunk_hash == next.chunk_hash and current.data == next.data
  end

  defp snapshot_to_attrs(snapshot) do
    {x, y, z} = snapshot.chunk_coord

    %{
      logical_scene_id: snapshot.logical_scene_id,
      coord_x: x,
      coord_y: y,
      coord_z: z,
      schema_version: snapshot.schema_version,
      chunk_size_in_macro: snapshot.chunk_size_in_macro,
      micro_resolution: snapshot.micro_resolution,
      region_id: snapshot.region_id,
      lease_id: snapshot.lease_id,
      owner_scene_instance_ref: snapshot.owner_scene_instance_ref,
      owner_epoch: snapshot.owner_epoch,
      chunk_version: snapshot.chunk_version,
      # 梯队1 step1.1(TIME-1):Cell 时间字段,默认 0(向后兼容)。
      cell_tick: Map.get(snapshot, :cell_tick, 0),
      sim_time_ms: Map.get(snapshot, :sim_time_ms, 0),
      chunk_hash: snapshot.chunk_hash,
      data: snapshot.data
    }
  end

  defp to_snapshot(%VoxelChunkSnapshot{} = row) do
    %{
      logical_scene_id: row.logical_scene_id,
      chunk_coord: {row.coord_x, row.coord_y, row.coord_z},
      schema_version: row.schema_version,
      chunk_size_in_macro: row.chunk_size_in_macro,
      micro_resolution: row.micro_resolution,
      region_id: row.region_id,
      lease_id: row.lease_id,
      owner_scene_instance_ref: row.owner_scene_instance_ref,
      owner_epoch: row.owner_epoch,
      chunk_version: row.chunk_version,
      cell_tick: row.cell_tick,
      sim_time_ms: row.sim_time_ms,
      chunk_hash: row.chunk_hash,
      data: row.data
    }
  end

  defp validate_write_token(opts, snapshot) do
    token_store = Keyword.get(opts, :write_token_store, WriteTokenStore)

    case WriteTokenStore.validate_write(token_store, snapshot) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :write_token_validation_failed}
    end
  catch
    :exit, _reason -> {:error, :write_token_store_unavailable}
  end

  defp normalize_snapshot(%struct{} = attrs) when is_atom(struct) do
    attrs |> Map.from_struct() |> normalize_snapshot()
  end

  defp normalize_snapshot(attrs) when is_map(attrs) do
    with {:ok, logical_scene_id} <- fetch_non_neg_integer(attrs, :logical_scene_id),
         {:ok, chunk_coord} <- fetch_coord(attrs, :chunk_coord),
         {:ok, schema_version} <- fetch_non_neg_integer_default(attrs, :schema_version, 1),
         {:ok, chunk_size_in_macro} <-
           fetch_non_neg_integer_default(attrs, :chunk_size_in_macro, 16),
         {:ok, micro_resolution} <- fetch_non_neg_integer_default(attrs, :micro_resolution, 8),
         {:ok, region_id} <- fetch_non_neg_integer(attrs, :region_id),
         {:ok, lease_id} <- fetch_non_neg_integer(attrs, :lease_id),
         {:ok, owner_scene_instance_ref} <-
           fetch_non_neg_integer(attrs, :owner_scene_instance_ref),
         {:ok, owner_epoch} <- fetch_non_neg_integer(attrs, :owner_epoch),
         {:ok, chunk_version} <- fetch_non_neg_integer(attrs, :chunk_version),
         {:ok, chunk_hash} <- fetch_chunk_hash(attrs),
         {:ok, data} <- fetch_binary(attrs, :data) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         schema_version: schema_version,
         chunk_size_in_macro: chunk_size_in_macro,
         micro_resolution: micro_resolution,
         region_id: region_id,
         lease_id: lease_id,
         owner_scene_instance_ref: owner_scene_instance_ref,
         owner_epoch: owner_epoch,
         chunk_version: chunk_version,
         cell_tick: Map.get(attrs, :cell_tick, 0),
         sim_time_ms: Map.get(attrs, :sim_time_ms, 0),
         chunk_hash: chunk_hash,
         data: data
       }}
    end
  end

  defp fetch_chunk_hash(attrs) do
    with {:ok, value} <- fetch_required(attrs, :chunk_hash),
         :ok <- validate_chunk_hash(value) do
      {:ok, value}
    end
  end

  defp validate_chunk_hash(value) when is_binary(value) and byte_size(value) == 8, do: :ok
  defp validate_chunk_hash(_value), do: {:error, :invalid_chunk_hash}

  defp fetch_coord(attrs, key) do
    with {:ok, value} <- fetch_required(attrs, key),
         {:ok, coord} <- normalize_coord(value) do
      {:ok, coord}
    else
      {:error, :invalid_chunk_coord} -> {:error, invalid_reason(key)}
      other -> other
    end
  end

  defp fetch_non_neg_integer(attrs, key) do
    with {:ok, value} <- fetch_required(attrs, key),
         :ok <- validate_non_neg_integer(value, invalid_reason(key)) do
      {:ok, value}
    end
  end

  defp fetch_non_neg_integer_default(attrs, key, default) do
    case fetch_optional(attrs, key) do
      :missing ->
        {:ok, default}

      {:ok, value} ->
        case validate_non_neg_integer(value, invalid_reason(key)) do
          :ok -> {:ok, value}
          error -> error
        end
    end
  end

  defp fetch_binary(attrs, key) do
    with {:ok, value} <- fetch_required(attrs, key),
         :ok <- validate_binary(value, invalid_reason(key)) do
      {:ok, value}
    end
  end

  defp fetch_required(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.fetch!(attrs, key)}
      Map.has_key?(attrs, Atom.to_string(key)) -> {:ok, Map.fetch!(attrs, Atom.to_string(key))}
      true -> {:error, missing_reason(key)}
    end
  end

  defp fetch_optional(attrs, key) do
    cond do
      Map.has_key?(attrs, key) -> {:ok, Map.fetch!(attrs, key)}
      Map.has_key?(attrs, Atom.to_string(key)) -> {:ok, Map.fetch!(attrs, Atom.to_string(key))}
      true -> :missing
    end
  end

  defp normalize_coord({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z) do
    {:ok, {x, y, z}}
  end

  defp normalize_coord([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z) do
    {:ok, {x, y, z}}
  end

  defp normalize_coord(_value), do: {:error, :invalid_chunk_coord}

  defp validate_non_neg_integer(value, _reason) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_neg_integer(_value, reason), do: {:error, reason}

  defp validate_binary(value, _reason) when is_binary(value), do: :ok
  defp validate_binary(_value, reason), do: {:error, reason}

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  defp missing_reason(:logical_scene_id), do: :missing_logical_scene_id
  defp missing_reason(:chunk_coord), do: :missing_chunk_coord
  defp missing_reason(:region_id), do: :missing_region_id
  defp missing_reason(:lease_id), do: :missing_lease_id
  defp missing_reason(:owner_scene_instance_ref), do: :missing_owner_scene_instance_ref
  defp missing_reason(:owner_epoch), do: :missing_owner_epoch
  defp missing_reason(:chunk_version), do: :missing_chunk_version
  defp missing_reason(:chunk_hash), do: :missing_chunk_hash
  defp missing_reason(:data), do: :missing_data
  defp missing_reason(:schema_version), do: :missing_schema_version
  defp missing_reason(:chunk_size_in_macro), do: :missing_chunk_size_in_macro
  defp missing_reason(:micro_resolution), do: :missing_micro_resolution

  defp invalid_reason(:logical_scene_id), do: :invalid_logical_scene_id
  defp invalid_reason(:chunk_coord), do: :invalid_chunk_coord
  defp invalid_reason(:region_id), do: :invalid_region_id
  defp invalid_reason(:lease_id), do: :invalid_lease_id
  defp invalid_reason(:owner_scene_instance_ref), do: :invalid_owner_scene_instance_ref
  defp invalid_reason(:owner_epoch), do: :invalid_owner_epoch
  defp invalid_reason(:chunk_version), do: :invalid_chunk_version
  defp invalid_reason(:chunk_hash), do: :invalid_chunk_hash
  defp invalid_reason(:data), do: :invalid_data
  defp invalid_reason(:schema_version), do: :invalid_schema_version
  defp invalid_reason(:chunk_size_in_macro), do: :invalid_chunk_size_in_macro
  defp invalid_reason(:micro_resolution), do: :invalid_micro_resolution
end
