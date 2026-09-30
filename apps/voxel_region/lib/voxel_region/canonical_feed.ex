defmodule VoxelRegion.CanonicalFeed do
  @moduledoc """
  全局系统功能：一个 canonical 订阅者的发送进程。World 把窗口快照（区域字节与属性，已在同一 seq 取好）和之后的增量
  按提交次序交给它；它在自己的进程里解码区域、投影碰撞 chunk（纯计算，原先在 World 进程里每次 0.1–0.2 s），发出快照后
  按收到次序转发增量。订阅者只从这一个进程收消息，次序与 World 直接发送时相同；订阅者退出时随之退出。
  """
  require Logger
  alias VoxelRegion.CollisionSource

  def start_link(subscriber) do
    spawn_link(fn ->
      Process.monitor(subscriber)
      loop(subscriber)
    end)
  end

  defp loop(subscriber) do
    receive do
      {:snapshot, request, snapshot, include_chunks, capacity, from} ->
        started = System.monotonic_time(:microsecond)
        chunks = if include_chunks, do: CollisionSource.snapshot_chunks(snapshot.regions, capacity), else: []
        send(subscriber, {:canonical_snapshot, request, %{snapshot | chunks: chunks}})
        GenServer.reply(from, :ok)

        Logger.info(
          "voxel_window_stage stage=feed_sent request=#{inspect(request)} seq=#{snapshot.transaction_seq} " <>
            "chunks=#{length(chunks)} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
        )

        loop(subscriber)

      {:canonical_delta, _} = delta ->
        send(subscriber, delta)
        loop(subscriber)

      {:DOWN, _, :process, ^subscriber, _} ->
        :ok
    end
  end
end
