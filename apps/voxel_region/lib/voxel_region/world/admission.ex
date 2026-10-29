defmodule VoxelRegion.World.Admission do
  @moduledoc "World物理输入的不可变接纳上下文与ready队列；只保存输入/顺序，不保存第二份物理时间或世界真值。"

  @doc "首次World到达构造一次身份与本地观察时间；arrival不是物理推进上界。"
  def input(entry, now, request \\ nil),
    do:
      {:input,
       %{
         id: make_ref(),
         arrival_ms: now,
         request_ref: request,
         ready_round: 0,
         ready_cutoff_ms: nil,
         page_dependencies: []
       }, entry}

  @doc "本轮依赖ready时冻结有限切点；普通continuation不调用它。"
  def ready({:input, context, entry}, now),
    do:
      {:input,
       %{
         context
         | ready_round: context.ready_round + 1,
           ready_cutoff_ms: now
       }, entry}

  @doc "新准备轮次释放旧物理上界，身份与到达观察保持。"
  def preparing({:input, context, entry}), do: {:input, %{context | ready_cutoff_ms: nil}, entry}

  @doc "Player转交的异步请求：消息仍走info，等待身份复用现caller取消与准备生命周期。"
  def async_input(message, from, now, request) do
    {:input, context, entry} = input({:info, message}, now, request)
    {:input, Map.put(context, :waiter, from), entry}
  end

  @doc "原始输入消息。"
  def message({:input, _, entry}), do: message(entry)
  def message({:call, message, _}), do: message
  def message({:info, message}), do: message

  @doc "等待请求的唯一身份；受管异步请求由Player拥有，未另建monitor表。"
  def from({:input, %{waiter: from}, _}), do: from
  def from({:input, _, {:call, _, from}}), do: from
  def from({:input, _, {:info, _}}), do: nil

  @doc "只按各owner原due选择下一完整自然步，同due固定热先液体后；热run的剩余段先完成。"
  def next_step(%{thermal_run: run}, _cutoff) when run != nil, do: :thermal

  def next_step(state, cutoff) do
    [{state.thermal_due, 0, :thermal}, {state.liquid_due, 1, :liquid}]
    |> Enum.filter(fn {due, _, _} -> due != nil and due <= cutoff end)
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> nil
      {_, _, owner} -> owner
    end
  end

  @doc "ready队列只读观察；不把cutoff误称已成立的历史世界时间。"
  def observe(queue) do
    %{
      ready_count: :queue.len(queue),
      inputs:
        for(
          {:input, context, entry} <- :queue.to_list(queue),
          do:
            Map.merge(context, %{
              id: inspect(context.id),
              request_ref: inspect(context.request_ref),
              kind: entry |> message() |> kind()
            })
        )
    }
  end

  @doc "消息的稳定日志标签。"
  def kind(message) when is_tuple(message), do: elem(message, 0)
  def kind(message), do: message
end
