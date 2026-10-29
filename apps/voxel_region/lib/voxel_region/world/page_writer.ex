defmodule VoxelRegion.World.PageWriter do
  @moduledoc """
  全局系统功能（M2a 写回进程，`m2a-page-store.md` §5–§6）：替 World 编码页段、写库、发布切点、渐进删除。

  只持久化 World 从切点冻结状态抽出的值，不读 World 状态、不做裁决；同一时刻只有一个写回进程（World 在旧进程 `DOWN` 后才启动新的）。
  一次**尝试**（attempt）：`{:begin}` 先读持久前缀——已不低于切点即上次已发布（确认丢失），直接回“已发布”；否则删掉高于前缀的残留
  再回“可写”。之后每批写完回一个信用（`:page_ack`），`{:publish}` 写最后一批 + 全局行并推进前缀。发布后按前缀分批删除旧行。
  所有回复带尝试号，World 丢弃旧尝试的迟到结果。
  """
  use GenServer
  require Logger

  alias VoxelRegion.World.Pages

  @collect_batch 2_000

  # 与 World 链接：World 被关停时写回随之退出（未发布的写入下次启动按前缀清掉）；写回异常退出时 World 一起重启，
  # 从持久前缀恢复（与“新写回进程按持久前缀收口”同一保证，评审 R5 / X5）。
  def start_link(world, log), do: GenServer.start_link(__MODULE__, {world, log})

  @impl true
  def init({world, log}) do
    {:ok, %{world: world, log: log}}
  end

  @impl true
  def handle_cast(request, state), do: run(request, state)

  defp run({:begin, attempt, cut_seq}, %{log: {backend, handle}} = state) do
    prefix = backend.prefix(handle)

    if prefix != nil and prefix >= cut_seq do
      send(state.world, {:page_published, attempt, cut_seq})
    else
      :ok = backend.clear_unpublished(handle, prefix)
      send(state.world, {:page_begun, attempt})
    end

    {:noreply, state}
  end

  defp run({:batch, attempt, cut_seq, units}, %{log: {backend, handle}} = state) do
    started = System.monotonic_time(:microsecond)
    rows = rows(units)
    payload_bytes = Enum.reduce(rows, 0, fn row, bytes -> bytes + if(Map.has_key?(row, :payload), do: byte_size(row.payload), else: 0) end)
    :ok = backend.write_pages(handle, cut_seq, rows)
    Logger.info("voxel_page_write seq=#{cut_seq} units=#{length(units)} rows=#{length(rows)} encoded_payload_bytes=#{payload_bytes} elapsed_us=#{System.monotonic_time(:microsecond) - started}")
    send(state.world, {:page_ack, attempt})
    {:noreply, state}
  end

  defp run({:publish, attempt, cut_seq, units, globals}, %{log: {backend, handle}} = state) do
    started = System.monotonic_time(:microsecond)

    case backend.publish(handle, cut_seq, rows(units), globals) do
      :ok ->
        send(state.world, {:page_published, attempt, cut_seq})
        collected = collect(backend, handle, cut_seq, 0)
        Logger.info("voxel_page_publish seq=#{cut_seq} collected=#{collected} us=#{System.monotonic_time(:microsecond) - started}")

      # 发布事务读到的前缀已等于本切点：此前一次发布已提交、只是确认丢失（§6.1 第 3 步）。
      {:error, {:prefix, ^cut_seq}} ->
        send(state.world, {:page_published, attempt, cut_seq})

      {:error, reason} ->
        send(state.world, {:page_failed, attempt, reason})
    end

    {:noreply, state}
  end

  # 已删除身份的定位单元没有行（`Pages.row/2` 返回 nil）。
  defp rows(units), do: for({unit, value} <- units, row = Pages.row(unit, value), row != nil, do: row)

  defp collect(backend, handle, prefix, total) do
    case backend.collect(handle, prefix, @collect_batch) do
      0 -> total
      n -> collect(backend, handle, prefix, total + n)
    end
  end
end
