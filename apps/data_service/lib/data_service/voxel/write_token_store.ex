defmodule DataService.Voxel.WriteTokenStore do
  @moduledoc """
  Durable write-token fence for voxel chunk persistence(梯队1 step1.2,CELL-19/21)。

  WorldServer publishes one current lease write token per logical scene region.
  DataService validates every voxel write against this fence so old scene
  instances cannot persist chunks after a migration or lease flip.

  **持久化(本次重构)**:token 落 `voxel_write_tokens` 表(`token_version` CAS,
  advisory lock 线性化每 region),故 fencing 在节点重启后仍有效——消除了原内存版"重启即空"
  的 fencing 失效窗口。`upsert_token`/`validate_write`/`snapshot`/`reset` 直接走
  `DataService.Repo`(stateless,与 `DataService.Voxel.ChunkSnapshotStore` 同构)。

  > **兼容垫片**:仍提供 `start_link/1`(空 GenServer),使既有
  > `start_supervised!(WriteTokenStore)` 与 `name:` 调用方/测试无需改动;函数 API 的首个
  > `server` 参数被忽略(DB 是唯一真相)。该垫片是过渡 tech-debt,移除列入梯队4。
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  alias DataService.Repo
  alias DataService.Schema.VoxelWriteToken

  @type chunk_coord :: {integer(), integer(), integer()}

  # ---------------------------------------------------------------------------
  # 兼容垫片:空 GenServer(仅为既有 start_supervised!/name: 调用方保留)。
  # ---------------------------------------------------------------------------
  @doc "启动兼容垫片进程(无状态;真相在 Postgres)。"
  def start_link(opts \\ []) do
    {server_opts, _init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, %{}, server_opts)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  # ---------------------------------------------------------------------------
  # Public API(首参 server 为兼容保留,被忽略;DB 是唯一真相)。
  # ---------------------------------------------------------------------------

  @doc """
  Inserts or updates a token with CAS semantics on `token_version`(durable)。

  A newer token replaces the previous one; replaying the same token is
  idempotent; a stale token is rejected and leaves the current token unchanged.
  """
  def upsert_token(server \\ __MODULE__, token, opts \\ [])
  def upsert_token(_server, token, opts), do: do_upsert_token(normalize_token(token), opts)

  @doc "Validates a chunk write against the durable token fence."
  def validate_write(server \\ __MODULE__, attrs, opts \\ [])
  def validate_write(_server, attrs, opts), do: do_validate_write(normalize_write(attrs), opts)

  @doc "Returns the current token table for CLI/debug inspection."
  def snapshot(server \\ __MODULE__, opts \\ [])

  def snapshot(_server, opts) do
    repo = repo(opts)

    repo.all(VoxelWriteToken)
    |> Map.new(fn row ->
      token = row_to_token(row)
      {{token.logical_scene_id, token.region_id}, token}
    end)
  end

  @doc """
  Clears every stored token. Test-only hatch; production code never needs to
  drop the in-flight authority because lease lifetime is owned by World.
  """
  def reset(server \\ __MODULE__, opts \\ [])

  def reset(_server, opts) do
    repo = repo(opts)
    repo.delete_all(VoxelWriteToken)
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks(垫片:无业务逻辑)。
  # ---------------------------------------------------------------------------
  @impl true
  def handle_call(_msg, _from, state), do: {:reply, {:error, :use_module_api}, state}

  # ---------------------------------------------------------------------------
  # DB-backed core
  # ---------------------------------------------------------------------------

  defp do_upsert_token(token, opts) do
    repo = repo(opts)

    case repo.transaction(fn -> upsert_in_txn(repo, token) end) do
      {:ok, {:ok, _} = reply} -> reply
      {:ok, {:error, _} = reply} -> reply
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_in_txn(repo, token) do
    lock_region(repo, token.logical_scene_id, token.region_id)

    case fetch_row(repo, token.logical_scene_id, token.region_id) do
      nil ->
        insert_row(repo, token)
        {:ok, :inserted}

      %VoxelWriteToken{} = row ->
        compare_and_upsert(repo, row, token)
    end
  end

  defp compare_and_upsert(repo, %VoxelWriteToken{} = row, token) do
    current = row_to_token(row)

    cond do
      token.token_version > current.token_version ->
        row
        |> VoxelWriteToken.changeset(token_to_attrs(token))
        |> repo.update!()

        {:ok, :updated}

      token.token_version == current.token_version and tokens_equal?(current, token) ->
        {:ok, :unchanged}

      true ->
        {:error, :stale_token}
    end
  end

  defp do_validate_write(write, opts) do
    repo = repo(opts)
    now_ms = now_ms()

    with {:ok, token} <- find_token(repo, write),
         :ok <- validate_bounds(token, write.chunk_coord),
         :ok <- validate_identity(token, write),
         :ok <- validate_expiry(token, now_ms) do
      :ok
    end
  end

  defp find_token(repo, %{region_id: region_id, logical_scene_id: logical_scene_id})
       when not is_nil(region_id) do
    case fetch_row(repo, logical_scene_id, region_id) do
      nil -> {:error, :unknown_region_token}
      row -> {:ok, row_to_token(row)}
    end
  end

  defp find_token(repo, %{logical_scene_id: logical_scene_id, chunk_coord: {cx, cy, cz}}) do
    query =
      from(t in VoxelWriteToken,
        where:
          t.logical_scene_id == ^logical_scene_id and
            t.bounds_chunk_min_x <= ^cx and ^cx < t.bounds_chunk_max_x and
            t.bounds_chunk_min_y <= ^cy and ^cy < t.bounds_chunk_max_y and
            t.bounds_chunk_min_z <= ^cz and ^cz < t.bounds_chunk_max_z,
        limit: 1
      )

    case repo.one(query) do
      nil -> {:error, :unknown_region_token}
      row -> {:ok, row_to_token(row)}
    end
  end

  defp validate_bounds(token, chunk_coord) do
    if chunk_in_bounds?(chunk_coord, token), do: :ok, else: {:error, :chunk_out_of_bounds}
  end

  defp validate_identity(token, write) do
    cond do
      write.lease_id != token.lease_id ->
        {:error, :lease_id_mismatch}

      write.owner_scene_instance_ref != token.owner_scene_instance_ref ->
        {:error, :owner_scene_mismatch}

      write.owner_epoch != token.owner_epoch ->
        {:error, :owner_epoch_mismatch}

      true ->
        :ok
    end
  end

  defp validate_expiry(%{expires_at_ms: expires_at_ms}, now_ms) do
    if expires_at_ms > now_ms, do: :ok, else: {:error, :lease_expired}
  end

  defp chunk_in_bounds?({cx, cy, cz}, token) do
    {min_x, min_y, min_z} = token.bounds_chunk_min
    {max_x, max_y, max_z} = token.bounds_chunk_max
    cx >= min_x and cx < max_x and cy >= min_y and cy < max_y and cz >= min_z and cz < max_z
  end

  # ---------------------------------------------------------------------------
  # repo helpers
  # ---------------------------------------------------------------------------

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  defp lock_region(repo, logical_scene_id, region_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      "SELECT pg_advisory_xact_lock($1, $2)",
      [
        :erlang.phash2({:voxel_write_token, logical_scene_id}, 2_147_483_647),
        :erlang.phash2(region_id, 2_147_483_647)
      ]
    )

    :ok
  end

  defp fetch_row(repo, logical_scene_id, region_id) do
    repo.get_by(VoxelWriteToken, logical_scene_id: logical_scene_id, region_id: region_id)
  end

  defp insert_row(repo, token) do
    %VoxelWriteToken{}
    |> VoxelWriteToken.changeset(token_to_attrs(token))
    |> repo.insert!()
  end

  defp token_to_attrs(token) do
    {min_x, min_y, min_z} = token.bounds_chunk_min
    {max_x, max_y, max_z} = token.bounds_chunk_max

    %{
      logical_scene_id: token.logical_scene_id,
      region_id: token.region_id,
      lease_id: token.lease_id,
      owner_scene_instance_ref: token.owner_scene_instance_ref,
      owner_epoch: token.owner_epoch,
      bounds_chunk_min_x: min_x,
      bounds_chunk_min_y: min_y,
      bounds_chunk_min_z: min_z,
      bounds_chunk_max_x: max_x,
      bounds_chunk_max_y: max_y,
      bounds_chunk_max_z: max_z,
      expires_at_ms: token.expires_at_ms,
      token_version: token.token_version
    }
  end

  defp row_to_token(%VoxelWriteToken{} = row) do
    %{
      logical_scene_id: row.logical_scene_id,
      region_id: row.region_id,
      lease_id: row.lease_id,
      owner_scene_instance_ref: row.owner_scene_instance_ref,
      owner_epoch: row.owner_epoch,
      bounds_chunk_min: {row.bounds_chunk_min_x, row.bounds_chunk_min_y, row.bounds_chunk_min_z},
      bounds_chunk_max: {row.bounds_chunk_max_x, row.bounds_chunk_max_y, row.bounds_chunk_max_z},
      expires_at_ms: row.expires_at_ms,
      token_version: row.token_version
    }
  end

  defp tokens_equal?(a, b) do
    Map.take(a, [
      :logical_scene_id,
      :region_id,
      :lease_id,
      :owner_scene_instance_ref,
      :owner_epoch,
      :bounds_chunk_min,
      :bounds_chunk_max,
      :expires_at_ms,
      :token_version
    ]) ==
      Map.take(b, [
        :logical_scene_id,
        :region_id,
        :lease_id,
        :owner_scene_instance_ref,
        :owner_epoch,
        :bounds_chunk_min,
        :bounds_chunk_max,
        :expires_at_ms,
        :token_version
      ])
  end

  # ---------------------------------------------------------------------------
  # input normalization (struct/map → 内部 token/write map)
  # ---------------------------------------------------------------------------

  defp normalize_token(%_struct{} = token), do: token |> Map.from_struct() |> normalize_token()

  defp normalize_token(attrs) when is_map(attrs) do
    %{
      logical_scene_id: fetch!(attrs, :logical_scene_id),
      region_id: fetch!(attrs, :region_id),
      lease_id: fetch!(attrs, :lease_id),
      owner_scene_instance_ref: fetch!(attrs, :owner_scene_instance_ref),
      owner_epoch: fetch!(attrs, :owner_epoch),
      bounds_chunk_min: coord!(fetch!(attrs, :bounds_chunk_min)),
      bounds_chunk_max: coord!(fetch!(attrs, :bounds_chunk_max)),
      expires_at_ms: fetch!(attrs, :expires_at_ms),
      token_version: fetch!(attrs, :token_version)
    }
  end

  defp normalize_write(attrs) when is_map(attrs) do
    %{
      logical_scene_id: fetch!(attrs, :logical_scene_id),
      region_id: Map.get(attrs, :region_id),
      chunk_coord: coord!(fetch!(attrs, :chunk_coord)),
      lease_id: fetch!(attrs, :lease_id),
      owner_scene_instance_ref: fetch!(attrs, :owner_scene_instance_ref),
      owner_epoch: fetch!(attrs, :owner_epoch)
    }
  end

  defp fetch!(attrs, key) do
    Map.fetch!(attrs, key)
  rescue
    KeyError -> raise ArgumentError, "missing required #{inspect(key)}"
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp now_ms, do: System.system_time(:millisecond)
end
