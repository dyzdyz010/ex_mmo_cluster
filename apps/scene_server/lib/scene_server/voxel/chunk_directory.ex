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

  # 内层(directory → ChunkProcess)同步调用超时上限。短于移动侧 collision_query 的 5s 外层
  # 超时,使慢 chunk 被捕获后 directory 仍能在外层超时前回复;且 directory 绝不因此 exit 崩库。
  @chunk_query_timeout 2_000

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
  def collision_query(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:collision_query, attrs})
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
  Read-only prefab anti-floating check, routed to the owning `ChunkProcess`.

  The directory only resolves / starts the chunk (same `ensure_chunk_in_state`
  path as `apply_intents/2`), then forwards to `ChunkProcess.prefab_floating?/2`.
  Returns `{:ok, boolean}` or `{:error, reason}` if the chunk could not be
  resolved / the intents were malformed. The prefab fast path calls this
  **before** `apply_intents/2` so a floating placement is rejected without ever
  mutating chunk truth.
  """
  def prefab_floating?(server \\ __MODULE__, attrs_list) when is_list(attrs_list) do
    GenServer.call(server, {:prefab_floating?, attrs_list}, 30_000)
  end

  @doc """
  形态轨 C5.2:放置 / 清除一个表面元件(火炬/拉杆等)。

  目录只负责定位/启动 chunk;`ChunkProcess` 拥有 truth 变更 + lease-fenced 持久化 +
  订阅者全快照下行(表面元件零 occupancy,走快照而非 delta)。`attrs` 须含
  `:logical_scene_id`、`:chunk_coord`、`:lease`、`:action`(`:place` | `:clear`)、
  `:macro_index`、`:face`;放置还须 `:surface_type_id`,可选 `:attribute_set_ref` /
  `:tag_set_ref` / `:owner_actor_id`。
  """
  def apply_surface_element_intent(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(server, {:apply_surface_element, attrs})
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
       chunks: %{},
       # 阶段3 step3.3:monitor 每个 chunk pid → DOWN(idle 驱逐 :normal / 崩溃)时即时从
       # chunks 表清除(让该表也随 idle 驱逐内存有界),崩溃额外 emit。monitors: %{ref => {key, pid}}。
       monitors: %{},
       # 透明崩溃恢复(2026-06-27 订阅活性根因修复)的订阅者镜像 + 续租 + 订阅者 monitor。
       # 不变量:`subscribers` 镜像 == 已向对应 ChunkProcess 注册的订阅集。subscribe 成功才加、
       # unsubscribe / 订阅者 DOWN 才减;ChunkProcess 崩溃后由本目录用镜像把同一批订阅者重订到
       # 新进程(镜像不变)。所有镜像变更都在本(共享单)GenServer 进程内串行,无需 generation tag。
       #
       # subscribers: %{key => MapSet<subscriber_pid>} —— 每 chunk 的活订阅者镜像。
       subscribers: %{},
       # chunk_leases: %{key => lease | nil} —— 每 chunk 最近一次 subscribe 用的 lease,崩溃重建需要。
       chunk_leases: %{},
       # 本目录对每个**唯一** subscriber_pid monitor 一次,用于订阅者(连接)死亡时清镜像防泄漏。
       # subscriber_monitors: %{ref => subscriber_pid};subscriber_chunks: %{subscriber_pid => MapSet<key>}。
       subscriber_monitors: %{},
       subscriber_chunks: %{}
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

        # ChunkDirectory 是**全 scene 共享单 GenServer**(所有 chunk 的 subscribe/edit/query 汇聚于此)。
        # collision_query 由移动 tick 高频驱动:若把对某个 ChunkProcess 的同步调用**裸调**,而该 chunk
        # 因慢 persist / mailbox 积压暂不应答,默认 5s GenServer.call 超时的 exit 会**把整个 directory
        # 拖崩** → supervisor 重启丢 chunks 表 → 下个查询重新物化 → 再超时 → 自持崩溃循环,拖垮全部
        # 体素操作(订阅/放置/消除)。故:(a)用短超时(2s,快于移动侧 safe_query 的 5s 外层超时,让
        # 移动能拿到干净错误优雅降级);(b)**捕获 :exit**,超时只返回错误、绝不崩 directory。
        reply =
          try do
            case ChunkProcess.collision_query(chunk_pid, query_attrs, @chunk_query_timeout) do
              {:ok, result} -> {:ok, result}
              {:error, reason} -> {:error, reason}
            end
          catch
            :exit, _reason -> {:error, :collision_query_unavailable}
          end

        {:reply, reply, next_state}

      {{:error, reason}, next_state} ->
        {:reply, {:error, reason}, next_state}
    end
  rescue
    _exception in [ArgumentError, KeyError] ->
      {:reply, {:error, :invalid_collision_query}, state}
  end

  def handle_call({:subscribe, attrs}, _from, state) do
    attrs = normalize_subscribe_attrs(attrs)
    key = {attrs.logical_scene_id, attrs.chunk_coord}

    case ensure_chunk_in_state(state, attrs) do
      {{:ok, chunk_pid}, next_state} ->
        opts = [
          request_id: attrs.request_id,
          send_snapshot?: attrs.send_snapshot?,
          known_version: attrs.known_version
        ]

        case ChunkProcess.subscribe(chunk_pid, attrs.subscriber, opts) do
          {:ok, payload} ->
            # 订阅成功才记镜像 —— 维持"subscribers 镜像 == 已注册订阅集"不变量。
            next_state = track_subscription(next_state, key, attrs.subscriber, attrs.lease)
            {:reply, {:ok, payload}, next_state}

          {:error, reason} ->
            {:reply, {:error, reason}, next_state}
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

        # 镜像同步:无论 chunk 是否仍 hot,都从镜像移除该订阅者(幂等)。
        next_state = untrack_subscription(state, key, attrs.subscriber)
        {:reply, reply, next_state}

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

  def handle_call({:prefab_floating?, []}, _from, state) do
    {:reply, {:ok, false}, state}
  end

  def handle_call({:prefab_floating?, attrs_list}, _from, state) when is_list(attrs_list) do
    case normalize_apply_intents_attrs(attrs_list) do
      {:ok, attrs, _normalized_attrs} ->
        case ensure_chunk_in_state(state, attrs) do
          {{:ok, chunk_pid}, next_state} ->
            {:reply, {:ok, ChunkProcess.prefab_floating?(chunk_pid, attrs_list)}, next_state}

          {{:error, reason}, next_state} ->
            {:reply, {:error, reason}, next_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # 形态轨 C5.2:表面元件放置/清除。lease-routed,走 ChunkProcess.put/clear_surface_element。
  def handle_call({:apply_surface_element, attrs}, _from, state) do
    case normalize_surface_element_attrs(attrs) do
      {:ok, route_attrs, op} ->
        case ensure_chunk_in_state(state, route_attrs) do
          {{:ok, chunk_pid}, next_state} ->
            reply = apply_surface_element_op(chunk_pid, route_attrs.lease, op)
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
    case Map.get(state.chunks, {logical_scene_id, chunk_coord}) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, state}
        else
          {:reply, :not_started, state}
        end

      _ ->
        {:reply, :not_started, state}
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
          lease = Map.get(attrs, :lease)

          case maybe_apply_chunk_lease(pid, Map.get(state.chunk_leases, key), lease) do
            :ok ->
              {{:ok, pid}, remember_chunk_lease(state, key, lease)}

            {:error, reason} ->
              CliObserve.emit("voxel_chunk_lease_apply_failed", fn ->
                %{
                  logical_scene_id: attrs.logical_scene_id,
                  chunk_coord: attrs.chunk_coord,
                  reason: inspect(reason)
                }
              end)

              {{:error, {:lease_apply_failed, reason}}, state}
          end
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
      chunk_coord: attrs.chunk_coord
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

        ref = Process.monitor(pid)

        next_state =
          state
          |> put_in([:chunks, key], pid)
          |> put_in([:monitors, ref], {key, pid})
          |> remember_chunk_lease(key, Map.get(attrs, :lease))

        {{:ok, pid}, next_state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    # 先判 ref 属于 chunk monitor 还是 subscriber monitor(两张 map 分开,先查 chunk)。
    case Map.pop(state.monitors, ref) do
      {{key, ^pid}, monitors} ->
        handle_chunk_down(%{state | monitors: monitors}, key, pid, reason)

      {_other, _monitors} ->
        # ref 不在 chunk monitors;可能是某订阅者(连接)死亡。
        handle_subscriber_down(state, ref, pid)
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ChunkProcess DOWN:照旧删表;若镜像里仍有订阅者(必是崩溃,因 idle 驱逐时镜像必空),
  # 透明重建 ChunkProcess 并把同一批订阅者重订到新进程(带快照让客户端追上)。绝不让本目录崩。
  defp handle_chunk_down(state, key, pid, reason) do
    # Drop the chunk from the table only if it still points at the dead pid
    # (a re-`ensure_chunk` may have already replaced it with a fresh process).
    chunks =
      case Map.get(state.chunks, key) do
        ^pid -> Map.delete(state.chunks, key)
        _other -> state.chunks
      end

    state = %{state | chunks: chunks}
    {logical_scene_id, chunk_coord} = key
    subs = Map.get(state.subscribers, key, MapSet.new())

    if reason not in [:normal, :shutdown] do
      CliObserve.emit("voxel_chunk_process_down", fn ->
        %{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord,
          reason: inspect(reason)
        }
      end)
    end

    if MapSet.size(subs) > 0 do
      # 有订阅者却 DOWN → 崩溃。透明恢复:重建 + 重订同一批订阅者。
      recover_crashed_chunk(state, key, subs, reason)
    else
      # 无订阅者(idle 驱逐 :normal 或本就无人订阅)→ 只清空镜像空条目,不重建。
      {:noreply, drop_empty_chunk_mirror(state, key)}
    end
  end

  defp recover_crashed_chunk(state, key, subs, reason) do
    {logical_scene_id, chunk_coord} = key
    lease = Map.get(state.chunk_leases, key)

    rebuild_attrs = %{
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      lease: lease
    }

    case start_chunk(state, key, rebuild_attrs) do
      {{:ok, new_pid}, next_state} ->
        # 对镜像里每个订阅者,重订到新进程并带当前权威快照(补回崩溃间隙丢失的变更)。
        Enum.each(subs, fn subscriber_pid ->
          try do
            ChunkProcess.subscribe(new_pid, subscriber_pid,
              request_id: 0,
              send_snapshot?: true,
              known_version: nil
            )
          catch
            :exit, _exit_reason -> :ok
          end
        end)

        CliObserve.emit("voxel_chunk_subscription_recovered", fn ->
          %{
            logical_scene_id: logical_scene_id,
            chunk_coord: chunk_coord,
            subscriber_count: MapSet.size(subs),
            reason: inspect(reason)
          }
        end)

        {:noreply, next_state}

      {{:error, rebuild_reason}, next_state} ->
        # 重建失败:保留镜像(下次 ensure_chunk 再建时不丢订阅者),只 emit 失败 observe,绝不崩本目录。
        CliObserve.emit("voxel_chunk_subscription_recovery_failed", fn ->
          %{
            logical_scene_id: logical_scene_id,
            chunk_coord: chunk_coord,
            subscriber_count: MapSet.size(subs),
            reason: inspect(rebuild_reason)
          }
        end)

        {:noreply, next_state}
    end
  end

  # 订阅者(连接)DOWN:从它订阅过的每个 chunk 镜像移除它;清自身 monitor / chunk 集。
  # ChunkProcess 那边也会自己 DOWN 丢它,这里只清本目录镜像防泄漏。
  defp handle_subscriber_down(state, ref, subscriber_pid) do
    case Map.pop(state.subscriber_monitors, ref) do
      {nil, _subscriber_monitors} ->
        # 既不是 chunk monitor 也不是已知 subscriber monitor —— 忽略。
        {:noreply, state}

      {^subscriber_pid, subscriber_monitors} ->
        keys = Map.get(state.subscriber_chunks, subscriber_pid, MapSet.new())

        subscribers =
          Enum.reduce(keys, state.subscribers, fn key, acc ->
            remove_subscriber_from_chunk_mirror(acc, key, subscriber_pid)
          end)

        {:noreply,
         %{
           state
           | subscribers: subscribers,
             subscriber_monitors: subscriber_monitors,
             subscriber_chunks: Map.delete(state.subscriber_chunks, subscriber_pid)
         }}

      {_other_pid, subscriber_monitors} ->
        # ref/pid 不一致(理论上不发生),保守地丢掉这条 monitor 条目。
        {:noreply, %{state | subscriber_monitors: subscriber_monitors}}
    end
  end

  # ── 订阅者镜像 + 续租 + 双 monitor 维护 ─────────────────────────────────────

  # subscribe 成功:把订阅者加入 chunk 镜像、记 lease;若该订阅者尚未被本目录 monitor,则 monitor 之。
  defp track_subscription(state, key, subscriber_pid, lease) do
    chunk_subs = Map.get(state.subscribers, key, MapSet.new())
    subscribers = Map.put(state.subscribers, key, MapSet.put(chunk_subs, subscriber_pid))
    chunk_leases = Map.put(state.chunk_leases, key, lease)

    sub_keys = Map.get(state.subscriber_chunks, subscriber_pid, MapSet.new())
    already_monitored? = MapSet.size(sub_keys) > 0

    subscriber_chunks =
      Map.put(state.subscriber_chunks, subscriber_pid, MapSet.put(sub_keys, key))

    subscriber_monitors =
      if already_monitored? do
        state.subscriber_monitors
      else
        sub_ref = Process.monitor(subscriber_pid)
        Map.put(state.subscriber_monitors, sub_ref, subscriber_pid)
      end

    %{
      state
      | subscribers: subscribers,
        chunk_leases: chunk_leases,
        subscriber_chunks: subscriber_chunks,
        subscriber_monitors: subscriber_monitors
    }
  end

  # unsubscribe:从 chunk 镜像移除该订阅者;若它再无任何 chunk,demonitor + 清 subscriber_monitors。
  defp untrack_subscription(state, key, subscriber_pid) do
    subscribers = remove_subscriber_from_chunk_mirror(state.subscribers, key, subscriber_pid)

    sub_keys =
      state.subscriber_chunks
      |> Map.get(subscriber_pid, MapSet.new())
      |> MapSet.delete(key)

    if MapSet.size(sub_keys) == 0 do
      {subscriber_monitors, subscriber_chunks} =
        demonitor_subscriber(state, subscriber_pid)

      %{
        state
        | subscribers: subscribers,
          subscriber_monitors: subscriber_monitors,
          subscriber_chunks: subscriber_chunks
      }
    else
      %{
        state
        | subscribers: subscribers,
          subscriber_chunks: Map.put(state.subscriber_chunks, subscriber_pid, sub_keys)
      }
    end
  end

  defp demonitor_subscriber(state, subscriber_pid) do
    subscriber_monitors =
      state.subscriber_monitors
      |> Enum.reject(fn {ref, pid} ->
        if pid == subscriber_pid do
          Process.demonitor(ref, [:flush])
          true
        else
          false
        end
      end)
      |> Map.new()

    {subscriber_monitors, Map.delete(state.subscriber_chunks, subscriber_pid)}
  end

  # 从某 chunk 的订阅者镜像里移除一个 pid;镜像变空则删 key 条目(随 idle 驱逐内存有界)。
  defp remove_subscriber_from_chunk_mirror(subscribers, key, subscriber_pid) do
    case Map.get(subscribers, key) do
      nil ->
        subscribers

      set ->
        next = MapSet.delete(set, subscriber_pid)

        if MapSet.size(next) == 0 do
          Map.delete(subscribers, key)
        else
          Map.put(subscribers, key, next)
        end
    end
  end

  # idle 驱逐路径:清掉该 chunk 的空镜像 / 续租条目。
  defp drop_empty_chunk_mirror(state, key) do
    %{
      state
      | subscribers: Map.delete(state.subscribers, key),
        chunk_leases: Map.delete(state.chunk_leases, key)
    }
  end

  defp maybe_apply_chunk_lease(_pid, _cached_lease, nil), do: :ok

  defp maybe_apply_chunk_lease(_pid, cached_lease, lease) when cached_lease == lease, do: :ok

  defp maybe_apply_chunk_lease(pid, _cached_lease, lease) do
    case ChunkProcess.apply_lease(pid, lease) do
      {:ok, _lease} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_apply_lease_reply, other}}
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp remember_chunk_lease(state, _key, nil), do: state

  defp remember_chunk_lease(state, key, lease) do
    put_in(state, [:chunk_leases, key], lease)
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
      samples: Map.get(attrs, :samples, [])
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
    case DataService.Voxel.ChunkSnapshotStore.get_snapshot(handoff.logical_scene_id, chunk_coord) do
      {:ok, snapshot} ->
        attrs = %{
          logical_scene_id: handoff.logical_scene_id,
          chunk_coord: chunk_coord,
          lease: handoff.new_lease
        }

        case ensure_chunk_in_state(state, attrs) do
          {{:ok, chunk_pid}, next_state} ->
            {load_prewarm_snapshot(chunk_pid, handoff, chunk_coord, snapshot), next_state}

          {{:error, reason}, next_state} ->
            {{:error, reason}, next_state}
        end

      {:error, :snapshot_not_found} ->
        reason = missing_prewarm_snapshot_reason(handoff, chunk_coord)

        CliObserve.emit("voxel_migration_prewarm_missing_snapshot", fn ->
          %{
            migration_id: handoff.migration_id,
            logical_scene_id: handoff.logical_scene_id,
            region_id: handoff.region_id,
            chunk_coord: chunk_coord,
            reason: reason
          }
        end)

        {{:error, reason}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp missing_prewarm_snapshot_reason(handoff, chunk_coord) do
    {:missing_authoritative_chunk_snapshot,
     %{
       logical_scene_id: handoff.logical_scene_id,
       chunk_coord: chunk_coord,
       migration_id: handoff.migration_id,
       stage: :migration_prewarm,
       reason: :snapshot_not_found
     }}
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

  # 形态轨 C5.2:校验 + 拆解表面元件 intent。返回 {route_attrs, op},其中 op 是
  # {:place, element_attrs} | {:clear, %{macro_index, face}}。须有 lease(World 授权)。
  defp normalize_surface_element_attrs(attrs) when is_map(attrs) do
    route_attrs = normalize_attrs(attrs)

    cond do
      is_nil(route_attrs.lease) ->
        {:error, :missing_lease}

      true ->
        case build_surface_element_op(attrs) do
          {:ok, op} -> {:ok, route_attrs, op}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    _exception in [ArgumentError, KeyError] -> {:error, :invalid_surface_element_intent}
  end

  defp normalize_surface_element_attrs(_attrs), do: {:error, :invalid_surface_element_intent}

  defp build_surface_element_op(attrs) do
    case Map.get(attrs, :action) do
      :place ->
        {:ok,
         {:place,
          %{
            macro_index: Map.fetch!(attrs, :macro_index),
            face: Map.fetch!(attrs, :face),
            surface_type_id: Map.fetch!(attrs, :surface_type_id),
            attribute_set_ref: Map.get(attrs, :attribute_set_ref, 0),
            tag_set_ref: Map.get(attrs, :tag_set_ref, 0),
            owner_actor_id: Map.get(attrs, :owner_actor_id, 0)
          }}}

      :clear ->
        {:ok,
         {:clear, %{macro_index: Map.fetch!(attrs, :macro_index), face: Map.fetch!(attrs, :face)}}}

      _other ->
        {:error, :invalid_surface_element_action}
    end
  end

  defp apply_surface_element_op(chunk_pid, lease, {:place, element}) do
    chunk_pid
    |> ChunkProcess.put_surface_element(Map.put(element, :lease, lease))
    |> surface_element_reply()
  end

  defp apply_surface_element_op(
         chunk_pid,
         lease,
         {:clear, %{macro_index: macro_index, face: face}}
       ) do
    chunk_pid
    |> ChunkProcess.clear_surface_element(macro_index, face, lease: lease)
    |> surface_element_reply()
  end

  # 把 ChunkProcess 返回的 Storage 摊成 gate 期望的纯 map 回执(含 chunk_coord/chunk_version)。
  defp surface_element_reply({:ok, storage}) do
    {:ok,
     %{
       logical_scene_id: storage.logical_scene_id,
       chunk_coord: storage.chunk_coord,
       chunk_version: storage.chunk_version,
       changed?: true
     }}
  end

  defp surface_element_reply({:error, reason}), do: {:error, reason}

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
