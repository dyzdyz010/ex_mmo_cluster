defmodule DataService.Voxel.ChunkPendingTransactionStore do
  @moduledoc """
  Stateless persistence wrapper around `voxel_chunk_pending_transactions`.

  Phase 3-bis fence persistence (D1):每个被 `SceneServer.Voxel.ChunkProcess`
  prepare 的 fence 落一行,Scene 重启后 ChunkProcess.init 用 `get_fence/3` 把
  fence reload 回 in-memory state。

  与 `DataService.Voxel.ChunkSnapshotStore` 一样是 stateless module,直走
  `DataService.Repo`。语义上一个 `(logical_scene_id, chunk_coord)` 同时只能
  持一个 fence —— DB 复合主键负责 `put_fence/2` 的唯一性,应用层 ChunkProcess
  GenServer 串行化 prepare 路径,正常路径不会冲突,即便有冲突 DB 也会硬拒绝。

  fence_payload 是 `:erlang.term_to_binary/1` 编码的 normalized intent batch,
  反序列化时用 `[:safe]` 模式防止反序列化未知 atom 导致 atom 表膨胀。
  """

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkPendingTransaction

  @type chunk_coord :: {integer(), integer(), integer()}

  @type fence :: %{
          required(:logical_scene_id) => non_neg_integer(),
          required(:chunk_coord) => chunk_coord(),
          required(:transaction_id) => binary(),
          required(:decision_version) => non_neg_integer(),
          required(:owner_region_id) => non_neg_integer(),
          required(:owner_lease_id) => non_neg_integer(),
          required(:owner_scene_instance_ref) => non_neg_integer(),
          required(:owner_epoch) => non_neg_integer(),
          required(:intents) => list(),
          required(:fenced_at_ms) => non_neg_integer()
        }

  @type put_result :: {:ok, :inserted} | {:error, atom()}
  @type get_result :: {:ok, fence()} | {:error, atom()}
  @type delete_result :: {:ok, :deleted | :not_found} | {:error, atom()}

  @doc """
  Persists a chunk fence row.

  `attrs` carries the chunk identity (`logical_scene_id`, `chunk_coord`), the
  transaction identity (`transaction_id`, `decision_version`), the lease the
  fence belongs to (`owner_region_id`, `owner_lease_id`,
  `owner_scene_instance_ref`, `owner_epoch`), the normalized `intents` list,
  and `fenced_at_ms`.

  The `intents` list is encoded with `:erlang.term_to_binary/1` before
  insert. INSERT must succeed for `prepare_transaction` to accept the fence;
  unique-key collisions surface as `:fence_already_present`.

  `opts[:repo]` overrides the default repo (test-only).
  """
  @spec put_fence(map(), keyword()) :: put_result()
  def put_fence(attrs, opts \\ [])

  def put_fence(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, fence} <- normalize_fence(attrs) do
      repo = repo(opts)
      changeset = VoxelChunkPendingTransaction.changeset(%VoxelChunkPendingTransaction{}, fence)

      case repo.insert(changeset) do
        {:ok, _row} ->
          {:ok, :inserted}

        {:error, %Ecto.Changeset{errors: errors}} ->
          if unique_violation?(errors) do
            {:error, :fence_already_present}
          else
            {:error, :invalid_fence_attrs}
          end
      end
    end
  rescue
    _exception in Postgrex.Error -> {:error, :fence_persist_failed}
  end

  def put_fence(_attrs, _opts), do: {:error, :invalid_fence_attrs}

  defp unique_violation?(errors) do
    Enum.any?(errors, fn
      {_field, {"fence already present", _opts}} -> true
      _ -> false
    end)
  end

  @doc """
  Reads the persisted fence for a chunk.

  Returns `{:error, :fence_not_found}` when no row exists. `chunk_coord` may
  be a `{x, y, z}` tuple or `[x, y, z]` list.
  """
  @spec get_fence(non_neg_integer(), chunk_coord() | [integer()], keyword()) :: get_result()
  def get_fence(logical_scene_id, chunk_coord, opts \\ []) do
    with :ok <- validate_non_neg_integer(logical_scene_id, :invalid_logical_scene_id),
         {:ok, {x, y, z}} <- normalize_coord(chunk_coord) do
      repo = repo(opts)

      case repo.get_by(VoxelChunkPendingTransaction,
             logical_scene_id: logical_scene_id,
             coord_x: x,
             coord_y: y,
             coord_z: z
           ) do
        nil -> {:error, :fence_not_found}
        row -> to_fence(row)
      end
    end
  end

  @doc """
  Deletes the persisted fence for a chunk.

  Idempotent: deleting a missing fence returns `{:ok, :not_found}` instead of
  an error.
  """
  @spec delete_fence(non_neg_integer(), chunk_coord() | [integer()], keyword()) :: delete_result()
  def delete_fence(logical_scene_id, chunk_coord, opts \\ []) do
    with :ok <- validate_non_neg_integer(logical_scene_id, :invalid_logical_scene_id),
         {:ok, {x, y, z}} <- normalize_coord(chunk_coord) do
      repo = repo(opts)

      case repo.get_by(VoxelChunkPendingTransaction,
             logical_scene_id: logical_scene_id,
             coord_x: x,
             coord_y: y,
             coord_z: z
           ) do
        nil ->
          {:ok, :not_found}

        row ->
          case repo.delete(row) do
            {:ok, _row} -> {:ok, :deleted}
            {:error, %Ecto.Changeset{}} -> {:error, :fence_delete_failed}
          end
      end
    end
  end

  @doc """
  Returns every persisted fence keyed by `{logical_scene_id, chunk_coord}`.

  CLI/debug helper. The returned map is built in process memory; do not call
  from hot paths or with large schemes.
  """
  @spec snapshot(keyword()) :: %{optional({non_neg_integer(), chunk_coord()}) => fence()}
  def snapshot(opts \\ []) do
    repo = repo(opts)

    repo.all(VoxelChunkPendingTransaction)
    |> Enum.reduce(%{}, fn row, acc ->
      case to_fence(row) do
        {:ok, fence} ->
          Map.put(acc, {fence.logical_scene_id, fence.chunk_coord}, fence)

        _ ->
          acc
      end
    end)
  end

  defp to_fence(%VoxelChunkPendingTransaction{} = row) do
    case decode_intents(row.fence_payload) do
      {:ok, intents} ->
        {:ok,
         %{
           logical_scene_id: row.logical_scene_id,
           chunk_coord: {row.coord_x, row.coord_y, row.coord_z},
           transaction_id: row.transaction_id,
           decision_version: row.decision_version,
           owner_region_id: row.owner_region_id,
           owner_lease_id: row.owner_lease_id,
           owner_scene_instance_ref: row.owner_scene_instance_ref,
           owner_epoch: row.owner_epoch,
           intents: intents,
           fenced_at_ms: row.fenced_at_ms
         }}

      {:error, _reason} ->
        {:error, :invalid_fence_payload}
    end
  end

  defp decode_intents(payload) when is_binary(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    _exception in [ArgumentError] -> {:error, :invalid_fence_payload}
  end

  defp decode_intents(_payload), do: {:error, :invalid_fence_payload}

  defp normalize_fence(%struct{} = attrs) when is_atom(struct) do
    attrs |> Map.from_struct() |> normalize_fence()
  end

  defp normalize_fence(attrs) when is_map(attrs) do
    with {:ok, logical_scene_id} <- fetch_non_neg_integer(attrs, :logical_scene_id),
         {:ok, {x, y, z}} <- fetch_coord(attrs, :chunk_coord),
         {:ok, transaction_id} <- fetch_binary(attrs, :transaction_id),
         :ok <- validate_nonempty_binary(transaction_id, :invalid_transaction_id),
         {:ok, decision_version} <- fetch_non_neg_integer(attrs, :decision_version),
         {:ok, owner_region_id} <- fetch_non_neg_integer(attrs, :owner_region_id),
         {:ok, owner_lease_id} <- fetch_non_neg_integer(attrs, :owner_lease_id),
         {:ok, owner_scene_instance_ref} <-
           fetch_non_neg_integer(attrs, :owner_scene_instance_ref),
         {:ok, owner_epoch} <- fetch_non_neg_integer(attrs, :owner_epoch),
         {:ok, intents} <- fetch_intents(attrs),
         {:ok, fenced_at_ms} <- fetch_non_neg_integer(attrs, :fenced_at_ms) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         coord_x: x,
         coord_y: y,
         coord_z: z,
         transaction_id: transaction_id,
         decision_version: decision_version,
         owner_region_id: owner_region_id,
         owner_lease_id: owner_lease_id,
         owner_scene_instance_ref: owner_scene_instance_ref,
         owner_epoch: owner_epoch,
         fence_payload: :erlang.term_to_binary(intents),
         fenced_at_ms: fenced_at_ms
       }}
    end
  end

  defp normalize_fence(_attrs), do: {:error, :invalid_fence_attrs}

  defp fetch_intents(attrs) do
    case fetch_required(attrs, :intents) do
      {:ok, intents} when is_list(intents) and intents != [] -> {:ok, intents}
      {:ok, _other} -> {:error, :invalid_intents}
      error -> error
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
      Map.has_key?(attrs, key) -> {:ok, Map.fetch!(attrs, key)}
      Map.has_key?(attrs, Atom.to_string(key)) -> {:ok, Map.fetch!(attrs, Atom.to_string(key))}
      true -> {:error, missing_reason(key)}
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

  defp validate_nonempty_binary(<<>>, reason), do: {:error, reason}
  defp validate_nonempty_binary(value, _reason) when is_binary(value), do: :ok
  defp validate_nonempty_binary(_value, reason), do: {:error, reason}

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  defp missing_reason(:logical_scene_id), do: :missing_logical_scene_id
  defp missing_reason(:chunk_coord), do: :missing_chunk_coord
  defp missing_reason(:transaction_id), do: :missing_transaction_id
  defp missing_reason(:decision_version), do: :missing_decision_version
  defp missing_reason(:owner_region_id), do: :missing_owner_region_id
  defp missing_reason(:owner_lease_id), do: :missing_owner_lease_id
  defp missing_reason(:owner_scene_instance_ref), do: :missing_owner_scene_instance_ref
  defp missing_reason(:owner_epoch), do: :missing_owner_epoch
  defp missing_reason(:intents), do: :missing_intents
  defp missing_reason(:fenced_at_ms), do: :missing_fenced_at_ms

  defp invalid_reason(:logical_scene_id), do: :invalid_logical_scene_id
  defp invalid_reason(:chunk_coord), do: :invalid_chunk_coord
  defp invalid_reason(:transaction_id), do: :invalid_transaction_id
  defp invalid_reason(:decision_version), do: :invalid_decision_version
  defp invalid_reason(:owner_region_id), do: :invalid_owner_region_id
  defp invalid_reason(:owner_lease_id), do: :invalid_owner_lease_id
  defp invalid_reason(:owner_scene_instance_ref), do: :invalid_owner_scene_instance_ref
  defp invalid_reason(:owner_epoch), do: :invalid_owner_epoch
  defp invalid_reason(:intents), do: :invalid_intents
  defp invalid_reason(:fenced_at_ms), do: :invalid_fenced_at_ms
end
