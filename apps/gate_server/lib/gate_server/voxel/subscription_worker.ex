defmodule GateServer.Voxel.SubscriptionWorker do
  @moduledoc """
  Per-connection voxel **subscription worker** (阶段4 step4.3 非阻塞核心).

  The gate connection used to route + subscribe every chunk of a subscribe box
  **synchronously inside its own GenServer** — 125 cold `safe_call`s (each up to
  15s) blocked the connection for a measured ~3.5s, stalling the player's queued
  `VoxelEditIntent` / movement frames. This worker moves that slow control-plane
  I/O off the connection's main loop: the connection `cast`s its subscribe /
  unsubscribe intents and returns immediately, so edit / movement frames stay
  low-latency no matter how large the subscribe storm.

  ## Single owner, single scene-op issuer

  The worker is the **sole owner** of the connection's voxel subscription set and
  the **sole issuer** of Scene-side subscribe / unsubscribe. Because one GenServer
  processes its mailbox serially, subscribe and unsubscribe for the same chunk are
  strictly ordered and the worker's `subscriptions` map is always consistent with
  what it has registered at the Scene. This is what makes the asynchronous design
  correct: an earlier design that split subscription state across the connection
  (authoritative map) and worker (scene I/O) had a whole class of reorder races
  (退订/重订交错 → 静默死订阅) because two processes issued Scene ops for the same
  chunk. Concentrating both the state and the I/O in one serial process removes
  them — no generation tags, no clobbering.

  The worker subscribes with `subscriber: connection_pid` (not itself), so chunk
  snapshots / deltas flow straight to the connection → socket (the fan-out hot
  path is untouched). The connection holds only the worker pid; it queries the
  worker (sync `call`) for the rare introspection / debug / rebind paths.
  """

  use GenServer
  require Logger

  alias GateServer.Voxel.{Routing, RouteCache}

  @typedoc "A subscribe-box intent handed over from the connection (full box, undiffed)."
  @type reconcile_ctx :: %{
          request_id: non_neg_integer(),
          client_intent_seq: non_neg_integer(),
          logical_scene_id: integer(),
          center_chunk: {integer(), integer(), integer()},
          radius: non_neg_integer(),
          want_snapshot: boolean(),
          known: %{optional({integer(), integer(), integer()}) => non_neg_integer()}
        }

  # ── public API ──────────────────────────────────────────────────────────────

  @doc "Starts a worker bound to `connection_pid` (links to the caller)."
  @spec start_link(pid(), keyword()) :: GenServer.on_start()
  def start_link(connection_pid, opts \\ []) when is_pid(connection_pid) do
    GenServer.start_link(__MODULE__, {connection_pid, opts})
  end

  @doc "Asynchronously route + subscribe the box's not-yet-subscribed chunks."
  @spec reconcile(pid(), reconcile_ctx()) :: :ok
  def reconcile(worker, ctx) when is_pid(worker) and is_map(ctx) do
    GenServer.cast(worker, {:reconcile, ctx})
  end

  @doc "Asynchronously unsubscribe the given chunks of a logical scene."
  @spec unsubscribe(pid(), integer(), [{integer(), integer(), integer()}]) :: :ok
  def unsubscribe(worker, logical_scene_id, chunks) when is_pid(worker) and is_list(chunks) do
    GenServer.cast(worker, {:unsubscribe, logical_scene_id, chunks})
  end

  @doc """
  Drops one chunk's subscription record after a `ChunkInvalidate` (the Scene already
  cleared the subscriber), so a subsequent re-subscribe rebuilds it instead of being
  diffed away (阶段4 评审 F5). Also clears the route cache (ownership churn).
  """
  @spec invalidate_chunk(pid(), integer(), {integer(), integer(), integer()}) :: :ok
  def invalidate_chunk(worker, logical_scene_id, chunk_coord) when is_pid(worker) do
    GenServer.cast(worker, {:invalidate_chunk, logical_scene_id, chunk_coord})
  end

  @doc "Drops the worker's cached routes (e.g. on migration / a non-decodable invalidate)."
  @spec invalidate_route_cache(pid()) :: :ok
  def invalidate_route_cache(worker) when is_pid(worker) do
    GenServer.cast(worker, :invalidate_route_cache)
  end

  @doc "Re-routes existing subscriptions after a World migration cutover (sync — rare)."
  @spec rebind(pid(), integer(), :all | term(), term()) :: %{
          rebound_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          error_count: non_neg_integer(),
          subscription_count: non_neg_integer()
        }
  def rebind(worker, logical_scene_id, region_selector, reason) when is_pid(worker) do
    GenServer.call(worker, {:rebind, logical_scene_id, region_selector, reason})
  end

  @doc "The live subscription map `{logical_scene_id, chunk_coord} => sub` (sync — debug)."
  @spec subscriptions(pid()) :: %{optional(term()) => map()}
  def subscriptions(worker) when is_pid(worker) do
    GenServer.call(worker, :subscriptions)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  # Connection-driven lease keep-alive interval. Half the route-cache refresh window so
  # a lease that has drifted into the "near expiry" band (a route-cache miss) is renewed
  # well before it actually lapses — without the client ever polling.
  @lease_renew_interval_ms :timer.seconds(15)

  @impl true
  def init({connection_pid, opts}) do
    # Monitor (not only link) the connection: a `:normal` connection stop does NOT
    # propagate through the start_link link, so without this the worker would orphan.
    Process.monitor(connection_pid)

    renew_interval = Keyword.get(opts, :lease_renew_interval_ms, @lease_renew_interval_ms)
    Process.send_after(self(), :renew_leases, renew_interval)

    {:ok,
     %{
       connection_pid: connection_pid,
       subscriptions: %{},
       route_cache: RouteCache.new(),
       refresh_window_ms: Keyword.get(opts, :route_cache_refresh_ms, :timer.seconds(30)),
       lease_renew_interval_ms: renew_interval
     }}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{connection_pid: pid} = state) do
    {:stop, :normal, state}
  end

  # Connection-driven lease keep-alive (阶段1-续租). The worker is the owner of this
  # connection's subscriptions, so it owns their LIVENESS too: it periodically re-routes
  # each live subscription, which renews a near-expiry lease at World (route_cached treats
  # near-expiry as a miss → route_chunk → renewal). A non-expiring lease is a cheap cache
  # hit, so this is nearly free until a lease actually approaches its TTL. Effect: a region
  # the player is actively subscribed to is NEVER reaped by the region GC — even if they
  # stand still and never move/re-subscribe. This is the orthogonal fix for the silent
  # time-based death: the subscription self-maintains its liveness, no client polling.
  def handle_info(:renew_leases, state) do
    Process.send_after(self(), :renew_leases, state.lease_renew_interval_ms)
    {:noreply, renew_subscription_leases(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp renew_subscription_leases(%{subscriptions: subs} = state) when map_size(subs) == 0 do
    state
  end

  defp renew_subscription_leases(state) do
    now = System.system_time(:millisecond)

    Enum.reduce(state.subscriptions, state, fn {{logical_scene_id, coord}, _sub}, acc ->
      case route_cached(acc, logical_scene_id, coord, now) do
        {:ok, _route, next} -> next
        {:error, _reason} -> acc
      end
    end)
  end

  @impl true
  def handle_cast({:reconcile, ctx}, state) do
    {:noreply, do_reconcile(ctx, state)}
  end

  def handle_cast({:unsubscribe, logical_scene_id, chunks}, state) do
    {:noreply, do_unsubscribe(logical_scene_id, chunks, state)}
  end

  def handle_cast({:invalidate_chunk, logical_scene_id, chunk_coord}, state) do
    key = {logical_scene_id, chunk_coord}

    # 评审复审 F1:ChunkInvalidate 从 Scene 端发出,与本 worker 自己的 subscribe 调用**跨进程**,故
    # 本 cast 与一次(因 AOI 触发的)重订阅在 ChunkProcess vs 本 worker 上可乱序提交。若本 worker 在
    # 收到本 cast 前刚把该 chunk 重订阅(map 有、Scene 有),仅删 map 会留下 Scene 侧静默死订阅。故
    # **主动**对 Scene 幂等退订一次再删 map,保证「map == Scene 注册集」不变量;客户端按协议
    # (0x69 = 丢弃 + 重订)重订时由 worker 自身权威集差集干净重建。
    case Map.pop(state.subscriptions, key) do
      {nil, _rest} ->
        {:noreply, %{state | route_cache: RouteCache.new()}}

      {subscription, rest} ->
        scene_unsubscribe(state, subscription)
        {:noreply, %{state | subscriptions: rest, route_cache: RouteCache.new()}}
    end
  end

  def handle_cast(:invalidate_route_cache, state) do
    {:noreply, %{state | route_cache: RouteCache.new()}}
  end

  @impl true
  def handle_call({:rebind, logical_scene_id, region_selector, reason}, _from, state) do
    {next_state, result} = do_rebind(logical_scene_id, region_selector, reason, state)
    {:reply, result, next_state}
  end

  def handle_call(:subscriptions, _from, state) do
    {:reply, state.subscriptions, state}
  end

  # ── reconcile (subscribe) ────────────────────────────────────────────────────

  defp do_reconcile(%{center_chunk: center, radius: radius} = ctx, state) do
    now = System.system_time(:millisecond)

    box_coords(center, radius)
    |> Enum.reduce({state, false}, fn coord, {acc, failed?} ->
      key = {ctx.logical_scene_id, coord}

      cond do
        # diff (step4.2):already subscribed — skip the Scene round-trip entirely.
        #
        # 例外(2026-06-27 resync 硬化):若客户端为该 coord 显式带了 known_version,说明这是一次
        # **版本感知重快照请求**(client 持旧版本、疑似与权威分歧),必须转发到 Scene —— Scene 端
        # `ChunkProcess` 的 `known_version != current_version` guard 决定是否重发全快照(版本去重、
        # idempotent)。这把"重订强制重快照"变成干净单步,不再依赖 unsubscribe 舞蹈 + debounce。
        # routine coverage 重订(随移动,Known 为空)仍走下面的跳过,不打扰 Scene。
        Map.has_key?(acc.subscriptions, key) and not Map.has_key?(ctx.known, coord) ->
          {acc, failed?}

        true ->
          case subscribe_one(acc, ctx, coord, now) do
            {:ok, next_acc} ->
              {next_acc, failed?}

            {:error, reason, next_acc} ->
              # streaming, best-effort:keep subscribing the rest of the box; surface
              # only the FIRST failure as one 0x68 (avoids a frame storm on a fully
              # unavailable World), with the failing chunk in the observe trail.
              unless failed?, do: send_failed(next_acc, ctx, coord, reason)
              {next_acc, true}
          end
      end
    end)
    |> elem(0)
  end

  defp subscribe_one(state, ctx, coord, now) do
    with {:ok, route, state} <- route_cached(state, ctx.logical_scene_id, coord, now),
         {:ok, scene_node} <- Routing.scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      attrs = %{
        request_id: ctx.request_id,
        logical_scene_id: ctx.logical_scene_id,
        chunk_coord: coord,
        subscriber: state.connection_pid,
        lease: lease,
        send_snapshot?: ctx.want_snapshot,
        known_version: Map.get(ctx.known, coord)
      }

      key = {ctx.logical_scene_id, coord}
      subscription = build_subscription(ctx.logical_scene_id, coord, ctx.request_id, scene_node, lease)

      case Routing.subscribe(scene_node, attrs) do
        {:ok, _payload} ->
          emit_routed(state, ctx, coord, route)
          {:ok, %{state | subscriptions: Map.put(state.subscriptions, key, subscription)}}

        # 评审复审 F2:订阅 call 超时但 ChunkProcess 很可能已注册 subscriber(put_subscriber 在快照
        # 编码前),且快照经 send/2 直达连接不受本 call 超时影响。故**记录订阅**(否则日后退订因 map
        # 无此 key 而漏退 Scene → 泄漏);日后退订对 Scene 幂等退订无害。不发 0x68(快照已异步直达)。
        {:error, :timeout} ->
          emit_routed(state, ctx, coord, route)
          {:ok, %{state | subscriptions: Map.put(state.subscriptions, key, subscription)}}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # cache-first per-chunk route: a hit returns locally; a miss routes through the
  # control plane (materializing the region) and caches it. Lease-near-expiry is a
  # cache miss, so the re-route triggers a World-side renewal (阶段2-bis).
  defp route_cached(state, logical_scene_id, chunk_coord, now) do
    case RouteCache.lookup(state.route_cache, chunk_coord, now, state.refresh_window_ms) do
      {:ok, route} ->
        {:ok, route, state}

      :miss ->
        case Routing.route_chunk(logical_scene_id, chunk_coord) do
          {:ok, route} ->
            cache = RouteCache.put(state.route_cache, route, now)
            {:ok, route, %{state | route_cache: cache}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # ── unsubscribe ───────────────────────────────────────────────────────────────

  defp do_unsubscribe(logical_scene_id, chunks, state) do
    Enum.reduce(chunks, state, fn coord, acc ->
      key = {logical_scene_id, coord}

      case Map.pop(acc.subscriptions, key) do
        {nil, _rest} -> acc
        {subscription, rest} ->
          scene_unsubscribe(acc, subscription)
          %{acc | subscriptions: rest}
      end
    end)
  end

  # ── rebind (migration cutover, rare/sync) ────────────────────────────────────

  defp do_rebind(logical_scene_id, region_selector, reason, state) do
    GateServer.CliObserve.emit("voxel_subscription_rebind_requested", %{
      connection_pid: state.connection_pid,
      logical_scene_id: logical_scene_id,
      region_selector: region_selector,
      reason: reason,
      subscription_count: map_size(state.subscriptions)
    })

    # 评审复审 F4:迁移改变所有权 → 在 rebind 内清自身 route 缓存(此前只有 public cast 路径在调用
    # 方清,debug 探针路径漏清留陈旧路由)。放 rebind 内使两条路径一致、去掉跨模块时序依赖。
    state = %{state | route_cache: RouteCache.new()}

    {next_state, counts} =
      Enum.reduce(
        state.subscriptions,
        {state, %{rebound_count: 0, skipped_count: 0, error_count: 0}},
        fn {key, subscription}, {acc_state, acc_result} ->
          if rebind_selected?(subscription, logical_scene_id, region_selector) do
            case rebind_one(acc_state, subscription, reason) do
              {:ok, next_subscription, :rebound} ->
                {put_in(acc_state.subscriptions[key], next_subscription),
                 Map.update!(acc_result, :rebound_count, &(&1 + 1))}

              {:ok, _next_subscription, :skipped} ->
                {acc_state, Map.update!(acc_result, :skipped_count, &(&1 + 1))}

              {:error, rebind_error} ->
                GateServer.CliObserve.emit("voxel_subscription_rebind_error", %{
                  connection_pid: state.connection_pid,
                  logical_scene_id: subscription.logical_scene_id,
                  chunk_coord: subscription.chunk_coord,
                  region_id: Map.get(subscription, :region_id),
                  reason: rebind_error
                })

                {acc_state, Map.update!(acc_result, :error_count, &(&1 + 1))}
            end
          else
            {acc_state, acc_result}
          end
        end
      )

    {next_state, Map.put(counts, :subscription_count, map_size(next_state.subscriptions))}
  end

  defp rebind_selected?(subscription, logical_scene_id, region_selector) do
    subscription.logical_scene_id == logical_scene_id and
      (region_selector == :all or Map.get(subscription, :region_id) == region_selector)
  end

  defp rebind_one(state, subscription, reason) do
    with {:ok, route} <- Routing.route_chunk(subscription.logical_scene_id, subscription.chunk_coord),
         {:ok, scene_node} <- Routing.scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      GateServer.CliObserve.emit("voxel_subscription_rebind_routed", %{
        connection_pid: state.connection_pid,
        logical_scene_id: subscription.logical_scene_id,
        chunk_coord: subscription.chunk_coord,
        reason: reason,
        old_scene_node: Map.get(subscription, :scene_node),
        new_scene_node: scene_node,
        old_lease_id: Map.get(subscription, :lease_id),
        new_lease_id: lease.lease_id,
        old_owner_scene_instance_ref: Map.get(subscription, :owner_scene_instance_ref),
        new_owner_scene_instance_ref: lease.owner_scene_instance_ref,
        new_owner_epoch: lease.owner_epoch
      })

      if subscription_matches_route?(subscription, scene_node, lease) do
        GateServer.CliObserve.emit("voxel_subscription_rebind_skipped", %{
          connection_pid: state.connection_pid,
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          lease_id: lease.lease_id,
          owner_scene_instance_ref: lease.owner_scene_instance_ref,
          owner_epoch: lease.owner_epoch
        })

        {:ok, subscription, :skipped}
      else
        attrs = %{
          request_id: subscription.request_id,
          logical_scene_id: subscription.logical_scene_id,
          chunk_coord: subscription.chunk_coord,
          subscriber: state.connection_pid,
          lease: lease,
          send_snapshot?: true,
          known_version: nil
        }

        case Routing.subscribe(scene_node, attrs) do
          {:ok, _payload} ->
            if Map.get(subscription, :scene_node) != scene_node do
              scene_unsubscribe(state, subscription)

              GateServer.CliObserve.emit("voxel_subscription_rebind_unsubscribed_old", %{
                connection_pid: state.connection_pid,
                logical_scene_id: subscription.logical_scene_id,
                chunk_coord: subscription.chunk_coord,
                scene_node: Map.get(subscription, :scene_node),
                lease_id: Map.get(subscription, :lease_id),
                owner_scene_instance_ref: Map.get(subscription, :owner_scene_instance_ref),
                owner_epoch: Map.get(subscription, :owner_epoch)
              })
            end

            next_subscription = %{
              subscription
              | scene_node: scene_node,
                region_id: lease.region_id,
                lease_id: lease.lease_id,
                owner_scene_instance_ref: lease.owner_scene_instance_ref,
                owner_epoch: lease.owner_epoch
            }

            GateServer.CliObserve.emit("voxel_subscription_rebind_subscribed_new", %{
              connection_pid: state.connection_pid,
              logical_scene_id: next_subscription.logical_scene_id,
              chunk_coord: next_subscription.chunk_coord,
              scene_node: next_subscription.scene_node,
              region_id: next_subscription.region_id,
              lease_id: next_subscription.lease_id,
              owner_scene_instance_ref: next_subscription.owner_scene_instance_ref,
              owner_epoch: next_subscription.owner_epoch
            })

            {:ok, next_subscription, :rebound}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp subscription_matches_route?(subscription, scene_node, lease) do
    Map.get(subscription, :scene_node) == scene_node and
      Map.get(subscription, :lease_id) == lease.lease_id and
      Map.get(subscription, :owner_scene_instance_ref) == lease.owner_scene_instance_ref and
      Map.get(subscription, :owner_epoch) == lease.owner_epoch
  end

  # ── helpers ───────────────────────────────────────────────────────────────────

  defp build_subscription(logical_scene_id, coord, request_id, scene_node, lease) do
    %{
      logical_scene_id: logical_scene_id,
      chunk_coord: coord,
      request_id: request_id,
      scene_node: scene_node,
      region_id: lease.region_id,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch
    }
  end

  defp scene_unsubscribe(state, %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         scene_node: scene_node
       }) do
    Routing.unsubscribe(scene_node, %{
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      subscriber: state.connection_pid
    })
  end

  defp box_coords({cx, cy, cz}, radius) do
    for x <- (cx - radius)..(cx + radius),
        y <- (cy - radius)..(cy + radius),
        z <- (cz - radius)..(cz + radius) do
      {x, y, z}
    end
  end

  defp send_failed(state, ctx, coord, reason) do
    send(
      state.connection_pid,
      {:voxel_subscribe_failed,
       %{
         request_id: ctx.request_id,
         client_intent_seq: ctx.client_intent_seq,
         logical_scene_id: ctx.logical_scene_id,
         chunk_coord: coord
       }, reason}
    )
  end

  defp emit_routed(state, ctx, coord, route) do
    GateServer.CliObserve.emit("voxel_chunk_subscribe_routed", fn ->
      assignment = Map.fetch!(route, :assignment)
      lease = Map.fetch!(route, :lease)

      %{
        connection_pid: state.connection_pid,
        request_id: ctx.request_id,
        logical_scene_id: ctx.logical_scene_id,
        center_chunk: coord,
        region_id: assignment.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch
      }
    end)
  end
end
