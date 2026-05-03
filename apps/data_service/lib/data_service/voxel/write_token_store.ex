defmodule DataService.Voxel.WriteTokenStore do
  @moduledoc """
  In-memory write-token fence for voxel chunk persistence.

  WorldServer publishes one current lease write token per logical scene region.
  DataService validates every voxel write against this local table so old scene
  instances cannot persist chunks after a migration or lease flip. The store is
  deliberately small and process-local for the first implementation; the public
  API is shaped so it can later be backed by PostgreSQL rows with CAS updates.
  """

  use GenServer

  @type chunk_coord :: {integer(), integer(), integer()}
  @type token :: %{
          required(:logical_scene_id) => non_neg_integer(),
          required(:region_id) => non_neg_integer(),
          required(:lease_id) => non_neg_integer(),
          required(:owner_scene_instance_ref) => non_neg_integer(),
          required(:owner_epoch) => non_neg_integer(),
          required(:bounds_chunk_min) => chunk_coord(),
          required(:bounds_chunk_max) => chunk_coord(),
          required(:expires_at_ms) => non_neg_integer(),
          required(:token_version) => non_neg_integer()
        }

  @doc "Starts the write token store."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Inserts or updates a token with CAS semantics on `token_version`.

  A newer token replaces the previous one. Replaying the same token is
  idempotent. A stale token is rejected and leaves the current token unchanged.
  """
  def upsert_token(server \\ __MODULE__, token) do
    GenServer.call(server, {:upsert_token, normalize_token(token)})
  end

  @doc "Validates a chunk write against the current token table."
  def validate_write(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:validate_write, normalize_write(attrs)})
  end

  @doc "Returns the current token table for CLI/debug inspection."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(_opts) do
    {:ok, %{tokens: %{}}}
  end

  @impl true
  def handle_call({:upsert_token, token}, _from, state) do
    key = token_key(token)
    current = Map.get(state.tokens, key)

    case compare_token(current, token) do
      :newer ->
        {:reply, {:ok, upsert_result(current)}, put_in(state.tokens[key], token)}

      :same ->
        {:reply, {:ok, :unchanged}, state}

      :stale ->
        {:reply, {:error, :stale_token}, state}
    end
  end

  def handle_call({:validate_write, write}, _from, state) do
    {:reply, validate_against_tokens(state.tokens, write, now_ms()), state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state.tokens, state}
  end

  defp compare_token(nil, _token), do: :newer

  defp compare_token(current, token) do
    cond do
      token.token_version > current.token_version -> :newer
      token.token_version == current.token_version and token == current -> :same
      true -> :stale
    end
  end

  defp upsert_result(nil), do: :inserted
  defp upsert_result(_current), do: :updated

  defp validate_against_tokens(tokens, write, now_ms) do
    with {:ok, token} <- find_token(tokens, write),
         :ok <- validate_bounds(token, write.chunk_coord),
         :ok <- validate_identity(token, write),
         :ok <- validate_expiry(token, now_ms) do
      :ok
    end
  end

  defp find_token(tokens, %{region_id: region_id, logical_scene_id: logical_scene_id})
       when not is_nil(region_id) do
    case Map.fetch(tokens, {logical_scene_id, region_id}) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, :unknown_region_token}
    end
  end

  defp find_token(tokens, %{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}) do
    tokens
    |> Map.values()
    |> Enum.find(fn token ->
      token.logical_scene_id == logical_scene_id and chunk_in_bounds?(chunk_coord, token)
    end)
    |> case do
      nil -> {:error, :unknown_region_token}
      token -> {:ok, token}
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

  defp token_key(token), do: {token.logical_scene_id, token.region_id}

  defp normalize_token(%struct{} = token) when is_atom(struct) do
    token |> Map.from_struct() |> normalize_token()
  end

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
    KeyError ->
      raise ArgumentError, "missing required #{inspect(key)}"
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp now_ms, do: System.system_time(:millisecond)
end
