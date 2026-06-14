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

  # 梯队1 step1.5b-2:idempotency-key claim/confirm/release(prefab,AUTH-4)。

  test "claim 首次 :fresh,confirm 后重复 claim 得缓存结果(AUTH-4)" do
    assert :fresh = CommandLog.claim("prefab:1:42:7", 1)
    assert :ok = CommandLog.confirm("prefab:1:42:7", "12|2|3")
    assert {:duplicate, "12|2|3"} = CommandLog.claim("prefab:1:42:7", 1)
    assert {:duplicate, "12|2|3"} = CommandLog.claim("prefab:1:42:7", 1)
  end

  test "claim :fresh 未收尾时重复 claim 得 :in_flight" do
    assert :fresh = CommandLog.claim("prefab:1:42:8", 1)
    assert :in_flight = CommandLog.claim("prefab:1:42:8", 1)
  end

  test "release 后后续 claim 仍 :fresh(失败放行合法重试,exactly-once)" do
    assert :fresh = CommandLog.claim("prefab:1:42:9", 1)
    assert :ok = CommandLog.release("prefab:1:42:9")
    refute CommandLog.seen?("prefab:1:42:9")
    # 释放后重试可再次认领并完成。
    assert :fresh = CommandLog.claim("prefab:1:42:9", 1)
    assert :ok = CommandLog.confirm("prefab:1:42:9", "1|1|5")
    assert {:duplicate, "1|1|5"} = CommandLog.claim("prefab:1:42:9", 1)
  end

  test "并发 claim 同 command_id 只一个 :fresh,其余 :in_flight(原子认领)" do
    tasks =
      for _ <- 1..16 do
        Task.async(fn -> CommandLog.claim("prefab:1:42:race", 1) end)
      end

    results = Enum.map(tasks, &Task.await/1)

    assert Enum.count(results, &(&1 == :fresh)) == 1
    assert Enum.count(results, &(&1 == :in_flight)) == 15
  end

  test "record_once 插入的行 status 为 committed(列默认)" do
    assert :fresh = CommandLog.record_once("edit:1:42:1", 1)

    # 单方块 committed 命令被 claim(理论上不同前缀不会撞,这里仅验证 status 默认值)得 duplicate。
    assert {:duplicate, _result} = CommandLog.claim("edit:1:42:1", 1)
  end
end
