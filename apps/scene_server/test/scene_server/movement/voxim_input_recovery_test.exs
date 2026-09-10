defmodule SceneServer.Movement.VoximInputRecoveryTest do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.InputSlots
  alias MmoContracts.Movement.{InputBatch, InputFrame}

  test "400ms delivery pause preserves direction changes release and one jump" do
    identity = %MmoContracts.Session.Identity{session_epoch: 1, scene_id: 1, scene_epoch: 1}
    frames = for seq <- 1..24 do
      %InputFrame{input_seq: seq, axis_x: cond do seq < 9 -> 32767; seq < 17 -> -32767; true -> 0 end,
        axis_z: 0, yaw: 0, jump_pressed: if(seq == 12, do: 1, else: 0)}
    end
    slots = Enum.reduce(100..123, InputSlots.new(identity, 100), fn tick, s ->
      {next, _} = InputSlots.take(s, tick)
      next
    end)
    # 真实模块的原始结果保留，断言揭示服务端是否代领了输入号。
    IO.puts("M1_DELAY_REPRO " <> inspect(%{pause_ms: 400, processed_without_arrival: slots.processed_input_seq}))
    assert slots.processed_input_seq == 0
    slots = Enum.reduce(Enum.reverse(Enum.chunk_every(frames, 6)), slots, fn batch, s ->
      {next, :accepted} = InputSlots.receive_batch(s, %InputBatch{identity: identity, frames: batch})
      next
    end)
    {slots, recovered} = Enum.reduce(1..24, {slots, []}, fn _, {s, taken} ->
      {next, frame} = InputSlots.take(s, 123)
      {next, taken ++ [frame]}
    end)
    assert recovered == frames
    assert slots.processed_input_seq == 24
    assert {^slots, :waiting} = InputSlots.take(slots, 123)
    {same, _} = InputSlots.receive_batch(slots, %InputBatch{identity: identity, frames: Enum.take(frames, 6)})
    assert same == slots
  end
end
