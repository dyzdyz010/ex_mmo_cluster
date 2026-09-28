# 只测试（Test-only）：受控输入槽截止、替代与迟到语义，不覆盖真实网络。
defmodule SceneServer.Movement.InputDeadlineTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias SceneServer.Movement.InputSlots
  alias MmoContracts.{Movement, Session}

  defp identity, do: %Session.Identity{session_epoch: 1, scene_id: 1, scene_epoch: 1}
  defp frame(seq, x \\ 32767, jump \\ 0),
    do: %Movement.InputFrame{input_seq: seq, axis_x: x, axis_z: 0, yaw: 123, jump_pressed: jump}
  defp batch(frames), do: %Movement.InputBatch{identity: identity(), frames: frames}

  test "三个缺帧保持连续轴，第四帧归零，朝向保持且不重复跳跃" do
    {s, :accepted} = InputSlots.receive_batch(InputSlots.new(identity(), 100), batch([frame(1, 32767, 1)]))
    {s, actual, :received} = InputSlots.take_observed(s, 100)
    assert actual.jump_pressed == 1
    {s, held} = Enum.reduce(101..103, {s, []}, fn tick, {slots, values} ->
      {next, f, :held} = InputSlots.take_observed(slots, tick)
      {next, values ++ [f]}
    end)
    assert Enum.map(held, &{&1.input_seq, &1.axis_x, &1.jump_pressed}) == [{2,32767,0},{3,32767,0},{4,32767,0}]
    {s, stopped, :neutral} = InputSlots.take_observed(s, 104)
    assert {stopped.input_seq, stopped.axis_x, stopped.yaw, stopped.jump_pressed} == {5,0,123,0}
    assert s.processed_input_seq == 5
    assert s.substituted_through_seq == 5
    assert {^s, :waiting, :waiting} = InputSlots.take_observed(s, 104)
  end

  test "400ms断流完成24个最终槽，迟到的换向及跳跃不改写过去" do
    s = Enum.reduce(100..123, InputSlots.new(identity(), 100), fn tick, slots ->
      {next, f, :neutral} = InputSlots.take_observed(slots, tick)
      assert f.jump_pressed == 0
      next
    end)
    assert s.processed_input_seq == 24
    {same, :late, decisions} = InputSlots.receive_batch_observed(s, batch([frame(12,-32767,1)]),123)
    assert same == s
    assert [{_, :late}] = decisions
    {s, :accepted, _} = InputSlots.receive_batch_observed(s,batch([frame(25,0,1)]),123)
    {s, f, :received} = InputSlots.take_observed(s,124)
    assert {f.input_seq,f.axis_x,f.jump_pressed} == {25,0,1}
    {_, f, :held} = InputSlots.take_observed(s,125)
    assert f.jump_pressed == 0
  end

  test "截止按接收时刻判断，即使物理仍在等碰撞也不能补交过去输入" do
    s=InputSlots.new(identity(),100)
    {s, :late, [{_,:late}]}=InputSlots.receive_batch_observed(s,batch([frame(1)]),100)
    assert s.pending == %{}
    {s, :accepted, _}=InputSlots.receive_batch_observed(s,batch([frame(3),frame(2)]),100)
    {s, _, :neutral}=InputSlots.take_observed(s,100)
    {s, second, :received}=InputSlots.take_observed(s,101)
    {_, third, :received}=InputSlots.take_observed(s,102)
    assert {second.input_seq,third.input_seq} == {2,3}
  end

  test "六帧冗余补回丢包，逆序重投不重复跳跃或改写最终槽" do
    # 首包 1 丢失；后包携带原始记录。独立期望：第 2 槽跳一次，第 4 槽松开。
    frames = for seq <- 1..6, do: frame(seq, if(seq < 4, do: 32767, else: 0), if(seq == 2, do: 1, else: 0))
    s = InputSlots.new(identity(), 100)
    {s, :accepted} = InputSlots.receive_batch(s, batch(frames), 99)
    {s, :accepted} = InputSlots.receive_batch(s, batch(Enum.take(frames, 3)), 99)
    {s, applied} = Enum.reduce(100..105, {s, []}, fn tick, {slots, values} ->
      {next, f, :received} = InputSlots.take_observed(slots, tick)
      {next, values ++ [{f.input_seq, f.axis_x, f.jump_pressed}]}
    end)
    assert applied == [{1,32767,0},{2,32767,1},{3,32767,0},{4,0,0},{5,0,0},{6,0,0}]
    assert {^s, :late} = InputSlots.receive_batch(s, batch(Enum.reverse(frames)), 105)
    assert {^s, :waiting, :waiting} = InputSlots.take_observed(s, 105)
    {_, next, :held} = InputSlots.take_observed(s, 106)
    assert {next.axis_x, next.jump_pressed} == {0,0}
  end
end
