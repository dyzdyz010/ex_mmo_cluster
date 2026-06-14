defmodule SceneServer.Voxel.Field.FieldTickWorker do
  @moduledoc """
  Phase 6 局部场最小目标:per-region GenServer。

  独立于 ChunkProcess simulation_tick(100ms)、prepare_transaction /
  commit_transaction 链路,持有整个 FieldRegion 状态。**调度由节点级
  `SceneServer.Voxel.Field.SimRuntime` 统一驱动**(梯队2 step2.6,NIF-1/5):本 worker
  init 后经 `handle_continue(:subscribe)` 订阅 SimRuntime,由其单一 clock + CPU 预算每拍
  调 `:run_tick`(不再自 `send_after`)。每 tick:
    1. 调 FieldKernel 更新 layers。
    2. 调 FieldCodec.encode_snapshot_payload/2 编出 0x73 wire。
    3. 将 non-observe kernel effects 交给 ChunkProcess authority dispatcher。
    4. `ChunkProcess.push_field_snapshot_payload/2` 把 payload 投到 chunk
       的 cast 通道,由 ChunkProcess fanout 给 subscribers。
    5. 到 max_ticks 时,push FieldRegionDestroyed(0x74)并 stop。
    6. 监听绑定 chunk 进程 DOWN → stop。
  """

  use GenServer

  alias SceneServer.CliObserve

  alias SceneServer.Voxel.ChunkProcess

  alias SceneServer.Voxel.Field.{
    FieldCodec,
    FieldLayer,
    FieldRegion,
    KernelContext,
    SimRuntime
  }

  @default_tick_interval_ms 100

  @type opts :: [
          region: FieldRegion.t(),
          chunk_pid: pid(),
          storage_fn: (-> any()),
          logical_scene_id: non_neg_integer(),
          tick_interval_ms: pos_integer(),
          sim_runtime: GenServer.server()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Queues additional source points onto an active field region."
  @spec add_source_points(GenServer.server(), [FieldRegion.source_point()]) :: :ok
  def add_source_points(server, source_points) when is_list(source_points) do
    GenServer.cast(server, {:add_source_points, source_points})
  end

  @doc "Replaces the source points on an active field region."
  @spec replace_source_points(GenServer.server(), [FieldRegion.source_point()]) :: :ok
  def replace_source_points(server, source_points) when is_list(source_points) do
    GenServer.cast(server, {:replace_source_points, source_points})
  end

  @doc """
  Queues an active field region refresh in place.

  This keeps the worker process and region id stable for subscribers while
  restarting the region lifetime from the latest source request. The refresh is
  intentionally asynchronous: `ChunkProcess` must not wait on the worker while
  the worker may be ticking and reading chunk storage.
  """
  @spec refresh_region(GenServer.server(), map()) :: map()
  def refresh_region(server, attrs) when is_map(attrs) do
    summary = refresh_source_points_summary(attrs)
    GenServer.cast(server, {:refresh_region, attrs})
    Map.put(summary, :lifetime_action, :queued_refresh)
  end

  @impl true
  def init(opts) do
    region = Keyword.fetch!(opts, :region)
    chunk_pid = Keyword.fetch!(opts, :chunk_pid)
    storage_fn = Keyword.fetch!(opts, :storage_fn)
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    tick_interval_ms = Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms)
    sim_runtime = Keyword.get(opts, :sim_runtime, SimRuntime)

    chunk_monitor = Process.monitor(chunk_pid)

    safe_emit("voxel_field_region_created", fn ->
      %{
        region_id: region.region_id,
        chunk_coord: region.chunk_coord,
        field_types: region.field_types,
        max_ticks: region.max_ticks
      }
    end)

    # 梯队2 step2.6:不再自 send(:tick);订阅 SimRuntime 放 handle_continue,避免 init 期与
    # ensure_field_region → ChunkProcess.get_storage 回调链死锁,且 SimRuntime 缺失即显式 crash。
    {:ok,
     %{
       region: region,
       chunk_pid: chunk_pid,
       chunk_monitor: chunk_monitor,
       storage_fn: storage_fn,
       logical_scene_id: logical_scene_id,
       tick_interval_ms: tick_interval_ms,
       sim_runtime: sim_runtime
     }, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    SimRuntime.subscribe(state.sim_runtime, self())
    {:noreply, state}
  end

  @impl true
  def handle_call(:run_tick, _from, state) do
    %{
      region: region,
      chunk_pid: chunk_pid,
      storage_fn: storage_fn,
      logical_scene_id: logical_scene_id,
      tick_interval_ms: tick_interval_ms
    } = state

    started_us = System.monotonic_time(:microsecond)
    storage = safe_call_storage_fn(storage_fn)

    {region, effect_batches} =
      run_field_kernels(region, storage, logical_scene_id, tick_interval_ms)

    region = FieldRegion.increment_tick(region)

    payload = FieldCodec.encode_snapshot_payload(region, logical_scene_id)
    cells_updated = count_active_cells(region)

    push_snapshot(chunk_pid, payload)

    snapshot_dispatch_us = System.monotonic_time(:microsecond) - started_us

    safe_emit("voxel_field_snapshot_dispatched", fn ->
      %{
        region_id: region.region_id,
        chunk_coord: region.chunk_coord,
        cell_count: cells_updated,
        byte_size: byte_size(payload),
        snapshot_dispatch_us: snapshot_dispatch_us
      }
    end)

    dispatch_kernel_effect_batches(chunk_pid, effect_batches)

    duration_us = System.monotonic_time(:microsecond) - started_us

    safe_emit("voxel_field_tick_completed", fn ->
      %{
        region_id: region.region_id,
        tick_count: region.tick_count,
        cells_updated: cells_updated,
        snapshot_dispatch_us: snapshot_dispatch_us,
        tick_duration_us: duration_us
      }
    end)

    if FieldRegion.tick_limit_reached?(region) do
      destroyed_payload =
        FieldCodec.encode_destroyed_payload(
          region.region_id,
          region.chunk_coord,
          logical_scene_id,
          :expired
        )

      push_destroyed(chunk_pid, destroyed_payload)

      safe_emit("voxel_field_region_destroyed", fn ->
        %{
          region_id: region.region_id,
          chunk_coord: region.chunk_coord,
          destroy_reason: :expired
        }
      end)

      {:stop, :normal, :ok, %{state | region: region}}
    else
      # 梯队2 step2.6:不再 schedule_tick;下一拍由 SimRuntime clock 驱动。
      {:reply, :ok, %{state | region: region}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{chunk_monitor: ref} = state) do
    safe_emit("voxel_field_region_destroyed", fn ->
      %{
        region_id: state.region.region_id,
        chunk_coord: state.region.chunk_coord,
        destroy_reason: :chunk_crash
      }
    end)

    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:add_source_points, source_points}, state) when is_list(source_points) do
    region = %{
      state.region
      | source_points: state.region.source_points ++ source_points
    }

    {:noreply, %{state | region: region}}
  end

  def handle_cast({:replace_source_points, source_points}, state) when is_list(source_points) do
    region = %{state.region | source_points: source_points}

    {:noreply, %{state | region: region}}
  end

  def handle_cast({:refresh_region, attrs}, state) when is_map(attrs) do
    {source_points, source_points_summary} = refreshed_source_points(state.region, attrs)

    region_attrs = %{
      region_id: state.region.region_id,
      chunk_coord: Map.get(attrs, :chunk_coord, state.region.chunk_coord),
      aabb: Map.get(attrs, :aabb, state.region.aabb),
      kernels: Map.get(attrs, :kernels, state.region.kernels),
      source_points: source_points,
      max_ticks: Map.get(attrs, :max_ticks, state.region.max_ticks),
      lease_token: Map.get(attrs, :lease_token, state.region.lease_token)
    }

    refreshed_region = FieldRegion.new(region_attrs)

    safe_emit("voxel_field_region_refresh_queued", fn ->
      %{
        region_id: refreshed_region.region_id,
        chunk_coord: refreshed_region.chunk_coord,
        max_ticks: refreshed_region.max_ticks
      }
      |> Map.merge(source_points_summary)
    end)

    {:noreply, %{state | region: refreshed_region}}
  end

  # ---- helpers --------------------------------------------------------------

  defp run_field_kernels(region, storage, logical_scene_id, tick_interval_ms) do
    {region, batches} =
      Enum.reduce(region.kernels, {region, []}, fn kernel_spec, {acc, batches} ->
        context = KernelContext.new(acc, logical_scene_id, storage, dt_ms: tick_interval_ms)
        {next_region, batch} = run_kernel(kernel_spec, acc, context)

        batches =
          case batch do
            nil -> batches
            batch -> [batch | batches]
          end

        {next_region, batches}
      end)

    {region, Enum.reverse(batches)}
  end

  defp refreshed_source_points(%FieldRegion{} = region, attrs) do
    case Map.fetch(attrs, :source_points) do
      {:ok, source_points} when is_list(source_points) and source_points != [] ->
        summary = refresh_source_points_summary(attrs)

        if Map.get(summary, :source_points_action) == :replaced do
          {source_points, summary}
        else
          next_source_points = region.source_points ++ source_points

          {next_source_points, summary}
        end

      {:ok, []} ->
        {region.source_points, refresh_source_points_summary(attrs)}

      {:ok, _other} ->
        {region.source_points, refresh_source_points_summary(attrs)}

      :error ->
        {region.source_points, refresh_source_points_summary(attrs)}
    end
  end

  defp refresh_source_points_summary(attrs) do
    case Map.fetch(attrs, :source_points) do
      {:ok, source_points} when is_list(source_points) and source_points != [] ->
        %{
          source_points_action:
            if(source_points_mode(attrs) == :replace, do: :replaced, else: :appended),
          source_points_count: length(source_points)
        }

      {:ok, []} ->
        %{
          source_points_action: :rejected,
          source_points_count: 0,
          source_points_rejection_reason: :empty_source_points
        }

      {:ok, _other} ->
        %{
          source_points_action: :rejected,
          source_points_count: 0,
          source_points_rejection_reason: :invalid_source_points
        }

      :error ->
        %{
          source_points_action: :rejected,
          source_points_count: 0,
          source_points_rejection_reason: :missing_source_points
        }
    end
  end

  defp source_points_mode(attrs) do
    case Map.get(attrs, :source_points_mode) do
      :replace -> :replace
      "replace" -> :replace
      _other -> :append
    end
  end

  defp run_kernel(%{id: id, module: module, opts: opts}, region, context) do
    case module.tick(region, context, opts) do
      {:cont, %FieldRegion{} = next_region, effects} when is_list(effects) ->
        {next_region, {id, next_region, effects}}

      {:done, %FieldRegion{} = next_region, effects} when is_list(effects) ->
        {next_region, {id, next_region, effects}}

      other ->
        emit_kernel_failed(region, id, module, {:invalid_return, other})
        {region, nil}
    end
  rescue
    error ->
      emit_kernel_failed(
        region,
        id,
        module,
        {:exception, error.__struct__, Exception.message(error)}
      )

      {region, nil}
  catch
    kind, reason ->
      emit_kernel_failed(region, id, module, {kind, reason})
      {region, nil}
  end

  defp run_kernel(kernel_spec, region, _context) do
    emit_kernel_failed(region, :unknown, :unknown, {:invalid_kernel_spec, kernel_spec})
    {region, nil}
  end

  defp dispatch_kernel_effect_batches(_chunk_pid, []), do: :ok

  defp dispatch_kernel_effect_batches(chunk_pid, batches) do
    Enum.each(batches, fn {kernel_id, region, effects} ->
      handle_kernel_effects(kernel_id, region, effects, chunk_pid)
    end)
  end

  defp handle_kernel_effects(kernel_id, region, effects, chunk_pid) do
    {observe_effects, field_effects} =
      Enum.split_with(effects, fn
        {:emit_observe, event, fields} when is_binary(event) and is_map(fields) -> true
        _other -> false
      end)

    Enum.each(observe_effects, fn
      {:emit_observe, event, fields} when is_binary(event) and is_map(fields) ->
        safe_emit(event, fn ->
          fields
          |> Map.put_new(:region_id, region.region_id)
          |> Map.put_new(:chunk_coord, region.chunk_coord)
          |> Map.put_new(:kernel_id, kernel_id)
        end)
    end)

    dispatch_field_effects(chunk_pid, kernel_id, region, field_effects)
  end

  defp dispatch_field_effects(_chunk_pid, _kernel_id, _region, []), do: :ok

  defp dispatch_field_effects(chunk_pid, kernel_id, region, effects) do
    case ChunkProcess.apply_field_effects(chunk_pid, effects, %{
           region_id: region.region_id,
           chunk_coord: region.chunk_coord,
           kernel_id: kernel_id
         }) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        emit_field_effect_dispatch_failed(region, kernel_id, reason)
    end
  rescue
    error ->
      emit_field_effect_dispatch_failed(
        region,
        kernel_id,
        {:exception, error.__struct__, Exception.message(error)}
      )
  catch
    kind, reason ->
      emit_field_effect_dispatch_failed(region, kernel_id, {kind, reason})
  end

  defp emit_kernel_failed(region, kernel_id, module, reason) do
    safe_emit("voxel_field_tick_failed", fn ->
      %{
        region_id: region.region_id,
        chunk_coord: region.chunk_coord,
        kernel_id: kernel_id,
        kernel_module: inspect(module),
        reason: inspect(reason)
      }
    end)
  end

  defp emit_field_effect_dispatch_failed(region, kernel_id, reason) do
    safe_emit("voxel_field_effect_dispatch_failed", fn ->
      %{
        region_id: region.region_id,
        chunk_coord: region.chunk_coord,
        kernel_id: kernel_id,
        reason: inspect(reason)
      }
    end)
  end

  defp count_active_cells(region) do
    Enum.sum(
      Enum.map(region.field_types, fn ft ->
        layer = FieldRegion.get_layer(region, ft)
        length(FieldLayer.active_cells(layer, region.aabb))
      end)
    )
  end

  defp safe_call_storage_fn(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp safe_call_storage_fn(_), do: nil

  defp push_snapshot(chunk_pid, payload) do
    try do
      ChunkProcess.push_field_snapshot_payload(chunk_pid, payload)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp push_destroyed(chunk_pid, payload) do
    try do
      ChunkProcess.push_field_region_destroyed_payload(chunk_pid, payload)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp safe_emit(event, fun) do
    try do
      CliObserve.emit(event, fun)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end
