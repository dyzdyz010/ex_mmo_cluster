defmodule VoxelRegion.CanonicalFeed do
  @moduledoc """
  全局系统功能：一个 canonical 订阅者的发送进程。World 同回合冻结输入与登记订阅；本进程按信用 1 拉取冻结条目，
  沿既有算法编码区域、汇总属性并投影碰撞。发出完整快照后再转发排队的增量，所有输出来自同一个进程。
  World 与本进程互相监视；订阅者退出时释放冻结输入与本进程，失败不拖垮权威进程、不发送部分快照。
  """
  require Logger
  alias VoxelRegion.CollisionSource
  alias VoxelRegion.World.WindowSnapshot

  @doc "由 World 启动并监视该订阅者的唯一发送进程。"
  def start(subscriber, world) do
    {pid, _} =
      spawn_monitor(fn ->
        sender = self()

        # 组装／文件读取可能阻塞本进程；独立的生命周期监视者必须能中断它，不能把 DOWN 排在组装之后。
        # 只与发送进程链接，不与 World 链接：发送失败不会反向杀掉权威；发送进程正常退出时监视者也退出。
        spawn_link(fn ->
          for pid <- [subscriber, world, sender], do: Process.monitor(pid)

          receive do
            {:DOWN, _, :process, ^sender, _} -> :ok
            {:DOWN, _, :process, _, _} -> exit(:shutdown)
          end
        end)

        loop(subscriber, world)
      end)

    pid
  end

  defp loop(subscriber, world) do
    receive do
      {:snapshot, token, request, box, include_chunks, capacity} ->
        started = System.monotonic_time(:microsecond)

        case snapshot(world, token, box, include_chunks, capacity) do
          {:ok, snapshot, payloads} ->
            send(subscriber, {:canonical_snapshot, request, snapshot})
            :ok = GenServer.call(world, {:window_finished, token, :ok, payloads}, 300_000)

            Logger.info(
              "voxel_window_stage stage=feed_sent request=#{inspect(request)} seq=#{snapshot.transaction_seq} " <>
                "chunks=#{length(snapshot.chunks)} elapsed_us=#{System.monotonic_time(:microsecond) - started} pid=#{inspect(self())}"
            )

            loop(subscriber, world)

          {:error, reason} = error ->
            Logger.error(
              "voxel_window_failed request=#{inspect(request)} reason=#{inspect(reason)}"
            )

            GenServer.call(world, {:window_finished, token, error, %{}}, 300_000)
        end

      {:canonical_delta, _} = delta ->
        send(subscriber, delta)
        loop(subscriber, world)
    end
  end

  defp snapshot(world, token, box, include_chunks, capacity) do
    with {:ok, snapshot, payloads} <- assemble(world, token, box) do
      # 组装输入（微格、epochs、目录等）不再被调用帧引用。先在发送进程释放它们，避免碰撞投影反复回收整份旧输入。
      # World 不执行这次回收；快照与已排队的增量仍由同一发送进程持有。
      started = System.monotonic_time(:microsecond)
      :erlang.garbage_collect()
      {:memory, bytes} = Process.info(self(), :memory)

      Logger.info(
        "voxel_window_stage stage=feed_input_released seq=#{snapshot.transaction_seq} " <>
          "memory_bytes=#{bytes} elapsed_us=#{System.monotonic_time(:microsecond) - started} pid=#{inspect(self())}"
      )

      chunks =
        if include_chunks,
          do: CollisionSource.snapshot_chunks(snapshot.regions, capacity),
          else: []

      {:ok, %{snapshot | chunks: chunks}, payloads}
    end
  rescue
    error -> {:error, {:canonical_assembly, Exception.message(error)}}
  end

  defp assemble(world, token, box) do
    with {:ok, view} <- input(world, token, %{}),
         {:ok, snapshot, %{payloads: payloads, snapshot_geometry: geometry}} <-
           WindowSnapshot.build(view, box) do
      for rows <- Enum.chunk_every(geometry, 16),
          do: :ok = GenServer.call(world, {:window_geometry, token, rows}, 300_000)

      {:ok, snapshot, payloads}
    end
  end

  defp input(world, token, view) do
    case GenServer.call(world, {:window_input, token}, 300_000) do
      :done -> {:ok, view}
      {:error, _} = error -> error
      items -> input(world, token, WindowSnapshot.accept(view, items))
    end
  end
end
