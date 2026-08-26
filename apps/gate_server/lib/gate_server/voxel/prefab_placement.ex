defmodule GateServer.Voxel.PrefabPlacement do
  @moduledoc """
  `0x67 PrefabPlaceIntent` 的 Gate 侧放置管线 —— TCP / WS 两条链路共用的唯一实现。

  拆分前这套管线在 `tcp_connection.ex` 与 `ws_connection.ex` 中各存在一份逐字镜像的
  副本（约 830 行 × 2），两边只有 observe 事件名不同。共享后放置语义只有一个 owner，
  新增传输或修 bug 不会再出现单边漂移。

  ## 放置路径选择

  蓝图先经 `SceneServer.Voxel.PrefabRaster` 栅格化成宏格单元列表，再按**具体 Scene
  owner**（`{chunk_directory, assigned_scene_node}`）分组成 participant，然后按覆盖面
  选三条路径之一：

  ```mermaid
  flowchart TD
      A[rasterize 蓝图] --> B[按 chunk 批量路由 + 分组 participant]
      B --> C{覆盖几个 chunk / 几个 owner}
      C -->|单 chunk| D[ChunkDirectory.apply_intents 直写]
      C -->|多 chunk 同 owner| E[PrefabLocalTransaction 本地 prepare/commit]
      C -->|跨 owner| F[World TransactionCoordinator + Executor 两阶段提交]
      D --> G[register_scene_objects]
      E --> G
      F --> G
  ```

  ## 幂等

  prefab 是多步 / 跨节点命令（分配 object_id 序列 + 跨 chunk 事务），无单一事务可包裹，
  故用 `DataService.Voxel.CommandLog` 的 idempotency-key：claim（派生稳定 command_id，
  在分配 object_id 前认领）→ 工作 → 成功 confirm（缓存结果摘要）/ 失败 release（放行重试）。
  重复命令直接返回缓存摘要，**不重新分配 object_id、不重复产生 durable 资产**。

  ## 原子性边界

  单 chunk 与同 owner 多 chunk 由对应路径整体提交；跨 owner 走 World 的两阶段提交，
  整个 prefab 要么全部落地要么整体 abort。三条路径都不做部分写回滚之外的兜底：失败按
  可诊断 reason 显式返回，由调用方编成 `VoxelIntentResult` 回给客户端。
  """

  alias GateServer.Session.Sink
  alias GateServer.Voxel.{PrefabLocalTransaction, Routing}
  alias SceneServer.Voxel.PrefabRaster

  @prefab_owner_part_id 1
  @max_prefab_owner_object_id 0x7FFF_FFFF_FFFF_FFFF

  @type ctx :: %{cid: integer(), sink: Sink.t()}
  @type summary :: %{
          cell_count: non_neg_integer(),
          chunk_count: non_neg_integer(),
          max_chunk_version: non_neg_integer()
        }
  @type failure :: %{
          reason: term(),
          applied_cell_count: non_neg_integer(),
          total_cell_count: non_neg_integer()
        }

  @doc """
  放置一个 prefab，返回 `{:ok, summary}` 或 `{:error, failure}`。

  必须在连接进程内调用 —— 内部的 observe 事件与 Scene 对象注册都以 `self()` 作为
  连接标识。
  """
  @spec place(map(), ctx()) :: {:ok, summary()} | {:error, failure()}
  def place(request, ctx) do
    case authorize(ctx) do
      :ok ->
        command_id =
          GateServer.VoxelCommandId.prefab(
            request.logical_scene_id,
            ctx.cid,
            request.client_intent_seq
          )

        apply_with_idempotency(command_id, request, ctx)

      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: 0}}
    end
  end

  defp authorize(%{cid: cid}) when is_integer(cid) and cid > 0, do: :ok
  defp authorize(_ctx), do: {:error, :cid_mismatch}

  defp apply_with_idempotency(command_id, request, ctx) do
    case DataService.Voxel.CommandLog.claim(command_id, request.logical_scene_id) do
      :fresh ->
        case do_place(request, ctx) do
          {:ok, summary} ->
            DataService.Voxel.CommandLog.confirm(
              command_id,
              GateServer.VoxelCommandId.encode_prefab_summary(summary)
            )

            {:ok, summary}

          {:error, _reason} = error ->
            DataService.Voxel.CommandLog.release(command_id)
            error
        end

      {:duplicate, result} ->
        Sink.emit_transport_tagged(ctx.sink, "voxel_prefab_place_intent_duplicate", %{
          connection_pid: self(),
          cid: ctx.cid,
          request_id: request.request_id,
          client_intent_seq: request.client_intent_seq,
          logical_scene_id: request.logical_scene_id,
          command_id: command_id
        })

        {:ok, GateServer.VoxelCommandId.decode_prefab_summary(result)}

      :in_flight ->
        {:error, %{reason: :command_in_flight, applied_cell_count: 0, total_cell_count: 0}}
    end
  end

  defp do_place(request, ctx) do
    with {:ok, owner_object_id} <- allocate_owner_object_id(),
         {:ok, cells} <-
           PrefabRaster.rasterize(
             request.blueprint_id,
             request.blueprint_version,
             request.anchor_world_micro,
             request.rotation,
             owner_object_id: owner_object_id,
             owner_part_id: @prefab_owner_part_id
           ) do
      run_transaction(cells, request, ctx, owner_object_id)
    else
      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: 0}}
    end
  end

  defp allocate_owner_object_id do
    case DataService.Voxel.SceneObjectStore.next_object_id() do
      {:ok, object_id}
      when is_integer(object_id) and object_id > 0 and object_id <= @max_prefab_owner_object_id ->
        {:ok, object_id}

      {:ok, _object_id} ->
        {:error, :invalid_allocated_object_id}

      {:error, _reason} ->
        {:error, :object_id_unavailable}
    end
  rescue
    _exception -> {:error, :object_id_unavailable}
  catch
    :exit, _reason -> {:error, :object_id_unavailable}
  end

  defp run_transaction([], _request, _ctx, _owner_object_id) do
    {:ok, %{cell_count: 0, chunk_count: 0, max_chunk_version: 0}}
  end

  defp run_transaction(cells, request, ctx, owner_object_id) do
    total = length(cells)

    with {:ok, plan} <- build_plan(cells, request, ctx, owner_object_id) do
      case single_chunk_plan(plan) do
        {:ok, participant, chunk_coord, intents} ->
          apply_single_chunk(participant, plan, chunk_coord, intents, request, ctx, total)

        :error ->
          case same_owner_plan(plan) do
            {:ok, participants} ->
              apply_same_owner(participants, plan, request, ctx, total)

            :error ->
              with {:ok, coordinator_ref} <- locate_transaction_coordinator(),
                   {:ok, transaction} <-
                     coordinator_begin_transaction(coordinator_ref, plan, request),
                   {:ok, executor_result} <-
                     executor_execute(coordinator_ref, transaction, plan) do
                finalize_outcome(executor_result, plan, total)
              end
          end
      end
    else
      {:error, reason} ->
        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: total}}
    end
  end

  # 批量把 chunk 路由过 World,再按具体 Scene owner `{chunk_directory, assigned_scene_node}`
  # 分组。每个 participant 仍带 `chunk_owners`,保留每个 chunk 真实的 `{region_id, lease_id}`
  # owner 供对象归属元数据使用。
  defp build_plan(cells, request, ctx, owner_object_id) do
    cells_by_chunk = Enum.group_by(cells, & &1.chunk_coord)
    chunk_coords = Map.keys(cells_by_chunk)

    case chunk_coords do
      [] ->
        {:error, :empty_prefab}

      coords ->
        with {:ok, routes_by_chunk} <- Routing.route_chunks(request.logical_scene_id, coords),
             {:ok, participants} <-
               build_participants(routes_by_chunk, cells_by_chunk, request),
             {:ok, scene_object} <-
               build_scene_object(request, ctx, owner_object_id, coords, cells, participants) do
          emit_routed_observe(request, ctx, participants, length(cells))

          {:ok,
           %{
             participants: participants,
             chunk_coords: Enum.sort(coords),
             scene_object: scene_object,
             scene_objects: [scene_object]
           }}
        end
    end
  end

  defp build_scene_object(request, ctx, owner_object_id, chunk_coords, cells, participants) do
    covered_chunks = Enum.sort(chunk_coords)

    with {:ok, owner} <- scene_object_owner(covered_chunks, participants),
         {:ok, covered_by_region} <- covered_chunks_by_region(covered_chunks, participants) do
      {:ok,
       %{
         object_id: owner_object_id,
         logical_scene_id: request.logical_scene_id,
         parcel_id: Map.get(request, :parcel_id, 0),
         blueprint_id: request.blueprint_id,
         blueprint_version: request.blueprint_version,
         anchor_world_micro: request.anchor_world_micro,
         rotation: request.rotation,
         owner_actor_id: ctx.cid,
         state_flags: 0,
         object_attribute_ref: 0,
         object_tag_set_ref: 0,
         covered_chunks: covered_chunks,
         covered_chunks_by_region: covered_by_region,
         part_states: [
           %{part_id: @prefab_owner_part_id, health: length(cells), state_flags: 0}
         ],
         object_version: 1,
         owner_region_id: owner.region_id,
         owner_lease_id: owner.lease_id
       }}
    end
  end

  defp scene_object_owner([], _participants), do: {:error, :invalid_covered_chunks}

  defp scene_object_owner(covered_chunks, participants) do
    first_chunk = covered_chunks |> Enum.sort() |> List.first()

    case Enum.find(participants, fn participant -> first_chunk in participant.chunk_coords end) do
      nil ->
        {:error, :scene_object_owner_undeterminable}

      participant ->
        case Map.fetch(participant.chunk_owners, first_chunk) do
          {:ok, {region_id, lease_id}} -> {:ok, %{region_id: region_id, lease_id: lease_id}}
          :error -> {:error, {:missing_chunk_owner, first_chunk}}
        end
    end
  end

  defp covered_chunks_by_region(covered_chunks, participants) do
    chunk_to_owner =
      participants
      |> Enum.flat_map(fn participant ->
        Enum.map(participant.chunk_coords, fn coord ->
          {coord, Map.fetch!(participant.chunk_owners, coord)}
        end)
      end)
      |> Map.new()

    covered_chunks
    |> Enum.reduce_while({:ok, []}, fn coord, {:ok, acc} ->
      case Map.fetch(chunk_to_owner, coord) do
        {:ok, owner} -> {:cont, {:ok, [{coord, owner} | acc]}}
        :error -> {:halt, {:error, {:missing_chunk_owner, coord}}}
      end
    end)
    |> case do
      {:ok, pairs} ->
        {:ok,
         pairs
         |> Enum.reverse()
         |> Enum.group_by(fn {_coord, owner} -> owner end, fn {coord, _owner} -> coord end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_participants(routes_by_chunk, cells_by_chunk, request) do
    routed_chunks =
      Enum.reduce_while(routes_by_chunk, {:ok, []}, fn {coord, route}, {:ok, acc} ->
        case Routing.scene_node_for_route(route) do
          {:ok, scene_node} ->
            lease = Map.fetch!(route, :lease)
            directory = chunk_directory_module_for({lease.region_id, lease.lease_id})
            {:cont, {:ok, [{coord, route, scene_node, directory} | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    with {:ok, routed_chunks} <- routed_chunks do
      chunks_by_owner =
        Enum.group_by(
          routed_chunks,
          fn {_coord, _route, scene_node, directory} -> {directory, scene_node} end,
          fn {coord, route, _scene_node, _directory} -> {coord, route} end
        )

      chunks_by_owner
      |> Enum.reduce_while({:ok, []}, fn {{directory, scene_node}, entries}, {:ok, acc} ->
        chunks = entries |> Enum.map(fn {coord, _route} -> coord end) |> Enum.sort()

        first_route =
          entries
          |> Enum.sort_by(fn {coord, _route} -> coord end)
          |> List.first()
          |> elem(1)

        case build_participant(
               {directory, scene_node},
               chunks,
               first_route,
               routes_by_chunk,
               cells_by_chunk,
               request
             ) do
          {:ok, participant} -> {:cont, {:ok, [participant | acc]}}
        end
      end)
      |> case do
        {:ok, participants} -> {:ok, Enum.reverse(participants)}
        {:error, _} = err -> err
      end
    end
  end

  defp build_participant(
         {directory, scene_node},
         chunks,
         first_route,
         routes_by_chunk,
         cells_by_chunk,
         request
       ) do
    lease = Map.fetch!(first_route, :lease)
    chunks_sorted = Enum.sort(chunks)

    chunk_owners =
      Map.new(chunks_sorted, fn chunk_coord ->
        chunk_lease = routes_by_chunk |> Map.fetch!(chunk_coord) |> Map.fetch!(:lease)
        {chunk_coord, {chunk_lease.region_id, chunk_lease.lease_id}}
      end)

    intents_by_chunk =
      chunks_sorted
      |> Enum.map(fn chunk_coord ->
        cells_in_chunk = Map.fetch!(cells_by_chunk, chunk_coord)
        chunk_lease = routes_by_chunk |> Map.fetch!(chunk_coord) |> Map.fetch!(:lease)

        {chunk_coord, intents_for_chunk(cells_in_chunk, request, chunk_coord, chunk_lease)}
      end)
      |> Map.new()

    participant = %{
      participant_key: {:scene_owner, directory, scene_node},
      lease: lease,
      scene_node: scene_node,
      assigned_scene_node: scene_node,
      chunk_directory_module: directory,
      chunk_coords: chunks_sorted,
      chunk_owners: chunk_owners,
      intents_by_chunk: intents_by_chunk
    }

    {:ok, participant}
  end

  defp intents_for_chunk(cells_in_chunk, request, chunk_coord, lease) do
    Enum.map(cells_in_chunk, fn cell ->
      %{
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: chunk_coord,
        lease: lease,
        operation: :put_micro_block,
        macro: cell.local_macro,
        micro_slot: cell.micro_slot,
        micro_layer: cell.layer_attrs,
        opts: [reject_occupied: true, return_snapshot_payload: false]
      }
    end)
  end

  defp single_chunk_plan(%{participants: [participant], chunk_coords: [chunk_coord]}) do
    case Map.fetch(participant.intents_by_chunk, chunk_coord) do
      {:ok, intents} -> {:ok, participant, chunk_coord, intents}
      :error -> :error
    end
  end

  defp single_chunk_plan(_plan), do: :error

  defp same_owner_plan(%{participants: [_ | _] = participants, chunk_coords: chunk_coords})
       when length(chunk_coords) > 1 do
    case participants |> Enum.map(&chunk_directory_ref/1) |> Enum.uniq() do
      [_single_owner] -> {:ok, participants}
      _multiple_owners -> :error
    end
  end

  defp same_owner_plan(_plan), do: :error

  defp apply_single_chunk(participant, plan, chunk_coord, intents, request, ctx, total) do
    started_at = System.monotonic_time(:millisecond)
    chunk_directory = chunk_directory_ref(participant)

    Sink.emit(ctx.sink, "voxel_prefab_single_chunk_fast_path_started", fn ->
      %{
        connection_pid: self(),
        cid: ctx.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_coord: chunk_coord,
        cell_count: total,
        region_id: participant.lease.region_id,
        lease_id: participant.lease.lease_id,
        scene_node: participant.scene_node
      }
    end)

    # 服务端权威反悬空兜底:放置前只读邻接校验(客户端已 snap+校验,这是兜底)。
    # 仅覆盖单 chunk fast path —— builtins 都是单 macro、宏格对齐时落单 chunk。
    # TODO(多 chunk):same-owner fast path / 跨 region transaction 路径暂不接此校验;
    # 跨 chunk 邻居本就放行(宽松),但多 chunk prefab 的整体悬空判定要在那些路径单独补。
    if intents_floating?(chunk_directory, intents) do
      Sink.emit(ctx.sink, "voxel_prefab_floating_rejected", fn ->
        %{
          connection_pid: self(),
          cid: ctx.cid,
          request_id: request.request_id,
          logical_scene_id: request.logical_scene_id,
          blueprint_id: request.blueprint_id,
          chunk_coord: chunk_coord,
          cell_count: total,
          region_id: participant.lease.region_id,
          lease_id: participant.lease.lease_id
        }
      end)

      {:error, %{reason: :prefab_floating, applied_cell_count: 0, total_cell_count: total}}
    else
      apply_single_chunk_after_check(
        participant,
        plan,
        chunk_coord,
        intents,
        request,
        ctx,
        total,
        chunk_directory,
        started_at
      )
    end
  end

  # 邻接校验失败(chunk 解析失败 / intents 非法)按"非悬空"放行 —— 不让校验本身的
  # 错误阻断合法放置;真正的下游错误仍由后续 apply_intents 返回。返回 true 仅当
  # ChunkDirectory 明确判定悬空。
  defp intents_floating?(chunk_directory, intents) do
    case SceneServer.Voxel.ChunkDirectory.prefab_floating?(chunk_directory, intents) do
      {:ok, floating?} -> floating?
      {:error, _reason} -> false
    end
  rescue
    _exception -> false
  catch
    :exit, _reason -> false
  end

  defp apply_single_chunk_after_check(
         participant,
         plan,
         chunk_coord,
         intents,
         request,
         ctx,
         total,
         chunk_directory,
         started_at
       ) do
    case SceneServer.Voxel.ChunkDirectory.apply_intents(chunk_directory, intents) do
      {:ok, summary} ->
        register_scene_object(plan, participant, ctx)

        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        Sink.emit(ctx.sink, "voxel_prefab_single_chunk_fast_path_applied", fn ->
          %{
            connection_pid: self(),
            cid: ctx.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_coord: chunk_coord,
            cell_count: total,
            changed_count: Map.get(summary, :changed_count, 0),
            skipped_count: Map.get(summary, :skipped_count, 0),
            chunk_version: Map.get(summary, :chunk_version, 0),
            persist_result: Map.get(summary, :persist_result),
            elapsed_ms: elapsed_ms
          }
        end)

        {:ok,
         %{
           cell_count: total,
           chunk_count: 1,
           max_chunk_version: Map.get(summary, :chunk_version, 0)
         }}

      {:error, reason} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        Sink.emit(ctx.sink, "voxel_prefab_single_chunk_fast_path_failed", fn ->
          %{
            connection_pid: self(),
            cid: ctx.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_coord: chunk_coord,
            cell_count: total,
            reason: inspect(reason),
            elapsed_ms: elapsed_ms
          }
        end)

        {:error, %{reason: reason, applied_cell_count: 0, total_cell_count: total}}
    end
  end

  defp apply_same_owner(participants, plan, request, ctx, total) do
    started_at = System.monotonic_time(:millisecond)
    transaction_id = unique_transaction_id(request)
    chunk_directory = chunk_directory_ref(List.first(participants))

    Sink.emit(ctx.sink, "voxel_prefab_same_owner_fast_path_started", fn ->
      %{
        connection_pid: self(),
        cid: ctx.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_count: length(plan.chunk_coords),
        participant_count: length(participants),
        cell_count: total,
        chunk_directory: inspect(chunk_directory)
      }
    end)

    case PrefabLocalTransaction.execute(
           participants,
           transaction_id,
           request.logical_scene_id,
           &chunk_directory_ref/1
         ) do
      {:ok, %{participant_results: participant_results}} ->
        register_scene_object(plan, List.first(participants), ctx)

        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        max_version = max_chunk_version_from_results(participant_results)

        Sink.emit(ctx.sink, "voxel_prefab_same_owner_fast_path_applied", fn ->
          %{
            connection_pid: self(),
            cid: ctx.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_count: length(plan.chunk_coords),
            participant_count: length(participants),
            cell_count: total,
            max_chunk_version: max_version,
            elapsed_ms: elapsed_ms
          }
        end)

        {:ok,
         %{
           cell_count: total,
           chunk_count: length(plan.chunk_coords),
           max_chunk_version: max_version
         }}

      {:error, %{reason: raw_reason} = error} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        reason = unwrap_prepare_reason(raw_reason)

        Sink.emit(ctx.sink, "voxel_prefab_same_owner_fast_path_failed", fn ->
          %{
            connection_pid: self(),
            cid: ctx.cid,
            request_id: request.request_id,
            logical_scene_id: request.logical_scene_id,
            blueprint_id: request.blueprint_id,
            chunk_count: length(plan.chunk_coords),
            participant_count: length(participants),
            cell_count: total,
            reason: inspect(reason),
            elapsed_ms: elapsed_ms
          }
        end)

        {:error,
         %{
           reason: reason || Map.get(error, :reason, :prefab_same_owner_fast_path_failed),
           applied_cell_count: 0,
           total_cell_count: total
         }}
    end
  end

  defp register_scene_object(%{scene_object: scene_object}, %{scene_node: scene_node}, ctx) do
    case :rpc.call(
           scene_node,
           SceneServer.Voxel.BuildTransactionApplier,
           :register_scene_objects,
           [[scene_object], []],
           5_000
         ) do
      :ok ->
        :ok

      other ->
        Sink.emit(ctx.sink, "voxel_prefab_scene_object_register_failed", fn ->
          %{
            object_id: Map.get(scene_object, :object_id),
            logical_scene_id: Map.get(scene_object, :logical_scene_id),
            reason: inspect(other)
          }
        end)

        :ok
    end
  end

  defp register_scene_object(_plan, _participant, _ctx), do: :ok

  defp chunk_directory_ref(%{chunk_directory_module: module, scene_node: scene_node}) do
    {module, scene_node}
  end

  defp chunk_directory_ref(%{participant_key: participant_key, scene_node: scene_node}) do
    module = chunk_directory_module_for(participant_key)
    {module, scene_node}
  end

  defp emit_routed_observe(request, ctx, participants, cell_count) do
    Sink.emit(ctx.sink, "voxel_prefab_routed", fn ->
      %{
        connection_pid: self(),
        cid: ctx.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        blueprint_id: request.blueprint_id,
        chunk_count: Enum.reduce(participants, 0, fn p, acc -> acc + length(p.chunk_coords) end),
        cell_count: cell_count,
        participant_count: length(participants),
        participants:
          Enum.map(participants, fn p ->
            %{
              participant_key: inspect(p.participant_key),
              region_id: p.lease.region_id,
              lease_id: p.lease.lease_id,
              owner_scene_instance_ref: p.lease.owner_scene_instance_ref,
              owner_epoch: p.lease.owner_epoch,
              scene_node: p.scene_node,
              chunk_owner_count: map_size(p.chunk_owners),
              chunk_count: length(p.chunk_coords)
            }
          end)
      }
    end)
  end

  # Phase 3 D5 calls for `BeaconServer.Client.lookup(:voxel_transaction_coordinator)`
  # directly, but Gate's existing service discovery already routes through
  # `GateServer.Interface` (whose internals are BeaconServer-backed), and the
  # gate test fixtures intercept that entry point via `FakeInterface`. Going
  # through the shared World-node lookup keeps the test mock surface stable while
  # preserving the same lookup semantics (single coordinator per world node,
  # 1:1 with `:world_server` resource). Recorded as a deliberate refinement
  # in the Phase 3 progress log.
  defp locate_transaction_coordinator do
    case Routing.world_node() do
      {:ok, world_node} ->
        {:ok, {WorldServer.Voxel.TransactionCoordinator, world_node}}

      {:error, _reason} ->
        {:error, :voxel_transaction_coordinator_unavailable}
    end
  end

  defp coordinator_begin_transaction(coordinator_ref, plan, request) do
    transaction_id = unique_transaction_id(request)

    attrs = %{
      logical_scene_id: request.logical_scene_id,
      parcel_id: Map.get(request, :parcel_id, 0),
      reservation_id: reservation_id(request),
      decision_version: 1,
      participants:
        Enum.map(plan.participants, fn p ->
          %{
            participant_key: p.participant_key,
            region_id: p.lease.region_id,
            lease_id: p.lease.lease_id,
            owner_scene_instance_ref: p.lease.owner_scene_instance_ref,
            owner_epoch: p.lease.owner_epoch,
            assigned_scene_node: p.assigned_scene_node,
            chunk_owners: p.chunk_owners,
            affected_chunks: p.chunk_coords
          }
        end),
      scene_objects: Map.get(plan, :scene_objects, [])
    }

    try do
      case WorldServer.Voxel.TransactionCoordinator.begin_transaction(
             coordinator_ref,
             transaction_id,
             attrs
           ) do
        {:ok, transaction} -> {:ok, transaction}
        {:error, reason} -> {:error, {:coordinator_begin_failed, reason}}
      end
    catch
      :exit, _reason -> {:error, :coordinator_unavailable}
    end
  end

  # plan.participants 已经按 Scene owner 分组,这里直接把每个 participant 的
  # intents_by_chunk + scene_node 摊成 by-participant 两份 map 喂给 executor。
  # 单 Scene-owner participant 可以包含多个 region/lease;chunk_owners 保留
  # 真实 owner。
  defp executor_execute(coordinator_ref, transaction, plan) do
    intents_by_participant =
      plan.participants
      |> Enum.map(fn p -> {p.participant_key, p.intents_by_chunk} end)
      |> Map.new()

    scene_opts_by_participant =
      plan.participants
      |> Enum.map(fn p ->
        {p.participant_key, [chunk_directory: chunk_directory_ref(p)]}
      end)
      |> Map.new()

    try do
      WorldServer.Voxel.TransactionExecutor.execute(
        coordinator_ref,
        transaction,
        intents_by_participant,
        scene_opts_by_participant: scene_opts_by_participant
      )
    catch
      :exit, _reason -> {:error, :executor_crashed}
    end
  end

  # Phase A4-5:per-participant chunk_directory module 解析。生产 default
  # `SceneServer.Voxel.ChunkDirectory`(单 module 跨所有 region);test 注入
  # `:voxel_chunk_directory_resolver` env fn 让不同 participant 路由到不同
  # named instance(`ChunkDirectory.RegionA` / `ChunkDirectory.RegionB`),
  # 在单 BEAM 内模拟多 scene_node 部署。A4-bis-cluster 落地后 default 改为
  # 走 `RegionRouting.resolve_chunk_directory/1`。
  defp chunk_directory_module_for(participant_key) do
    case Application.get_env(:gate_server, :voxel_chunk_directory_resolver) do
      nil -> SceneServer.Voxel.ChunkDirectory
      fun when is_function(fun, 1) -> fun.(participant_key)
    end
  end

  defp finalize_outcome(executor_result, plan, total) do
    case executor_result do
      %{decision: :commit, participant_results: results} ->
        max_version = max_chunk_version_from_results(results)

        {:ok,
         %{
           cell_count: total,
           chunk_count: length(plan.chunk_coords),
           max_chunk_version: max_version
         }}

      %{decision: :abort, prepare_results: prepare_results} ->
        reason = first_prepare_failure_reason(prepare_results) || :prefab_transaction_aborted

        {:error,
         %{
           reason: reason,
           applied_cell_count: 0,
           total_cell_count: total
         }}
    end
  end

  defp max_chunk_version_from_results(results) do
    Enum.reduce(results, 0, fn
      {_participant, {:ok, summary}}, acc ->
        committed = Map.get(summary, :committed_chunks, [])

        Enum.reduce(committed, acc, fn {_chunk, chunk_summary}, inner ->
          max(inner, Map.get(chunk_summary, :chunk_version, 0))
        end)

      _, acc ->
        acc
    end)
  end

  defp first_prepare_failure_reason(prepare_results) do
    prepare_results
    |> Enum.find_value(fn
      {_participant, {:error, reason}} -> reason
      _ -> nil
    end)
    |> unwrap_prepare_reason()
  end

  # Phase A1-2:`BuildTransactionApplier.prepare_chunks` 把 chunk 级 prepare
  # 失败 wrap 成 `{:prepare_failed, chunk_coord, inner_reason}`。Gate wire
  # 透传给 client 时,wrapped tuple 在 :reason 字段会变成
  # `"{:prepare_failed, {0, 0, 0}, :micro_slot_already_occupied}"` 这种串,
  # client UI 难以识别业务级 reject。这里 unwrap 成 inner atom 让 wire reason
  # 跟 single-intent path(0x70 voxel_edit_intent → :stale_chunk_version 之类)
  # 风格一致。其他 wrap 形式(:commit_failed 等)保持原样。
  defp unwrap_prepare_reason({:prepare_failed, _chunk_coord, inner_reason}), do: inner_reason
  defp unwrap_prepare_reason(other), do: other

  defp unique_transaction_id(request) do
    unique = System.unique_integer([:positive, :monotonic])
    "prefab-#{request.request_id}-#{unique}"
  end

  defp reservation_id(request) do
    "prefab-reservation-#{request.request_id}"
  end
end
