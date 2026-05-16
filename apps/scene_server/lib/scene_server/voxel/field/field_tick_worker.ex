defmodule SceneServer.Voxel.Field.FieldTickWorker do
  @moduledoc """
  Phase 6 局部场最小目标:per-region GenServer。

  独立于 ChunkProcess simulation_tick(100ms)、prepare_transaction /
  commit_transaction 链路,自己 schedule 10Hz tick(默认 100ms),持有
  整个 FieldRegion 状态。每 tick:
    1. 调 FieldKernel 更新 layers。
    2. 调 FieldCodec.encode_snapshot_payload/2 编出 0x73 wire。
    3. `ChunkProcess.push_field_snapshot_payload/2` 把 payload 投到 chunk
       的 cast 通道,由 ChunkProcess fanout 给 subscribers。
    4. 到 max_ticks 时,push FieldRegionDestroyed(0x74)并 stop。
    5. 监听绑定 chunk 进程 DOWN → stop。
  """

  use GenServer

  alias SceneServer.CliObserve

  alias SceneServer.Voxel.ChunkProcess

  alias SceneServer.Voxel.Field.{
    FieldCodec,
    FieldLayer,
    FieldRegion,
    KernelContext
  }

  @default_tick_interval_ms 100

  @type opts :: [
          region: FieldRegion.t(),
          chunk_pid: pid(),
          storage_fn: (-> any()),
          logical_scene_id: non_neg_integer(),
          tick_interval_ms: pos_integer()
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

  @impl true
  def init(opts) do
    region = Keyword.fetch!(opts, :region)
    chunk_pid = Keyword.fetch!(opts, :chunk_pid)
    storage_fn = Keyword.fetch!(opts, :storage_fn)
    logical_scene_id = Keyword.fetch!(opts, :logical_scene_id)
    tick_interval_ms = Keyword.get(opts, :tick_interval_ms, @default_tick_interval_ms)

    chunk_monitor = Process.monitor(chunk_pid)

    safe_emit("voxel_field_region_created", fn ->
      %{
        region_id: region.region_id,
        chunk_coord: region.chunk_coord,
        field_types: region.field_types,
        max_ticks: region.max_ticks
      }
    end)

    schedule_tick(tick_interval_ms)

    {:ok,
     %{
       region: region,
       chunk_pid: chunk_pid,
       chunk_monitor: chunk_monitor,
       storage_fn: storage_fn,
       logical_scene_id: logical_scene_id,
       tick_interval_ms: tick_interval_ms
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    %{
      region: region,
      chunk_pid: chunk_pid,
      storage_fn: storage_fn,
      logical_scene_id: logical_scene_id,
      tick_interval_ms: tick_interval_ms
    } = state

    started_us = System.monotonic_time(:microsecond)
    storage = safe_call_storage_fn(storage_fn)

    region =
      region
      |> run_field_kernels(storage, logical_scene_id, tick_interval_ms)
      |> FieldRegion.increment_tick()

    payload = FieldCodec.encode_snapshot_payload(region, logical_scene_id)
    cells_updated = count_active_cells(region)

    push_snapshot(chunk_pid, payload)

    duration_us = System.monotonic_time(:microsecond) - started_us

    safe_emit("voxel_field_tick_completed", fn ->
      %{
        region_id: region.region_id,
        tick_count: region.tick_count,
        cells_updated: cells_updated,
        tick_duration_us: duration_us
      }
    end)

    safe_emit("voxel_field_snapshot_dispatched", fn ->
      %{
        region_id: region.region_id,
        chunk_coord: region.chunk_coord,
        cell_count: cells_updated,
        byte_size: byte_size(payload)
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

      {:stop, :normal, %{state | region: region}}
    else
      schedule_tick(tick_interval_ms)
      {:noreply, %{state | region: region}}
    end
  end

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

  # ---- helpers --------------------------------------------------------------

  defp run_field_kernels(region, storage, logical_scene_id, tick_interval_ms) do
    Enum.reduce(region.kernels, region, fn kernel_spec, acc ->
      context = KernelContext.new(acc, logical_scene_id, storage, dt_ms: tick_interval_ms)
      run_kernel(kernel_spec, acc, context)
    end)
  end

  defp run_kernel(%{id: id, module: module, opts: opts}, region, context) do
    case module.tick(region, context, opts) do
      {:cont, %FieldRegion{} = next_region, effects} when is_list(effects) ->
        handle_kernel_effects(id, next_region, effects)
        next_region

      {:done, %FieldRegion{} = next_region, effects} when is_list(effects) ->
        handle_kernel_effects(id, next_region, effects)
        next_region

      other ->
        emit_kernel_failed(region, id, module, {:invalid_return, other})
        region
    end
  rescue
    error ->
      emit_kernel_failed(
        region,
        id,
        module,
        {:exception, error.__struct__, Exception.message(error)}
      )

      region
  catch
    kind, reason ->
      emit_kernel_failed(region, id, module, {kind, reason})
      region
  end

  defp run_kernel(kernel_spec, region, _context) do
    emit_kernel_failed(region, :unknown, :unknown, {:invalid_kernel_spec, kernel_spec})
    region
  end

  defp handle_kernel_effects(kernel_id, region, effects) do
    Enum.each(effects, fn
      {:emit_observe, event, fields} when is_binary(event) and is_map(fields) ->
        safe_emit(event, fn ->
          fields
          |> Map.put_new(:region_id, region.region_id)
          |> Map.put_new(:chunk_coord, region.chunk_coord)
          |> Map.put_new(:kernel_id, kernel_id)
        end)

      _other ->
        :ok
    end)
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

  defp count_active_cells(region) do
    Enum.sum(
      Enum.map(region.field_types, fn ft ->
        layer = FieldRegion.get_layer(region, ft)
        length(FieldLayer.active_cells(layer, region.aabb))
      end)
    )
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
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
