defmodule SceneServer.Voxel.ChunkDirectory do
  @moduledoc """
  Scene-side directory for hot voxel chunk processes.

  The directory gives Gate/World-facing code a stable API for resolving a chunk
  by `{logical_scene_id, chunk_coord}`. It starts chunk processes lazily under
  `SceneServer.VoxelChunkSup` and exposes snapshot payload reads for the first
  server-authoritative subscription path.
  """

  use GenServer

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.ChunkProcess

  @doc "Starts the chunk directory."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Ensures a chunk process exists and returns its pid."
  def ensure_chunk(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:ensure_chunk, attrs})
  end

  @doc "Returns a chunk snapshot payload suitable for `GateServer.Codec` raw downlink."
  def snapshot_payload(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:snapshot_payload, attrs})
  end

  @doc """
  Subscribes a process to a hot chunk after World has supplied the current lease.

  The directory only resolves or starts the chunk. `ChunkProcess` owns the
  monitor, immediate snapshot decision, and later snapshot fallback pushes.
  """
  def subscribe(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:subscribe, attrs})
  end

  @doc """
  Removes a process subscription from a known hot chunk.

  Unsubscribe is intentionally idempotent: if the directory has not started the
  chunk, the caller is already not subscribed through this directory.
  """
  def unsubscribe(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:unsubscribe, attrs})
  end

  @doc "Prewarms migration handoff data through the module-named chunk directory."
  def prewarm_handoff(handoff) do
    prewarm_handoff(__MODULE__, handoff, [])
  end

  @doc "Prewarms migration handoff data through an explicit chunk directory."
  def prewarm_handoff(server, handoff, opts \\ []) do
    GenServer.call(server, {:prewarm_handoff, handoff, opts}, Keyword.get(opts, :timeout, 30_000))
  end

  @doc """
  Persists hot source chunks for one migration slice before World cutover.

  This is the Scene-side drain hook for migrations. It does not change routing
  or lease ownership; it only asks already-hot source chunk processes inside the
  slice to persist their latest storage with the old lease fence. Chunks that
  are not hot in this directory are reported as `:not_hot`.
  """
  def persist_handoff_slice(handoff, slice) when is_map(handoff) and is_map(slice) do
    persist_handoff_slice(__MODULE__, handoff, slice, [])
  end

  def persist_handoff_slice(server, handoff, slice) when is_map(handoff) and is_map(slice) do
    persist_handoff_slice(server, handoff, slice, [])
  end

  def persist_handoff_slice(server, handoff, slice, opts)
      when is_map(handoff) and is_map(slice) and is_list(opts) do
    GenServer.call(
      server,
      {:persist_handoff_slice, handoff, slice, opts},
      Keyword.get(opts, :timeout, 30_000)
    )
  end

  @doc """
  Applies a World-authorized voxel write intent to a hot chunk.

  The directory owns chunk lookup/startup only. `ChunkProcess` remains the owner
  of chunk state, lease-fenced persistence, and subscriber snapshot fallback.
  """
  def apply_intent(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:apply_intent, attrs})
  end

  @doc """
  Applies multiple World-authorized write intents to one chunk with one persist.

  This directory still owns only chunk lookup/startup. `ChunkProcess` owns the
  atomic mutation, persistence fence, and subscriber notification. All intents
  must target the same `{logical_scene_id, chunk_coord}`.
  """
  def apply_intents(server \\ __MODULE__, attrs_list) when is_list(attrs_list) do
    GenServer.call(server, {:apply_intents, attrs_list}, 30_000)
  end

  @doc """
  Reserves a transaction fence on the chunk for a future commit.

  The directory ensures the chunk exists and routes to `ChunkProcess.prepare_transaction/3`.
  """
  def prepare_transaction(server \\ __MODULE__, transaction_id, attrs)
      when is_binary(transaction_id) do
    GenServer.call(server, {:prepare_transaction, transaction_id, attrs})
  end

  @doc "Applies the previously fenced intent on the chunk and releases the fence."
  def commit_transaction(server \\ __MODULE__, transaction_id, attrs)
      when is_binary(transaction_id) do
    GenServer.call(server, {:commit_transaction, transaction_id, attrs})
  end

  @doc "Releases the chunk fence without applying. Idempotent."
  def abort_transaction(server \\ __MODULE__, transaction_id, attrs)
      when is_binary(transaction_id) do
    GenServer.call(server, {:abort_transaction, transaction_id, attrs})
  end

  @doc """
  Pushes a `ChunkInvalidate` payload to every subscriber of one chunk and
  forgets them. Returns `{:ok, %{subscriber_count: n, reason: reason}}` when
  the chunk is hot, or `{:error, :chunk_not_started}` if the directory has not
  spawned a process for that coord yet (no subscribers either way).

  See `SceneServer.Voxel.Codec.invalidate_reason_name/1` for the supported
  `reason` byte values.
  """
  def invalidate_chunk(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:invalidate_chunk, attrs})
  end

  @doc "Returns the known chunk process table for CLI/debug inspection."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       chunk_sup: Keyword.get(opts, :chunk_sup, SceneServer.VoxelChunkSup),
       snapshot_store: Keyword.get(opts, :snapshot_store, DataService.Voxel.ChunkSnapshotStore),
       chunks: %{}
     }}
  end

  @impl true
  def handle_call({:ensure_chunk, attrs}, _from, state) do
    attrs = normalize_attrs(attrs)
    {reply, state} = ensure_chunk_in_state(state, attrs)
    {:reply, reply, state}
  end

  def handle_call({:snapshot_payload, attrs}, _from, state) do
    attrs = normalize_attrs(attrs)

    case ensure_chunk_in_state(state, attrs) do
      {{:ok, chunk_pid}, next_state} ->
        case ChunkProcess.snapshot_payload(chunk_pid, attrs.request_id) do
          {:ok, payload} -> {:reply, {:ok, payload}, next_state}
          {:error, reason} -> {:reply, {:error, reason}, next_state}
        end

      {{:error, reason}, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:subscribe, attrs}, _from, state) do
    attrs = normalize_subscribe_attrs(attrs)

    case ensure_chunk_in_state(state, attrs) do
      {{:ok, chunk_pid}, next_state} ->
        opts = [
          request_id: attrs.request_id,
          send_snapshot?: attrs.send_snapshot?,
          known_version: attrs.known_version
        ]

        case ChunkProcess.subscribe(chunk_pid, attrs.subscriber, opts) do
          {:ok, payload} -> {:reply, {:ok, payload}, next_state}
          {:error, reason} -> {:reply, {:error, reason}, next_state}
        end

      {{:error, reason}, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  rescue
    _exception in [ArgumentError, KeyError] ->
      {:reply, {:error, :invalid_voxel_subscription}, state}
  end

  def handle_call({:unsubscribe, attrs}, _from, state) do
    case normalize_unsubscribe_attrs(attrs) do
      {:ok, attrs} ->
        key = {attrs.logical_scene_id, attrs.chunk_coord}

        reply =
          case Map.get(state.chunks, key) do
            pid when is_pid(pid) ->
              if Process.alive?(pid) do
                ChunkProcess.unsubscribe(pid, attrs.subscriber)
              else
                :ok
              end

            _other ->
              :ok
          end

        {:reply, reply, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prewarm_handoff, handoff, opts}, _from, state) do
    case normalize_handoff(handoff) do
      {:ok, handoff} ->
        {reply, next_state} = prewarm_handoff_in_state(state, handoff, opts)
        {:reply, reply, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:persist_handoff_slice, handoff, slice, _opts}, _from, state) do
    with {:ok, handoff} <- normalize_source_handoff(handoff),
         {:ok, slice} <- normalize_source_slice(slice) do
      reply = persist_handoff_slice_in_state(state, handoff, slice)
      {:reply, reply, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_intent, attrs}, _from, state) do
    case normalize_apply_intent_attrs(attrs) do
      {:ok, attrs} ->
        case ensure_chunk_in_state(state, attrs) do
          {{:ok, chunk_pid}, next_state} ->
            reply = ChunkProcess.apply_intent(chunk_pid, attrs)
            emit_apply_intent_result(attrs, reply)
            {:reply, reply, next_state}

          {{:error, reason}, next_state} ->
            {:reply, {:error, reason}, next_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_intents, []}, _from, state) do
    {:reply,
     {:ok,
      %{
        logical_scene_id: nil,
        chunk_coord: nil,
        chunk_version: 0,
        changed?: false,
        changed_count: 0,
        skipped_count: 0,
        persist_result: :unchanged,
        snapshot_payload: <<>>
      }}, state}
  end

  def handle_call({:apply_intents, attrs_list}, _from, state) when is_list(attrs_list) do
    case normalize_apply_intents_attrs(attrs_list) do
      {:ok, attrs, normalized_attrs} ->
        case ensure_chunk_in_state(state, attrs) do
          {{:ok, chunk_pid}, next_state} ->
            reply = ChunkProcess.apply_intents(chunk_pid, attrs_list)
            emit_apply_intents_result(attrs, normalized_attrs, reply)
            {:reply, reply, next_state}

          {{:error, reason}, next_state} ->
            {:reply, {:error, reason}, next_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prepare_transaction, transaction_id, attrs}, _from, state) do
    case normalize_apply_intent_attrs(attrs) do
      {:ok, attrs} ->
        case ensure_chunk_in_state(state, attrs) do
          {{:ok, chunk_pid}, next_state} ->
            reply = ChunkProcess.prepare_transaction(chunk_pid, transaction_id, attrs)
            {:reply, reply, next_state}

          {{:error, reason}, next_state} ->
            {:reply, {:error, reason}, next_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:commit_transaction, transaction_id, attrs}, _from, state) do
    case normalize_chunk_key(attrs) do
      {:ok, key} ->
        case fetch_chunk_pid(state, key) do
          {:ok, chunk_pid} ->
            {:reply, ChunkProcess.commit_transaction(chunk_pid, transaction_id), state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:abort_transaction, transaction_id, attrs}, _from, state) do
    case normalize_chunk_key(attrs) do
      {:ok, key} ->
        case fetch_chunk_pid(state, key) do
          {:ok, chunk_pid} ->
            {:reply, ChunkProcess.abort_transaction(chunk_pid, transaction_id), state}

          {:error, :chunk_not_started} ->
            {:reply, :ok, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:invalidate_chunk, attrs}, _from, state) do
    reason = Map.get(attrs, :reason, 0x00)

    with {:ok, key} <- normalize_chunk_key(attrs),
         {:ok, chunk_pid} <- fetch_chunk_pid(state, key) do
      {:reply, ChunkProcess.invalidate_subscribers(chunk_pid, reason), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    chunks =
      Map.new(state.chunks, fn {key, pid} ->
        {key, %{pid: inspect(pid), alive?: Process.alive?(pid)}}
      end)

    {:reply, %{chunk_count: map_size(state.chunks), chunks: chunks}, state}
  end

  defp ensure_chunk_in_state(state, attrs) do
    key = {attrs.logical_scene_id, attrs.chunk_coord}

    case Map.get(state.chunks, key) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          maybe_apply_chunk_lease(pid, Map.get(attrs, :lease))
          {{:ok, pid}, state}
        else
          start_chunk(state, key, attrs)
        end

      _other ->
        start_chunk(state, key, attrs)
    end
  end

  defp start_chunk(state, key, attrs) do
    chunk_opts = [
      logical_scene_id: attrs.logical_scene_id,
      chunk_coord: attrs.chunk_coord,
      snapshot_store: state.snapshot_store
    ]

    chunk_opts =
      case attrs.lease do
        nil -> chunk_opts
        lease -> Keyword.put(chunk_opts, :lease, lease)
      end

    case SceneServer.VoxelChunkSup.start_chunk(state.chunk_sup, chunk_opts) do
      {:ok, pid} ->
        CliObserve.emit("voxel_chunk_started", %{
          logical_scene_id: attrs.logical_scene_id,
          chunk_coord: attrs.chunk_coord,
          pid: pid
        })

        {{:ok, pid}, put_in(state.chunks[key], pid)}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp maybe_apply_chunk_lease(_pid, nil), do: :ok

  defp maybe_apply_chunk_lease(pid, lease) do
    _ = ChunkProcess.apply_lease(pid, lease)
    :ok
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    %{
      request_id: Map.get(attrs, :request_id, 0),
      logical_scene_id: Map.fetch!(attrs, :logical_scene_id),
      chunk_coord:
        attrs
        |> Map.get(:chunk_coord, Map.get(attrs, :center_chunk))
        |> coord!(),
      lease: Map.get(attrs, :lease)
    }
  end

  defp normalize_subscribe_attrs(attrs) when is_map(attrs) do
    raw_attrs = attrs
    attrs = normalize_attrs(raw_attrs)

    Map.merge(attrs, %{
      subscriber: Map.get(raw_attrs, :subscriber, self()),
      send_snapshot?: Map.get(raw_attrs, :send_snapshot?, true),
      known_version: Map.get(raw_attrs, :known_version)
    })
  end

  defp normalize_unsubscribe_attrs(attrs) when is_map(attrs) do
    {:ok,
     %{
       logical_scene_id: Map.fetch!(attrs, :logical_scene_id),
       chunk_coord:
         attrs
         |> Map.get(:chunk_coord, Map.get(attrs, :center_chunk))
         |> coord!(),
       subscriber: Map.get(attrs, :subscriber, self())
     }}
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_voxel_subscription}
  end

  defp normalize_unsubscribe_attrs(_attrs), do: {:error, :invalid_voxel_subscription}

  defp normalize_handoff(handoff) when is_map(handoff) do
    planned_slices = Map.get(handoff, :planned_slices, [])

    cond do
      planned_slices == [] ->
        {:error, :migration_handoff_has_no_slices}

      true ->
        {:ok,
         %{
           migration_id: Map.fetch!(handoff, :migration_id),
           logical_scene_id: Map.fetch!(handoff, :logical_scene_id),
           region_id: Map.fetch!(handoff, :region_id),
           new_lease: Map.fetch!(handoff, :new_lease),
           planned_slices: Enum.map(planned_slices, &normalize_slice!/1)
         }}
    end
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_migration_handoff}
  end

  defp normalize_handoff(_handoff), do: {:error, :invalid_migration_handoff}

  defp normalize_slice!(slice) when is_map(slice) do
    min_coord = coord!(Map.fetch!(slice, :bounds_chunk_min))
    max_coord = coord!(Map.fetch!(slice, :bounds_chunk_max))
    validate_slice_bounds!(min_coord, max_coord)

    %{
      slice_id: Map.fetch!(slice, :slice_id),
      bounds_chunk_min: min_coord,
      bounds_chunk_max: max_coord
    }
  end

  defp validate_slice_bounds!({min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    unless min_x < max_x and min_y < max_y and min_z < max_z do
      raise ArgumentError,
            "invalid prewarm slice bounds: #{inspect({min_x, min_y, min_z})}..#{inspect({max_x, max_y, max_z})}"
    end
  end

  defp prewarm_handoff_in_state(state, handoff, _opts) do
    chunk_coords =
      handoff.planned_slices
      |> Enum.flat_map(&slice_chunk_coords/1)
      |> Enum.uniq()

    Enum.reduce_while(chunk_coords, {:ok, state, []}, fn chunk_coord, {:ok, acc_state, results} ->
      case prewarm_chunk(acc_state, handoff, chunk_coord) do
        {{:ok, result}, next_state} ->
          {:cont, {:ok, next_state, [result | results]}}

        {{:error, reason}, next_state} ->
          {:halt, {:error, reason, next_state}}
      end
    end)
    |> case do
      {:ok, next_state, results} ->
        results = Enum.reverse(results)

        summary = %{
          migration_id: handoff.migration_id,
          logical_scene_id: handoff.logical_scene_id,
          region_id: handoff.region_id,
          chunk_count: length(results),
          loaded_count: Enum.count(results, &(&1.status == :loaded)),
          empty_count: Enum.count(results, &(&1.status == :empty)),
          chunks: results
        }

        CliObserve.emit("voxel_migration_prewarm_applied", summary)
        {{:ok, summary}, next_state}

      {:error, reason, next_state} ->
        {{:error, reason}, next_state}
    end
  end

  defp persist_handoff_slice_in_state(state, handoff, slice) do
    chunk_coords = slice_chunk_coords(slice)

    results =
      Enum.map(chunk_coords, fn chunk_coord ->
        persist_source_chunk(state, handoff, chunk_coord)
      end)

    summary = %{
      migration_id: handoff.migration_id,
      logical_scene_id: handoff.logical_scene_id,
      region_id: handoff.region_id,
      slice_id: slice.slice_id,
      chunk_count: length(results),
      persisted_count: Enum.count(results, &(&1.status == :persisted)),
      not_hot_count: Enum.count(results, &(&1.status == :not_hot)),
      error_count: Enum.count(results, &(&1.status == :error)),
      max_chunk_version: max_chunk_version(results),
      chunks: results
    }

    CliObserve.emit("voxel_migration_source_slice_persisted", summary)

    if summary.error_count == 0 do
      {:ok, summary}
    else
      {:error, :migration_source_slice_persist_failed}
    end
  end

  defp persist_source_chunk(state, handoff, chunk_coord) do
    key = {handoff.logical_scene_id, chunk_coord}

    case Map.get(state.chunks, key) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          persist_live_source_chunk(pid, handoff, chunk_coord)
        else
          %{chunk_coord: chunk_coord, status: :not_hot}
        end

      _other ->
        %{chunk_coord: chunk_coord, status: :not_hot}
    end
  end

  defp persist_live_source_chunk(chunk_pid, handoff, chunk_coord) do
    with {:ok, _lease} <- ChunkProcess.apply_lease(chunk_pid, handoff.old_lease),
         {:ok, persist_result} <- ChunkProcess.persist(chunk_pid),
         %{chunk_version: chunk_version} <- ChunkProcess.debug_state(chunk_pid) do
      %{
        chunk_coord: chunk_coord,
        status: :persisted,
        persist_result: persist_result,
        chunk_version: chunk_version
      }
    else
      {:error, reason} ->
        %{
          chunk_coord: chunk_coord,
          status: :error,
          reason: reason
        }
    end
  end

  defp prewarm_chunk(state, handoff, chunk_coord) do
    attrs = %{
      logical_scene_id: handoff.logical_scene_id,
      chunk_coord: chunk_coord,
      lease: handoff.new_lease
    }

    case ensure_chunk_in_state(state, attrs) do
      {{:ok, chunk_pid}, next_state} ->
        reply =
          case DataService.Voxel.ChunkSnapshotStore.get_snapshot(
                 state.snapshot_store,
                 handoff.logical_scene_id,
                 chunk_coord
               ) do
            {:ok, snapshot} ->
              load_prewarm_snapshot(chunk_pid, handoff, chunk_coord, snapshot)

            {:error, :snapshot_not_found} ->
              apply_empty_prewarm_lease(chunk_pid, handoff, chunk_coord)

            {:error, reason} ->
              {:error, reason}
          end

        {reply, next_state}

      {{:error, reason}, next_state} ->
        {{:error, reason}, next_state}
    end
  end

  defp load_prewarm_snapshot(chunk_pid, handoff, chunk_coord, snapshot) do
    case ChunkProcess.load_snapshot(chunk_pid, %{snapshot: snapshot, lease: handoff.new_lease}) do
      {:ok, result} ->
        {:ok,
         %{
           chunk_coord: chunk_coord,
           status: :loaded,
           chunk_version: result.chunk_version,
           changed?: result.changed?
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_empty_prewarm_lease(chunk_pid, handoff, chunk_coord) do
    case ChunkProcess.apply_lease(chunk_pid, handoff.new_lease) do
      {:ok, _lease} ->
        case ChunkProcess.debug_state(chunk_pid) do
          %{chunk_version: chunk_version} ->
            {:ok, %{chunk_coord: chunk_coord, status: :empty, chunk_version: chunk_version}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp max_chunk_version(chunks) do
    chunks
    |> Enum.map(&Map.get(&1, :chunk_version, 0))
    |> Enum.max(fn -> 0 end)
  end

  defp slice_chunk_coords(%{bounds_chunk_min: min_coord, bounds_chunk_max: max_coord}) do
    {min_x, min_y, min_z} = min_coord
    {max_x, max_y, max_z} = max_coord

    for x <- min_x..(max_x - 1),
        y <- min_y..(max_y - 1),
        z <- min_z..(max_z - 1) do
      {x, y, z}
    end
  end

  defp normalize_apply_intent_attrs(attrs) when is_map(attrs) do
    normalized = normalize_attrs(attrs)

    if is_nil(normalized.lease) do
      {:error, :missing_lease}
    else
      {:ok, Map.merge(attrs, normalized)}
    end
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_voxel_intent}
  end

  defp normalize_apply_intent_attrs(_attrs), do: {:error, :invalid_voxel_intent}

  defp normalize_apply_intents_attrs([first | _rest] = attrs_list) do
    with {:ok, first_attrs} <- normalize_apply_intent_attrs(first),
         {:ok, normalized_attrs} <- normalize_apply_intents_targets(attrs_list, first_attrs) do
      {:ok, first_attrs, normalized_attrs}
    end
  end

  defp normalize_apply_intents_attrs(_attrs_list), do: {:error, :invalid_voxel_intent}

  defp normalize_apply_intents_targets(attrs_list, first_attrs) do
    attrs_list
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case normalize_apply_intent_attrs(attrs) do
        {:ok, attrs} ->
          if attrs.logical_scene_id == first_attrs.logical_scene_id and
               attrs.chunk_coord == first_attrs.chunk_coord do
            {:cont, {:ok, [attrs | acc]}}
          else
            {:halt, {:error, :batch_cross_chunk_unsupported}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, attrs} -> {:ok, Enum.reverse(attrs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_chunk_key(attrs) when is_map(attrs) do
    with {:ok, logical_scene_id} <- fetch_logical_scene_id(attrs),
         {:ok, chunk_coord} <- fetch_chunk_coord(attrs) do
      {:ok, {logical_scene_id, chunk_coord}}
    end
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_voxel_chunk_key}
  end

  defp normalize_chunk_key(_attrs), do: {:error, :invalid_voxel_chunk_key}

  defp fetch_logical_scene_id(attrs) do
    case Map.get(attrs, :logical_scene_id) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, :missing_logical_scene_id}
    end
  end

  defp fetch_chunk_coord(attrs) do
    case Map.get(attrs, :chunk_coord) || Map.get(attrs, :center_chunk) do
      {x, y, z} when is_integer(x) and is_integer(y) and is_integer(z) -> {:ok, {x, y, z}}
      [x, y, z] when is_integer(x) and is_integer(y) and is_integer(z) -> {:ok, {x, y, z}}
      _other -> {:error, :missing_chunk_coord}
    end
  end

  defp fetch_chunk_pid(state, {_logical_scene_id, _chunk_coord} = key) do
    case Map.get(state.chunks, key) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :chunk_not_started}

      _other ->
        {:error, :chunk_not_started}
    end
  end

  defp normalize_source_handoff(handoff) when is_map(handoff) do
    old_lease = Map.fetch!(handoff, :old_lease)

    if is_nil(old_lease) do
      {:error, :missing_source_lease}
    else
      {:ok,
       %{
         migration_id: Map.fetch!(handoff, :migration_id),
         logical_scene_id: Map.fetch!(handoff, :logical_scene_id),
         region_id: Map.fetch!(handoff, :region_id),
         old_lease: old_lease
       }}
    end
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_migration_handoff}
  end

  defp normalize_source_handoff(_handoff), do: {:error, :invalid_migration_handoff}

  defp normalize_source_slice(slice) when is_map(slice) do
    min_coord = coord!(Map.fetch!(slice, :bounds_chunk_min))
    max_coord = coord!(Map.fetch!(slice, :bounds_chunk_max))
    validate_slice_bounds!(min_coord, max_coord)

    {:ok,
     %{
       slice_id: Map.fetch!(slice, :slice_id),
       bounds_chunk_min: min_coord,
       bounds_chunk_max: max_coord
     }}
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_migration_slice}
  end

  defp normalize_source_slice(_slice), do: {:error, :invalid_migration_slice}

  defp emit_apply_intent_result(attrs, reply) do
    CliObserve.emit("voxel_directory_intent_result", fn ->
      %{
        logical_scene_id: attrs.logical_scene_id,
        chunk_coord: attrs.chunk_coord,
        result: inspect(reply)
      }
    end)
  end

  defp emit_apply_intents_result(attrs, normalized_attrs, reply) do
    CliObserve.emit("voxel_directory_intents_result", fn ->
      %{
        logical_scene_id: attrs.logical_scene_id,
        chunk_coord: attrs.chunk_coord,
        intent_count: length(normalized_attrs),
        result: inspect(reply)
      }
    end)
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end
end
