defmodule SceneServer.Movement.InputSlots do
  @moduledoc "固定 origin 的连续输入槽；接收只排队，Scene 到期 tick 才消费。"
  alias MmoContracts.Movement.{InputBatch, InputFrame}
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
  def receive_batch(%{identity: identity} = slots, %InputBatch{identity: other})
      when identity != other,
      do: {slots, :old_identity}

  def receive_batch(slots, %InputBatch{frames: frames}) do
    live = Enum.reject(frames, &(&1.input_seq <= slots.processed_input_seq))

    cond do
      live == [] ->
        {slots, :late}

      Enum.any?(live, &(&1.input_seq > slots.processed_input_seq + 32)) ->
        {slots, :future}

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
  end

  @doc "只消费下一个到期槽；缺帧延续轴六槽，jump 永不继承。"
  def take(slots, tick) do
    seq = slots.processed_input_seq + 1

    cond do
      tick < slots.origin_tick + seq - 1 ->
        {slots, :waiting}

      seq > 0xFFFFFFFF ->
        {slots, :exhausted}

      true ->
        case Map.pop(slots.pending, seq) do
          {nil, pending} ->
            missing = slots.missing + 1

            frame = %InputFrame{
              input_seq: seq,
              axis_x: if(missing <= 6, do: slots.axis_x, else: 0),
              axis_z: if(missing <= 6, do: slots.axis_z, else: 0),
              yaw: slots.yaw,
              jump_pressed: 0
            }

            {%{
               slots
               | pending: pending,
                 processed_input_seq: seq,
                 substituted_through_seq: seq,
                 missing: missing
             }, frame}

          {frame, pending} ->
            {%{
               slots
               | pending: pending,
                 processed_input_seq: seq,
                 missing: 0,
                 axis_x: frame.axis_x,
                 axis_z: frame.axis_z,
                 yaw: frame.yaw
             }, frame}
        end
    end
  end
end
