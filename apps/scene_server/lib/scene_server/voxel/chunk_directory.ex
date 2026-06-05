defmodule SceneServer.Voxel.ChunkDirectory do
  @moduledoc """
  Scene-side **无状态 facade**，把 Gate/World 侧调用路由到权威 chunk 进程。

  The directory gives Gate/World-facing code a stable API for resolving a chunk
  by `{logical_scene_id, chunk_coord}`. It starts chunk processes lazily under
  `SceneServer.VoxelChunkSup` and exposes snapshot payload reads for the first
  server-authoritative subscription path.

  ## 进程身份不在这里（阶段3.1）

  本进程**不再持有 chunk 进程表**。chunk 的进程身份（"谁是
  `{logical_scene_id, chunk_coord}` 的权威"）唯一真相源是
  `SceneServer.Voxel.ChunkRegistry`（`Registry` `:unique`）：

  * `ensure_chunk` 先 `ChunkRegistry.lookup/2`；未注册时经
    `VoxelChunkSup.start_chunk` 启动，via-tuple 注册保证去重——并发/重复
    启动会拿到 `{:error, {:already_started, pid}}`，facade 直接复用该 pid。
  * 所有 lookup（`lookup_chunk_pid` / `unsubscribe` / 事务路由 / 迁移持久化）
    都经注册表解析，**不读本进程状态**。
  * facade 进程崩溃重启**不会**产生第二个权威进程：权威进程独立挂在
    `VoxelChunkSup` 下，由注册表裁决单主，与 facade 生命周期解耦。

  facade 自身仍是一个 GenServer：它 monitor 它启动的 chunk 进程，chunk 崩溃
  时发 `voxel_chunk_directory_chunk_down` observe 事件供 World/运维观测。它
  **不**缓存 pid，因此 monitor 仅用于事件，不影响路由正确性。
  """

  use GenServer

  alias SceneServer.CliObserve
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.ChunkRegistry

  @chunk_call_timeout_ms 15_000
  @collision_query_timeout_ms 1_000
  @collision_directory_call_timeout_ms @collision_query_timeout_ms + 250

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
  Routes a read-only collision occupancy query to the owning hot chunk process.

  `ChunkDirectory` owns lookup/startup only. `ChunkProcess` owns the voxel
  truth and validates the local macro/micro samples.
  """
  def collision_query(
        server \\ __MODULE__,
        attrs,
        timeout \\ @collision_directory_call_timeout_ms
      ) do
    GenServer.call(server, {:collision_query, attrs}, timeout)
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
  Phase 4 (D8):wipes every micro slot owned by `(object_id, part_id)` in
  the named chunk, refreshes object refs, and persists. Idempotent — a
  chunk that has no matching slots is a cheap no-op.

  `attrs` requires `:logical_scene_id`, `:chunk_coord`, `:object_id`,
  `:part_id`.
  """
  def destroy_part(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:destroy_part, attrs})
  end

  @doc """
  Phase 4 (D9):drops any `ChunkObjectRef[]` entry pointing at the dead
  `object_id`. Defensive cleanup — under normal flow `destroy_part`
  already cleared the underlying layers and the next refresh removes the
  stale ChunkObjectRef.

  Idempotent.
  """
  def cleanup_object_refs(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:cleanup_object_refs, attrs})
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

  @doc """
  Look up an already-started ChunkProcess pid by `{logical_scene_id, chunk_coord}`.

  Returns `{:ok, pid}` if the directory has a registered, alive chunk process,
  or `:not_started` if the directory has no entry for that coord (or the
  registered pid is no longer alive).

  Phase 4-bis (D1):used by `ObjectRegistry` to dispatch ObjectStateDelta
  broadcasts to chunks affected by an object lifecycle event, **without**
  starting a new chunk process. If the chunk is not hot,the broadcast
  for that chunk is silently dropped(any subscriber would have to
  re-subscribe and re-snapshot anyway,which carries the current truth).
  """
  @spec lookup_chunk_pid(GenServer.server(), non_neg_integer(), {integer(), integer(), integer()}) ::
          {:ok, pid()} | :not_started
  def lookup_chunk_pid(server \\ __MODULE__, logical_scene_id, chunk_coord) do
    GenServer.call(server, {:lookup_chunk_pid, logical_scene_id, chunk_coord})
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
       # 阶段3.1：进程身份注册表名。facade 经它解析 pid，自己不持进程表。
       chunk_registry: Keyword.get(opts, :chunk_registry, ChunkRegistry.default_name()),
       chunk_call_timeout_ms: Keyword.get(opts, :chunk_call_timeout_ms, @chunk_call_timeout_ms),
       collision_query_timeout_ms:
         Keyword.get(opts, :collision_query_timeout_ms, @collision_query_timeout_ms),
       # monitor_ref => {logical_scene_id, chunk_coord}。仅用于崩溃 observe，
       # 不参与路由（路由唯一真相源是注册表）。
       chunk_monitors: %{}
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

  def handle_call({:collision_query, attrs}, _from, state) do
    attrs = normalize_attrs(attrs)

    case ensure_chunk_in_state(state, attrs) do
      {{:ok, chunk_pid}, next_state} ->
        query_attrs = Map.take(attrs, [:samples])

        collision_query_timeout_ms =
          collision_query_timeout_ms(attrs, state.collision_query_timeout_ms)

        case safe_chunk_call(:collision_query, fn ->
               ChunkProcess.collision_query(
                 chunk_pid,
                 query_attrs,
                 collision_query_timeout_ms
               )
             end) do
          {:ok, result} -> {:reply, {:ok, result}, next_state}
          {:error, reason} -> {:reply, {:error, reason}, next_state}
        end

      {{:error, reason}, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  rescue
    _exception in [ArgumentError, KeyError] ->
      {:reply, {:error, :invalid_collision_query}, state}
  end

  def handle_call({:subscribe, attrs}, _from, state) do
    attrs = normalize_subscribe_attrs(attrs)

    case ensure_chunk_in_state(state, attrs) do
      {{:ok, chunk_pid}, next_state} ->
        opts = [
          request_id: attrs.request_id,
          send_snapshot?: attrs.send_snapshot?,
          known_version: attrs.known_version,
          delivery_format: attrs.delivery_format,
          tier: attrs.tier
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
        reply =
          case ChunkRegistry.lookup(
                 attrs.logical_scene_id,
                 attrs.chunk_coord,
                 state.chunk_registry
               ) do
            {:ok, pid} -> ChunkProcess.unsubscribe(pid, attrs.subscriber)
            # 注册表无此 chunk → 调用方本就未经本 facade 订阅，幂等返回 :ok。
            :not_started -> :ok
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
    case normalize_prepare_transaction_attrs(attrs) do
      {:ok, route_attrs, intents, prepare_opts} ->
        case ensure_chunk_in_state(state, route_attrs) do
          {{:ok, chunk_pid}, next_state} ->
            reply =
              ChunkProcess.prepare_transaction(chunk_pid, transaction_id, intents, prepare_opts)

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

  def handle_call({:destroy_part, attrs}, _from, state) do
    case normalize_chunk_key(attrs) do
      {:ok, key} ->
        case fetch_chunk_pid(state, key) do
          {:ok, chunk_pid} ->
            {:reply, ChunkProcess.destroy_part(chunk_pid, attrs), state}

          # Chunk not started — no slots there to wipe.
          {:error, :chunk_not_started} ->
            {:reply, :ok, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cleanup_object_refs, attrs}, _from, state) do
    case normalize_chunk_key(attrs) do
      {:ok, key} ->
        case fetch_chunk_pid(state, key) do
          {:ok, chunk_pid} ->
            {:reply, ChunkProcess.cleanup_object_refs(chunk_pid, attrs), state}

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

  def handle_call({:lookup_chunk_pid, logical_scene_id, chunk_coord}, _from, state) do
    # 阶段3.1：facade 绝不把死 pid 返回给调用方。注册表对死条目的摘除是异步的
    # （Registry 收到被监控进程 :DOWN 后才删），存在一个"已死但仍注册"的窗口。
    # 这里主动校验 alive：死 pid 视同 :not_started，调用方据此走 re-subscribe /
    # 重新解析，等监督树按 :transient 重启出新权威进程后再解析到活的 pid。
    reply =
      case ChunkRegistry.lookup(logical_scene_id, chunk_coord, state.chunk_registry) do
        {:ok, pid} ->
          if Process.alive?(pid), do: {:ok, pid}, else: :not_started

        :not_started ->
          :not_started
      end

    {:reply, reply, state}
  end

  def handle_call(:snapshot, _from, state) do
    # 阶段3.1：debug 视图从注册表枚举，不读 facade 自身状态（无进程表）。
    chunks =
      state.chunk_registry
      |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
      |> Map.new(fn {key, pid} ->
        {key, %{pid: inspect(pid), alive?: Process.alive?(pid)}}
      end)

    {:reply, %{chunk_count: map_size(chunks), chunks: chunks}, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
    # 阶段3.1：facade monitor 到它启动过的 chunk 崩溃。这里**只发 observe**，
    # 不做路由修复——权威进程由 VoxelChunkSup 按 :transient 重启并经注册表
    # 重新登记单主，facade 下次 lookup 自然解析到新 pid。
    case Map.pop(state.chunk_monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{logical_scene_id, chunk_coord}, monitors} ->
        CliObserve.emit("voxel_chunk_directory_chunk_down", fn ->
          %{
            logical_scene_id: logical_scene_id,
            chunk_coord: chunk_coord,
            pid: inspect(pid),
            reason: inspect(reason)
          }
        end)

        {:noreply, %{state | chunk_monitors: monitors}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # 阶段3.1：先经注册表解析权威 pid；未注册才启动。注册表是唯一真相源，
  # facade 不缓存 pid。
  defp ensure_chunk_in_state(state, attrs) do
    case ChunkRegistry.lookup(attrs.logical_scene_id, attrs.chunk_coord, state.chunk_registry) do
      {:ok, pid} ->
        case maybe_apply_chunk_lease(pid, Map.get(attrs, :lease), state.chunk_call_timeout_ms) do
          :ok -> {{:ok, pid}, state}
          {:error, reason} -> {{:error, reason}, state}
        end

      :not_started ->
        start_chunk(state, attrs)
    end
  end

  defp start_chunk(state, attrs) do
    chunk_opts = [
      logical_scene_id: attrs.logical_scene_id,
      chunk_coord: attrs.chunk_coord,
      # 把注册表名透传给 ChunkProcess，使其 via-tuple 注册进同一张表。
      chunk_registry: state.chunk_registry
    ]

    chunk_opts =
      case attrs.lease do
        nil -> chunk_opts
        lease -> Keyword.put(chunk_opts, :lease, lease)
      end

    case SceneServer.VoxelChunkSup.start_chunk(state.chunk_sup, chunk_opts) do
      {:ok, pid} ->
        next_state = monitor_chunk(state, pid, attrs)

        CliObserve.emit("voxel_chunk_started", %{
          logical_scene_id: attrs.logical_scene_id,
          chunk_coord: attrs.chunk_coord,
          pid: pid
        })

        # 启动后若调用方带了 lease（与 init 用的可能不同 / init 走未授权态），
        # 在此 apply 一次确保进入授权态。
        case maybe_apply_chunk_lease(pid, Map.get(attrs, :lease), state.chunk_call_timeout_ms) do
          :ok -> {{:ok, pid}, next_state}
          {:error, reason} -> {{:error, reason}, next_state}
        end

      # 并发 / 重启竞态：另一路已经把同 key 的权威进程注册了。注册表去重，
      # facade 复用既有 pid，绝不产生第二个权威。
      {:error, {:already_started, pid}} ->
        case maybe_apply_chunk_lease(pid, Map.get(attrs, :lease), state.chunk_call_timeout_ms) do
          :ok -> {{:ok, pid}, state}
          {:error, reason} -> {{:error, reason}, state}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp monitor_chunk(state, pid, attrs) do
    monitor_ref = Process.monitor(pid)
    key = {attrs.logical_scene_id, attrs.chunk_coord}
    %{state | chunk_monitors: Map.put(state.chunk_monitors, monitor_ref, key)}
  end

  defp maybe_apply_chunk_lease(_pid, nil, _timeout_ms), do: :ok

  defp maybe_apply_chunk_lease(pid, lease, timeout_ms) do
    case safe_chunk_call(:apply_lease, fn -> ChunkProcess.apply_lease(pid, lease, timeout_ms) end) do
      {:ok, _lease} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_chunk_call(operation, fun) do
    fun.()
  rescue
    exception ->
      {:error, {:chunk_unavailable, {exception.__struct__, Exception.message(exception)}}}
  catch
    :exit, {:timeout, _call} ->
      {:error, {:chunk_unavailable, {:timeout, operation}}}

    :exit, reason ->
      {:error, {:chunk_unavailable, reason}}
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    %{
      request_id: Map.get(attrs, :request_id, 0),
      logical_scene_id: Map.fetch!(attrs, :logical_scene_id),
      chunk_coord:
        attrs
        |> Map.get(:chunk_coord, Map.get(attrs, :center_chunk))
        |> coord!(),
      lease: Map.get(attrs, :lease),
      samples: Map.get(attrs, :samples, []),
      collision_query_timeout_ms: Map.get(attrs, :collision_query_timeout_ms)
    }
  end

  defp collision_query_timeout_ms(%{collision_query_timeout_ms: timeout_ms}, default_timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    min(timeout_ms, default_timeout_ms)
  end

  defp collision_query_timeout_ms(_attrs, default_timeout_ms), do: default_timeout_ms

  defp normalize_subscribe_attrs(attrs) when is_map(attrs) do
    raw_attrs = attrs
    attrs = normalize_attrs(raw_attrs)

    Map.merge(attrs, %{
      subscriber: Map.get(raw_attrs, :subscriber, self()),
      send_snapshot?: Map.get(raw_attrs, :send_snapshot?, true),
      known_version: Map.get(raw_attrs, :known_version),
      delivery_format: normalize_delivery_format(raw_attrs),
      tier: normalize_delivery_tier(Map.get(raw_attrs, :tier))
    })
  end

  defp normalize_delivery_format(%{delivery_format: format}) when format in [:raw, :envelope],
    do: format

  defp normalize_delivery_format(%{delivery_format: "envelope"}), do: :envelope
  defp normalize_delivery_format(%{delivery_format: "raw"}), do: :raw
  defp normalize_delivery_format(%{delivery_envelope?: true}), do: :envelope
  defp normalize_delivery_format(_attrs), do: :raw

  defp normalize_delivery_tier(tier) when tier in [:near, :halo], do: tier
  defp normalize_delivery_tier("near"), do: :near
  defp normalize_delivery_tier("halo"), do: :halo
  defp normalize_delivery_tier(_tier), do: :near

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
    case ChunkRegistry.lookup(handoff.logical_scene_id, chunk_coord, state.chunk_registry) do
      {:ok, pid} -> persist_live_source_chunk(pid, handoff, chunk_coord)
      :not_started -> %{chunk_coord: chunk_coord, status: :not_hot}
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

  defp normalize_prepare_transaction_attrs(attrs) when is_map(attrs) do
    case Map.get(attrs, :intents) do
      [_ | _] = intents ->
        case normalize_apply_intents_attrs(intents) do
          {:ok, route_attrs, normalized_attrs} ->
            opts = collect_prepare_opts(attrs)
            {:ok, route_attrs, normalized_attrs, opts}

          {:error, reason} ->
            {:error, reason}
        end

      [] ->
        {:error, :empty_intents}

      nil ->
        {:error, :missing_intents}

      _other ->
        {:error, :invalid_intents}
    end
  end

  defp normalize_prepare_transaction_attrs(_attrs), do: {:error, :invalid_voxel_intent}

  defp collect_prepare_opts(attrs) do
    case Map.get(attrs, :decision_version) do
      version when is_integer(version) and version >= 0 -> [decision_version: version]
      _ -> []
    end
  end

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

  defp fetch_chunk_pid(state, {logical_scene_id, chunk_coord}) do
    case ChunkRegistry.lookup(logical_scene_id, chunk_coord, state.chunk_registry) do
      {:ok, pid} -> {:ok, pid}
      :not_started -> {:error, :chunk_not_started}
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
