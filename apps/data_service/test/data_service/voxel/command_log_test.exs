defmodule DataService.Voxel.CommandLogTest do
  # 共享 voxel_command_log 表,async:false + 每测试清表。
  use ExUnit.Case, async: false

  alias DataService.Voxel.CommandLog

  setup do
    CommandLog.reset()
    :ok
  end

  test "record_once 首次 :fresh,重复 :duplicate(AUTH-4)" do
    assert :fresh = CommandLog.record_once("cmd-1", 1)
    assert :duplicate = CommandLog.record_once("cmd-1", 1)
    assert :duplicate = CommandLog.record_once("cmd-1", 1)
  end

  test "不同 command_id 互不影响" do
    assert :fresh = CommandLog.record_once("cmd-a", 1)
    assert :fresh = CommandLog.record_once("cmd-b", 1)
    assert :duplicate = CommandLog.record_once("cmd-a", 1)
  end

  test "seen?/1 反映登记状态" do
    refute CommandLog.seen?("cmd-x")
    CommandLog.record_once("cmd-x", 1)
    assert CommandLog.seen?("cmd-x")
  end

  test "并发重复 command_id 只有一个 :fresh(线性化)" do
    tasks =
      for _ <- 1..16 do
        Task.async(fn -> CommandLog.record_once("cmd-race", 1) end)
      end

    results = Enum.map(tasks, &Task.await/1)

    assert Enum.count(results, &(&1 == :fresh)) == 1
    assert Enum.count(results, &(&1 == :duplicate)) == 15
  end
end
