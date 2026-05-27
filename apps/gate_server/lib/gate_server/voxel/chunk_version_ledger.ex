defmodule GateServer.Voxel.ChunkVersionLedger do
  @moduledoc """
  Tracks chunk versions already forwarded by one Gate connection.

  Scene remains the voxel truth owner and decides whether a subscription needs
  to push a full `ChunkSnapshot`. This cache is only a Gate-local transport
  hint: on reliable TCP/WebSocket connections, once Gate forwards a snapshot or
  an applicable delta, future subscribe plans can pass that version back as
  `known_version`.
  """

  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec

  @type chunk_coord :: {integer(), integer(), integer()}
  @type key :: {non_neg_integer(), chunk_coord()}
  @type t :: %{optional(key()) => non_neg_integer()}

  @doc "Returns an empty per-connection chunk version ledger."
  @spec new() :: t()
  def new, do: %{}

  @doc """
  Records a forwarded Scene payload.

  Snapshot payloads are authoritative and replace the stored version. Delta
  payloads only advance the stored version; stale deltas are reported but do
  not move the ledger backwards.
  """
  @spec record_payload(t() | nil, :snapshot | :delta, binary()) ::
          {:ok, t(), map()} | {:error, t(), map()}
  def record_payload(ledger, :snapshot, payload) when is_binary(payload) do
    case SceneVoxelCodec.decode_chunk_snapshot_payload(payload) do
      {:ok, %{storage: storage}} ->
        record_snapshot(
          ledger,
          storage.logical_scene_id,
          storage.chunk_coord,
          storage.chunk_version
        )

      {:error, reason} ->
        {:error, normalize_ledger(ledger), decode_failed(:snapshot, reason)}
    end
  end

  def record_payload(ledger, :delta, payload) when is_binary(payload) do
    case SceneVoxelCodec.decode_chunk_delta_payload(payload) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         base_chunk_version: base_chunk_version,
         new_chunk_version: new_chunk_version
       }} ->
        record_delta(ledger, logical_scene_id, chunk_coord, base_chunk_version, new_chunk_version)

      {:error, reason} ->
        {:error, normalize_ledger(ledger), decode_failed(:delta, reason)}
    end
  end

  @doc "Records a version directly and raises on invalid inputs."
  @spec record_version!(t() | nil, non_neg_integer(), chunk_coord(), non_neg_integer()) :: t()
  def record_version!(ledger, logical_scene_id, chunk_coord, chunk_version) do
    Map.put(
      normalize_ledger(ledger),
      key!(logical_scene_id, chunk_coord),
      non_negative_integer!(chunk_version, :chunk_version)
    )
  end

  @doc "Returns the known chunk versions for one logical scene."
  @spec known_versions(t() | nil, non_neg_integer()) :: %{
          optional(chunk_coord()) => non_neg_integer()
        }
  def known_versions(ledger, logical_scene_id) do
    logical_scene_id = non_negative_integer!(logical_scene_id, :logical_scene_id)

    ledger
    |> normalize_ledger()
    |> Enum.flat_map(fn
      {{^logical_scene_id, chunk_coord}, chunk_version} -> [{chunk_coord, chunk_version}]
      {_key, _chunk_version} -> []
    end)
    |> Map.new()
  end

  @doc """
  Merges client-provided known-version hints with Gate-forwarded versions.

  Explicit client hints win for chunks they mention. Gate's forwarded cache only
  fills missing chunks, because it is not a client ACK ledger. These values
  remain sync hints only; Scene still owns the authoritative payload decision.
  """
  @spec merge_known_versions(t() | nil, non_neg_integer(), map() | list() | nil) :: map()
  def merge_known_versions(ledger, logical_scene_id, client_known_versions) do
    ledger_known = known_versions(ledger, logical_scene_id)
    client_known = normalize_known_versions(client_known_versions)

    Map.merge(ledger_known, client_known)
  end

  @doc "Clears the chunk identified by a Scene `ChunkInvalidate` payload."
  @spec clear_invalidate_payload(t() | nil, binary()) :: {:ok, t(), map()} | {:error, t(), map()}
  def clear_invalidate_payload(ledger, payload) when is_binary(payload) do
    ledger = normalize_ledger(ledger)

    case SceneVoxelCodec.decode_chunk_invalidate_payload(payload) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         reason: reason,
         reason_name: reason_name
       }} ->
        key = key!(logical_scene_id, chunk_coord)
        previous_version = Map.get(ledger, key)

        {:ok, Map.delete(ledger, key),
         %{
           status: if(is_nil(previous_version), do: :not_cached, else: :cleared),
           frame_kind: :invalidate,
           logical_scene_id: logical_scene_id,
           chunk_coord: chunk_coord,
           previous_version: previous_version,
           reason: reason,
           reason_name: reason_name
         }}

      {:error, reason} ->
        {:error, ledger, decode_failed(:invalidate, reason)}
    end
  end

  @doc "Clears one cached chunk version."
  @spec clear_chunk(t() | nil, non_neg_integer(), chunk_coord()) :: t()
  def clear_chunk(ledger, logical_scene_id, chunk_coord) do
    Map.delete(normalize_ledger(ledger), key!(logical_scene_id, chunk_coord))
  end

  @doc "Returns a deterministic list useful in tests and debug output."
  @spec to_sorted_list(t() | nil) :: [{non_neg_integer(), chunk_coord(), non_neg_integer()}]
  def to_sorted_list(ledger) do
    ledger
    |> normalize_ledger()
    |> Enum.map(fn {{logical_scene_id, chunk_coord}, chunk_version} ->
      {logical_scene_id, chunk_coord, chunk_version}
    end)
    |> Enum.sort()
  end

  @doc "Formats a bounded deterministic ledger summary for CLI/debug probes."
  @spec format_debug(t() | nil, pos_integer()) :: binary()
  def format_debug(ledger, limit \\ 16) when is_integer(limit) and limit > 0 do
    entries = to_sorted_list(ledger)
    visible = Enum.take(entries, limit)
    suffix_count = max(length(entries) - length(visible), 0)

    if suffix_count == 0 do
      inspect(visible)
    else
      "#{inspect(visible)} ...(+#{suffix_count})"
    end
  end

  defp record_snapshot(ledger, logical_scene_id, chunk_coord, chunk_version) do
    ledger = normalize_ledger(ledger)
    key = key!(logical_scene_id, chunk_coord)
    previous_version = Map.get(ledger, key)
    chunk_version = non_negative_integer!(chunk_version, :chunk_version)

    {:ok, Map.put(ledger, key, chunk_version),
     event(:recorded, :snapshot, logical_scene_id, chunk_coord, previous_version, chunk_version)}
  end

  defp record_delta(ledger, logical_scene_id, chunk_coord, base_version, chunk_version) do
    ledger = normalize_ledger(ledger)
    key = key!(logical_scene_id, chunk_coord)
    previous_version = Map.get(ledger, key)
    base_version = non_negative_integer!(base_version, :base_chunk_version)
    chunk_version = non_negative_integer!(chunk_version, :chunk_version)

    cond do
      is_nil(previous_version) ->
        {:ok, ledger,
         delta_event(
           :unknown_base,
           logical_scene_id,
           chunk_coord,
           previous_version,
           base_version,
           chunk_version
         )}

      chunk_version < previous_version ->
        {:ok, ledger,
         delta_event(
           :stale,
           logical_scene_id,
           chunk_coord,
           previous_version,
           base_version,
           chunk_version
         )}

      base_version != previous_version ->
        {:ok, ledger,
         delta_event(
           :base_mismatch,
           logical_scene_id,
           chunk_coord,
           previous_version,
           base_version,
           chunk_version
         )}

      true ->
        {:ok, Map.put(ledger, key, chunk_version),
         delta_event(
           :recorded,
           logical_scene_id,
           chunk_coord,
           previous_version,
           base_version,
           chunk_version
         )}
    end
  end

  defp event(status, frame_kind, logical_scene_id, chunk_coord, previous_version, chunk_version) do
    %{
      status: status,
      frame_kind: frame_kind,
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      previous_version: previous_version,
      chunk_version: chunk_version
    }
  end

  defp delta_event(
         status,
         logical_scene_id,
         chunk_coord,
         previous_version,
         base_version,
         chunk_version
       ) do
    event(status, :delta, logical_scene_id, chunk_coord, previous_version, chunk_version)
    |> Map.put(:base_chunk_version, base_version)
  end

  defp decode_failed(frame_kind, reason) do
    %{status: :decode_failed, frame_kind: frame_kind, reason: reason}
  end

  defp normalize_ledger(nil), do: %{}

  defp normalize_ledger(ledger) when is_map(ledger) do
    Map.new(ledger, fn {{logical_scene_id, chunk_coord}, chunk_version} ->
      {key!(logical_scene_id, chunk_coord), non_negative_integer!(chunk_version, :chunk_version)}
    end)
  end

  defp normalize_known_versions(nil), do: %{}

  defp normalize_known_versions(known_versions) when is_map(known_versions) do
    Map.new(known_versions, fn {chunk_coord, chunk_version} ->
      {coord!(chunk_coord), non_negative_integer!(chunk_version, :known_version)}
    end)
  end

  defp normalize_known_versions(known_versions) when is_list(known_versions) do
    Map.new(known_versions, fn
      %{chunk_coord: chunk_coord, chunk_version: chunk_version} ->
        {coord!(chunk_coord), non_negative_integer!(chunk_version, :known_version)}

      {chunk_coord, chunk_version} ->
        {coord!(chunk_coord), non_negative_integer!(chunk_version, :known_version)}
    end)
  end

  defp key!(logical_scene_id, chunk_coord) do
    {non_negative_integer!(logical_scene_id, :logical_scene_id), coord!(chunk_coord)}
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp non_negative_integer!(value, _key) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer!(value, key) do
    raise ArgumentError, "#{inspect(key)} must be a non-negative integer, got: #{inspect(value)}"
  end
end
