defmodule GateServer.Voxel.ClientAckLedger do
  @moduledoc """
  Tracks chunk versions explicitly acknowledged by one reliable Gate client.

  `ChunkVersionLedger` records what Gate has forwarded. This ledger records what
  the client has confirmed after that handoff. It is still a Gate-local
  transport hint: Scene remains the chunk truth owner, and World remains the
  partition/lease authority.
  """

  alias GateServer.Voxel.ChunkVersionLedger
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec

  @type chunk_coord :: {integer(), integer(), integer()}
  @type key :: {non_neg_integer(), chunk_coord()}
  @type t :: %{optional(key()) => non_neg_integer()}

  @doc "Returns an empty per-connection client ACK ledger."
  @spec new() :: t()
  def new, do: %{}

  @doc """
  Records one client ACK when it does not exceed the version Gate forwarded.

  ACKs ahead of the forwarded ledger are rejected. Duplicate ACKs are accepted
  as idempotent. Stale ACKs and ACKs for chunks whose forwarded cache has
  already been pruned are ignored rather than promoted into reusable known
  versions.
  """
  @spec record_ack(
          t() | nil,
          ChunkVersionLedger.t() | nil,
          non_neg_integer(),
          chunk_coord(),
          non_neg_integer()
        ) :: {:ok, t(), map()} | {:error, t(), map()}
  def record_ack(ack_ledger, forwarded_ledger, logical_scene_id, chunk_coord, ack_version) do
    ack_ledger = normalize_ledger(ack_ledger)
    key = key!(logical_scene_id, chunk_coord)
    ack_version = non_negative_integer!(ack_version, :ack_version)
    forwarded_version = forwarded_version(forwarded_ledger, logical_scene_id, chunk_coord)
    previous_ack_version = Map.get(ack_ledger, key)

    cond do
      previous_ack_version == ack_version ->
        {:ok, ack_ledger,
         event(
           :duplicate_ack,
           logical_scene_id,
           chunk_coord,
           previous_ack_version,
           forwarded_version,
           ack_version
         )}

      is_integer(previous_ack_version) and ack_version < previous_ack_version ->
        {:ok, ack_ledger,
         event(
           :stale_ack,
           logical_scene_id,
           chunk_coord,
           previous_ack_version,
           forwarded_version,
           ack_version
         )}

      is_nil(forwarded_version) ->
        {:ok, ack_ledger,
         event(
           :ack_without_forwarded,
           logical_scene_id,
           chunk_coord,
           previous_ack_version,
           forwarded_version,
           ack_version
         )}

      ack_version > forwarded_version ->
        {:error, ack_ledger,
         event(
           :ack_ahead_of_forwarded,
           logical_scene_id,
           chunk_coord,
           previous_ack_version,
           forwarded_version,
           ack_version
         )}

      true ->
        {:ok, Map.put(ack_ledger, key, ack_version),
         event(
           :ack_recorded,
           logical_scene_id,
           chunk_coord,
           previous_ack_version,
           forwarded_version,
           ack_version
         )}
    end
  end

  @doc """
  Records a batch of client known-version ACKs after forwarded-version checks.

  The caller may pass the `known` list from `ChunkSubscribe` or the explicit
  `VoxelChunkAck` frame. Each entry is accepted only when Gate has already
  forwarded at least that version to this connection.
  """
  @spec record_known_versions(
          t() | nil,
          ChunkVersionLedger.t() | nil,
          non_neg_integer(),
          map() | list() | nil
        ) :: {t(), map()}
  def record_known_versions(ack_ledger, forwarded_ledger, logical_scene_id, known_versions) do
    entries = normalize_known_versions(known_versions)

    {ledger, events} =
      Enum.reduce(entries, {normalize_ledger(ack_ledger), []}, fn {chunk_coord, chunk_version},
                                                                  {ledger, events} ->
        {_result, next_ledger, event} =
          case record_ack(ledger, forwarded_ledger, logical_scene_id, chunk_coord, chunk_version) do
            {:ok, next_ledger, event} -> {:ok, next_ledger, event}
            {:error, next_ledger, event} -> {:error, next_ledger, event}
          end

        {next_ledger, [event | events]}
      end)

    events = Enum.reverse(events)
    accepted_count = Enum.count(events, &accepted_status?/1)
    ignored_count = Enum.count(events, &ignored_status?/1)
    rejected_count = length(events) - accepted_count - ignored_count

    {ledger,
     %{
       status: batch_status(length(events), accepted_count, ignored_count, rejected_count),
       logical_scene_id: non_negative_integer!(logical_scene_id, :logical_scene_id),
       accepted_count: accepted_count,
       ignored_count: ignored_count,
       rejected_count: rejected_count,
       ack_count: length(events),
       events: events
     }}
  end

  @doc "Returns acknowledged chunk versions for one logical scene."
  @spec known_versions(t() | nil, non_neg_integer()) :: %{
          optional(chunk_coord()) => non_neg_integer()
        }
  def known_versions(ledger, logical_scene_id) do
    logical_scene_id = non_negative_integer!(logical_scene_id, :logical_scene_id)

    ledger
    |> normalize_ledger()
    |> Enum.flat_map(fn
      {{^logical_scene_id, chunk_coord}, ack_version} -> [{chunk_coord, ack_version}]
      {_key, _ack_version} -> []
    end)
    |> Map.new()
  end

  @doc "Clears one retained client ACK."
  @spec clear_chunk(t() | nil, non_neg_integer(), chunk_coord()) :: t()
  def clear_chunk(ledger, logical_scene_id, chunk_coord) do
    Map.delete(normalize_ledger(ledger), key!(logical_scene_id, chunk_coord))
  end

  @doc "Clears the acknowledged version for a Scene `ChunkInvalidate` payload."
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
        previous_ack_version = Map.get(ledger, key)

        {:ok, Map.delete(ledger, key),
         %{
           status: if(is_nil(previous_ack_version), do: :not_acked, else: :cleared),
           frame_kind: :invalidate,
           logical_scene_id: logical_scene_id,
           chunk_coord: chunk_coord,
           previous_ack_version: previous_ack_version,
           reason: reason,
           reason_name: reason_name
         }}

      {:error, reason} ->
        {:error, ledger, %{status: :decode_failed, frame_kind: :invalidate, reason: reason}}
    end
  end

  @doc "Returns a deterministic ACK list useful in tests and debug output."
  @spec to_sorted_list(t() | nil) :: [{non_neg_integer(), chunk_coord(), non_neg_integer()}]
  def to_sorted_list(ledger) do
    ledger
    |> normalize_ledger()
    |> Enum.map(fn {{logical_scene_id, chunk_coord}, ack_version} ->
      {logical_scene_id, chunk_coord, ack_version}
    end)
    |> Enum.sort()
  end

  @doc "Formats a bounded deterministic ACK summary for CLI/debug probes."
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

  defp forwarded_version(forwarded_ledger, logical_scene_id, chunk_coord) do
    forwarded_ledger
    |> ChunkVersionLedger.known_versions(logical_scene_id)
    |> Map.get(coord!(chunk_coord))
  end

  defp event(
         status,
         logical_scene_id,
         chunk_coord,
         previous_ack_version,
         forwarded_version,
         ack_version
       ) do
    %{
      status: status,
      logical_scene_id: non_negative_integer!(logical_scene_id, :logical_scene_id),
      chunk_coord: coord!(chunk_coord),
      previous_ack_version: previous_ack_version,
      forwarded_version: forwarded_version,
      ack_version: ack_version
    }
  end

  defp normalize_ledger(nil), do: %{}

  defp normalize_ledger(ledger) when is_map(ledger) do
    Map.new(ledger, fn {{logical_scene_id, chunk_coord}, ack_version} ->
      {key!(logical_scene_id, chunk_coord), non_negative_integer!(ack_version, :ack_version)}
    end)
  end

  defp normalize_known_versions(nil), do: []

  defp normalize_known_versions(known_versions) when is_map(known_versions) do
    Enum.map(known_versions, fn {chunk_coord, chunk_version} ->
      {coord!(chunk_coord), non_negative_integer!(chunk_version, :chunk_version)}
    end)
  end

  defp normalize_known_versions(known_versions) when is_list(known_versions) do
    Enum.map(known_versions, fn
      %{chunk_coord: chunk_coord, chunk_version: chunk_version} ->
        {coord!(chunk_coord), non_negative_integer!(chunk_version, :chunk_version)}

      {chunk_coord, chunk_version} ->
        {coord!(chunk_coord), non_negative_integer!(chunk_version, :chunk_version)}
    end)
  end

  defp accepted_status?(%{status: status}) do
    status in [:ack_recorded, :duplicate_ack]
  end

  defp ignored_status?(%{status: status}) do
    status in [:ack_without_forwarded, :stale_ack]
  end

  defp batch_status(0, _accepted_count, _ignored_count, _rejected_count), do: :empty
  defp batch_status(_total, _accepted_count, _ignored_count, 0), do: :ok
  defp batch_status(total, 0, 0, total), do: :rejected
  defp batch_status(_total, _accepted_count, _ignored_count, _rejected_count), do: :partial

  defp key!(logical_scene_id, chunk_coord) do
    {non_negative_integer!(logical_scene_id, :logical_scene_id), coord!(chunk_coord)}
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp non_negative_integer!(value, _field) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer!(value, field) do
    raise ArgumentError, "expected #{field} as non-negative integer, got: #{inspect(value)}"
  end
end
