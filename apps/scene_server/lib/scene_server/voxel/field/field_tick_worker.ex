defmodule SceneServer.Voxel.Field.FieldTickWorker do
  @moduledoc """
  Phase 6 局部场最小目标:per-region GenServer。

  独立于 ChunkProcess simulation_tick(100ms)、prepare_transaction /
  commit_transaction 链路,自己 schedule 10Hz tick(默认 100ms),持有
  整个 FieldRegion 状态。每 tick:
    1. 调 algorithm(TemperatureField / ElectricField)更新 layers。
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
    ElectricField,
    FieldCodec,
    FieldLayer,
    FieldRegion,
    TemperatureField
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
      |> run_field_algorithms(storage)
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

  # ---- helpers --------------------------------------------------------------

  defp run_field_algorithms(region, storage) do
    Enum.reduce(region.field_types, region, fn field_type, acc ->
      case field_type do
        :temperature -> TemperatureField.tick(acc, storage)
        :electric_potential -> ElectricField.tick(acc, storage)
        :ionization -> acc
        _ -> acc
      end
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
