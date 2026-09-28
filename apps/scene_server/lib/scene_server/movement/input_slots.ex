defmodule SceneServer.Movement.InputSlots do
  @moduledoc "固定步最终输入槽；真实输入与短时保持／归零分别记账，已最终处理的槽不改写。"
  alias MmoContracts.Movement.{InputBatch, InputFrame}
  @hold_ticks 3
  @enforce_keys [:identity, :origin_tick]
  defstruct @enforce_keys ++
              [
                pending: %{},
                processed_input_seq: 0,
                substituted_through_seq: 0,
                missing: 0,
                axis_x: 0,
                axis_z: 0,
                yaw: 0
              ]

  @doc "InputStart 冻结 origin，之后不得重新映射序号。"
  def new(identity, origin_tick), do: %__MODULE__{identity: identity, origin_tick: origin_tick}

  @doc "消费 C1 已解码的帧；在唯一序号/epoch 信任边界接纳整批。"
  def receive_batch(slots, batch, closed_tick \\ -1) do
    {next, result, _decisions} = receive_batch_observed(slots, batch, closed_tick)
    {next, result}
  end

  @doc "从原接纳分支返回逐帧处置，不在日志调用方重新分类。"
  def receive_batch_observed(slots, batch, closed_tick \\ -1)
  def receive_batch_observed(%{identity: identity} = slots, %InputBatch{
        identity: other,
        frames: frames
      }, _closed_tick)
      when identity != other,
      do: {slots, :old_identity, decisions(frames, :old_identity)}

  def receive_batch_observed(slots, %InputBatch{frames: frames}, closed_tick) do
    {late, live} = Enum.split_with(frames, fn frame ->
      frame.input_seq <= slots.processed_input_seq or slots.origin_tick + frame.input_seq - 1 <= closed_tick
    end)

    {next, result} =
      cond do
        live == [] ->
          {slots, :late}

        Enum.any?(live, fn frame ->
          case Map.fetch(slots.pending, frame.input_seq) do
            {:ok, previous} -> previous != frame
            :error -> false
          end
        end) ->
          {slots, :conflict}

        true ->
          pending = Enum.reduce(live, slots.pending, &Map.put_new(&2, &1.input_seq, &1))
          {%{slots | pending: pending}, :accepted}
      end

    {next, result, decisions(late, :late) ++ decisions(live, result)}
  end

  defp decisions(frames, result), do: Enum.map(frames, &{&1, result})

  @doc "只最终处理已获得服务器时间的下一槽；重复调用不能创造额外物理时间。"
  def take(slots, tick) do
    {next, frame, _selection} = take_observed(slots, tick)
    {next, frame}
  end

  @doc "处置原因与实际轴选择同源；不改变原连续前缀。"
  def take_observed(slots, tick) do
    seq = slots.processed_input_seq + 1

    cond do
      tick < slots.origin_tick + seq - 1 ->
        {slots, :waiting, :waiting}

      true ->
        case Map.pop(slots.pending, seq) do
          {nil, _pending} ->
            missing = slots.missing + 1
            hold = missing <= @hold_ticks and slots.processed_input_seq > slots.missing
            frame = %InputFrame{input_seq: seq, axis_x: if(hold, do: slots.axis_x, else: 0),
              axis_z: if(hold, do: slots.axis_z, else: 0), yaw: slots.yaw, jump_pressed: 0}
            selection = if hold, do: :held, else: :neutral
            {%{slots | processed_input_seq: seq, substituted_through_seq: seq, missing: missing}, frame, selection}

          {frame, pending} ->
            {%{
               slots
               | pending: pending,
                 processed_input_seq: seq,
                 missing: 0,
                 axis_x: frame.axis_x,
                 axis_z: frame.axis_z,
                 yaw: frame.yaw
             }, frame, :received}
        end
    end
  end
end
