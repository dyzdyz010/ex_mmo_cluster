defmodule DataService.Voxel.ChunkSnapshotStore do
  @moduledoc """
  In-memory voxel chunk snapshot persistence boundary.

  This process owns the first DataService-side copy of persisted chunk
  snapshots. Scene runtimes may request writes, but the store only accepts them
  after `DataService.Voxel.WriteTokenStore` confirms the writer still owns the
  region lease. This keeps authority state in the token store and persistence
  state in this snapshot store.

  The implementation is intentionally process-local. Its public API mirrors the
  later durable backend: writes are fenced by the current token, newer
  `chunk_version` values replace older snapshots, and exact same-version content
  replays are idempotent.
  """

  use GenServer

  alias DataService.Voxel.WriteTokenStore

  @type chunk_coord :: {integer(), integer(), integer()}
  @type snapshot :: %{
          required(:logical_scene_id) => non_neg_integer(),
          required(:chunk_coord) => chunk_coord(),
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
  Starts the chunk snapshot store.

  Options:

    * `:name` - optional GenServer name.
    * `:write_token_store` - token store process or name used for write fences.

  """
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Writes a chunk snapshot to the module-named store.

  `attrs` must contain the logical scene id, chunk coordinate, lease fencing
  fields, `chunk_version`, `chunk_hash`, and binary `data`. The write succeeds
  only when the configured write token store validates the lease and the incoming
  version is newer than the stored version, or when it is an idempotent replay of
  the exact same version/hash/data.
  """
  @spec put_snapshot(map()) :: put_result()
  def put_snapshot(attrs) when is_map(attrs) do
    put_snapshot(__MODULE__, attrs, [])
  end

  def put_snapshot(_attrs), do: {:error, :invalid_snapshot_attrs}

  @doc """
  Writes a chunk snapshot using either explicit store or explicit options.

  When the first argument is a map and the second is a keyword list, the call
  targets the module-named store and treats the second argument as options. When
  the first argument is not snapshot attrs, it is treated as the GenServer name
  or pid and the second argument is the snapshot attrs. `opts[:write_token_store]`
  can override the token store configured at process start.
  """
  @spec put_snapshot(GenServer.server(), map()) :: put_result()
  @spec put_snapshot(map(), keyword()) :: put_result()
  def put_snapshot(attrs, opts) when is_map(attrs) and is_list(opts) do
    put_snapshot(__MODULE__, attrs, opts)
  end

  def put_snapshot(server, attrs) when is_map(attrs) do
    put_snapshot(server, attrs, [])
  end

  def put_snapshot(_server, _attrs), do: {:error, :invalid_snapshot_attrs}

  @doc """
  Writes a chunk snapshot to an explicit store with per-call options.

  This is the fully explicit API used by tests and adapters that run isolated
  stores. `server` selects the snapshot store, `attrs` is normalized into the
  stored snapshot shape, and `opts[:write_token_store]` selects the write-token
  authority used for this call.
  """
  @spec put_snapshot(GenServer.server(), map(), keyword()) :: put_result()
  def put_snapshot(server, attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, snapshot} <- normalize_snapshot(attrs) do
      GenServer.call(server, {:put_snapshot, snapshot, opts})
    end
  end

  def put_snapshot(_server, _attrs, _opts), do: {:error, :invalid_snapshot_attrs}

  @doc "Reads the latest stored snapshot for a logical scene chunk from the module-named store."
  @spec get_snapshot(non_neg_integer(), chunk_coord() | [integer()]) :: get_result()
  def get_snapshot(logical_scene_id, chunk_coord) do
    get_snapshot(__MODULE__, logical_scene_id, chunk_coord)
  end

  @doc """
  Reads the latest stored snapshot for a logical scene chunk from an explicit store.

  `chunk_coord` may be a `{x, y, z}` tuple or `[x, y, z]` list. The call returns
  `{:ok, snapshot}` when the exact logical-scene/chunk key exists, otherwise
  `{:error, :snapshot_not_found}` after input validation succeeds.
  """
  @spec get_snapshot(GenServer.server(), non_neg_integer(), chunk_coord() | [integer()]) ::
          get_result()
  def get_snapshot(server, logical_scene_id, chunk_coord) do
    with :ok <- validate_non_neg_integer(logical_scene_id, :invalid_logical_scene_id),
         {:ok, coord} <- normalize_coord(chunk_coord) do
      GenServer.call(server, {:get_snapshot, logical_scene_id, coord})
    end
  end

  @doc "Returns the current in-memory snapshot table for CLI/debug inspection."
  @spec snapshot(GenServer.server()) :: %{
          optional({non_neg_integer(), chunk_coord()}) => snapshot()
        }
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       snapshots: %{},
       write_token_store: Keyword.get(opts, :write_token_store, WriteTokenStore)
     }}
  end

  @impl true
  def handle_call({:put_snapshot, snapshot, opts}, _from, state) do
    token_store = Keyword.get(opts, :write_token_store, state.write_token_store)

    case validate_write_token(token_store, snapshot) do
      :ok ->
        {reply, snapshots} = put_valid_snapshot(state.snapshots, snapshot)
        {:reply, reply, %{state | snapshots: snapshots}}

      {:error, reason} when is_atom(reason) ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_snapshot, logical_scene_id, chunk_coord}, _from, state) do
    reply =
      case Map.fetch(state.snapshots, {logical_scene_id, chunk_coord}) do
        {:ok, snapshot} -> {:ok, snapshot}
        :error -> {:error, :snapshot_not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state.snapshots, state}
  end

  defp validate_write_token(token_store, snapshot) do
    case WriteTokenStore.validate_write(token_store, snapshot) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :write_token_validation_failed}
    end
  catch
    :exit, _reason -> {:error, :write_token_store_unavailable}
  end

  defp put_valid_snapshot(snapshots, snapshot) do
    key = snapshot_key(snapshot)

    case Map.fetch(snapshots, key) do
      :error ->
        {{:ok, :inserted}, Map.put(snapshots, key, snapshot)}

      {:ok, current} ->
        put_existing_snapshot(snapshots, key, current, snapshot)
    end
  end

  defp put_existing_snapshot(snapshots, key, current, next) do
    cond do
      next.chunk_version > current.chunk_version ->
        {{:ok, :updated}, Map.put(snapshots, key, next)}

      next.chunk_version < current.chunk_version ->
        {{:error, :stale_chunk_version}, snapshots}

      same_snapshot_content?(current, next) ->
        {{:ok, :unchanged}, snapshots}

      true ->
        {{:error, :chunk_version_conflict}, snapshots}
    end
  end

  defp same_snapshot_content?(left, right) do
    left.chunk_hash == right.chunk_hash and left.data == right.data
  end

  defp snapshot_key(snapshot), do: {snapshot.logical_scene_id, snapshot.chunk_coord}

  defp normalize_snapshot(%struct{} = attrs) when is_atom(struct) do
    attrs |> Map.from_struct() |> normalize_snapshot()
  end

  defp normalize_snapshot(attrs) when is_map(attrs) do
    with {:ok, logical_scene_id} <- fetch_non_neg_integer(attrs, :logical_scene_id),
         {:ok, chunk_coord} <- fetch_coord(attrs, :chunk_coord),
         {:ok, region_id} <- fetch_non_neg_integer(attrs, :region_id),
         {:ok, lease_id} <- fetch_non_neg_integer(attrs, :lease_id),
         {:ok, owner_scene_instance_ref} <-
           fetch_non_neg_integer(attrs, :owner_scene_instance_ref),
         {:ok, owner_epoch} <- fetch_non_neg_integer(attrs, :owner_epoch),
         {:ok, chunk_version} <- fetch_non_neg_integer(attrs, :chunk_version),
         {:ok, chunk_hash} <- fetch_binary(attrs, :chunk_hash),
         {:ok, data} <- fetch_binary(attrs, :data) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         region_id: region_id,
         lease_id: lease_id,
         owner_scene_instance_ref: owner_scene_instance_ref,
         owner_epoch: owner_epoch,
         chunk_version: chunk_version,
         chunk_hash: chunk_hash,
         data: data
       }}
    end
  end

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

  defp fetch_binary(attrs, key) do
    with {:ok, value} <- fetch_required(attrs, key),
         :ok <- validate_binary(value, invalid_reason(key)) do
      {:ok, value}
    end
  end

  defp fetch_required(attrs, key) do
    cond do
      Map.has_key?(attrs, key) ->
        {:ok, Map.fetch!(attrs, key)}

      Map.has_key?(attrs, Atom.to_string(key)) ->
        {:ok, Map.fetch!(attrs, Atom.to_string(key))}

      true ->
        {:error, missing_reason(key)}
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

  defp missing_reason(:logical_scene_id), do: :missing_logical_scene_id
  defp missing_reason(:chunk_coord), do: :missing_chunk_coord
  defp missing_reason(:region_id), do: :missing_region_id
  defp missing_reason(:lease_id), do: :missing_lease_id
  defp missing_reason(:owner_scene_instance_ref), do: :missing_owner_scene_instance_ref
  defp missing_reason(:owner_epoch), do: :missing_owner_epoch
  defp missing_reason(:chunk_version), do: :missing_chunk_version
  defp missing_reason(:chunk_hash), do: :missing_chunk_hash
  defp missing_reason(:data), do: :missing_data

  defp invalid_reason(:logical_scene_id), do: :invalid_logical_scene_id
  defp invalid_reason(:chunk_coord), do: :invalid_chunk_coord
  defp invalid_reason(:region_id), do: :invalid_region_id
  defp invalid_reason(:lease_id), do: :invalid_lease_id
  defp invalid_reason(:owner_scene_instance_ref), do: :invalid_owner_scene_instance_ref
  defp invalid_reason(:owner_epoch), do: :invalid_owner_epoch
  defp invalid_reason(:chunk_version), do: :invalid_chunk_version
  defp invalid_reason(:chunk_hash), do: :invalid_chunk_hash
  defp invalid_reason(:data), do: :invalid_data
end
