defmodule MmoContracts.Movement.Codec do
  alias MmoContracts.Movement
  @frame [input_seq: :seq, axis_x: :axis, axis_z: :axis, yaw: :u16, jump_pressed: :bool]
  @record [
    entity_id: :u64,
    entity_epoch: :u64,
    interest_generation: :u64,
    collision_revision: :u64,
    state: :state
  ]
  @m1_messages %{
    1 =>
      {Movement.InputBatch,
       [identity: :identity, frames: {:array, :u8, {:struct, Movement.InputFrame, @frame}}]},
    2 =>
      {Movement.OwnerAck,
       [
         identity: :identity,
         server_tick: :u64,
         processed_input_seq: :u32,
         collision_revision: :u64,
         state: :state,
         substituted_through_seq: :u32,
         simulation_tick: :u64
       ]},
    3 =>
      {Movement.Snapshot,
       [
         identity: :identity,
         server_tick: :u64,
         records: {:array, :u16, {:struct, Movement.SnapshotRecord, @record}}
       ]}
  }

  @moduledoc "M1 输入、本人 ACK 和实体快照的纯合同；不拥有输入槽或时间推进器。"
  alias MmoContracts.Session.Wire

  @doc "M1 Movement 消息编码。"
  def encode(message), do: Wire.encode(2, @m1_messages, message)

  @doc "在网络边界一次解码/拒绝不合法帧。"
  def decode(bytes), do: Wire.decode(2, bytes, @m1_messages, &accept_m1/1)

  @doc "由同一量化整数还原单位圆输入；预测及服务端消费该结果。"
  def axes(%MmoContracts.Movement.InputFrame{axis_x: x, axis_z: z}) do
    x = x / 32767
    z = z / 32767
    length = max(1.0, :math.sqrt(x * x + z * z))
    {x / length, z / length}
  end

  defp accept_m1(%Movement.InputBatch{frames: frames}) do
    true = length(frames) in 1..6
    MmoContracts.Session.Wire.ordered!(Enum.map(frames, & &1.input_seq))
  end

  defp accept_m1(%Movement.Snapshot{records: records}),
    do: MmoContracts.Session.Wire.ordered!(Enum.map(records, & &1.entity_id))

  defp accept_m1(_), do: :ok
end
