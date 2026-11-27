defmodule DataService.UidGeneratorTest do
  @moduledoc """
  只测试：`DataService.UidGenerator` 雪花 id 的纯计算核心（`new/1`、`next/2`）与 GenServer 接线（`generate/1`）。

  - 纯计算用例直接给定 `now_ms`：同一毫秒、序号用尽、新毫秒、回拨、越界都是确定输入，不读时钟、不 sleep。
  - 期望值按位布局手算：id = 距纪元毫秒数 × 2^22 + service × 2^12 + 序号，纪元 2021-01-01T00:00:00Z；
    不调用、不复制产品的打包代码。
  - GenServer 用例各起一个不注册名字的进程；不启动数据库与 DataService 应用。
  """
  use ExUnit.Case, async: true
  @moduletag :t0

  import ExUnit.CaptureLog

  alias DataService.UidGenerator

  # 纪元 2021-01-01T00:00:00Z 的 Unix 毫秒数。
  @epoch_ms 1_609_459_200_000
  # 41 位时间段能表示的最大毫秒数 2^41 - 1。
  @max_elapsed_ms 2_199_023_255_551

  # 在同一个 now_ms 上连续签发 count 个 id，返回 id 列表与最后的状态。
  defp issue_many(state, now_ms, count) do
    Enum.map_reduce(1..count, state, fn _, acc ->
      {:ok, id, next_state} = UidGenerator.next(acc, now_ms)
      {id, next_state}
    end)
  end

  describe "next/2 纯计算" do
    test "同一毫秒内序号逐个 +1" do
      # 距纪元 1 ms、service 1：1 × 4_194_304 + 1 × 4096 = 4_198_400，序号从 0 起。
      {ids, _state} = issue_many(UidGenerator.new(1), @epoch_ms + 1, 3)
      assert ids == [4_198_400, 4_198_401, 4_198_402]
    end

    test "进入新毫秒序号归 0" do
      {_ids, state} = issue_many(UidGenerator.new(1), @epoch_ms + 1, 3)

      # 距纪元 2 ms：2 × 4_194_304 + 4096 = 8_392_704。
      assert {:ok, 8_392_704, state} = UidGenerator.next(state, @epoch_ms + 2)
      assert {:ok, 8_392_705, _state} = UidGenerator.next(state, @epoch_ms + 2)
    end

    test "同一毫秒 4096 个序号用尽后要求等下一毫秒，下一毫秒从 0 续发" do
      {ids, state} = issue_many(UidGenerator.new(1), @epoch_ms + 1, 4096)
      assert ids == Enum.to_list(4_198_400..(4_198_400 + 4095))

      assert :sequence_exhausted = UidGenerator.next(state, @epoch_ms + 1)
      assert {:ok, 8_392_704, _state} = UidGenerator.next(state, @epoch_ms + 2)
    end

    test "时钟回拨显式拒绝且不改状态，时钟追回后接着签发" do
      {:ok, _id, state} = UidGenerator.next(UidGenerator.new(1), @epoch_ms + 10)

      assert UidGenerator.next(state, @epoch_ms + 9) ==
               {:error,
                {:clock_moved_backwards, %{last_ms: @epoch_ms + 10, now_ms: @epoch_ms + 9}}}

      # 状态没被回拨改动：回到上次的毫秒继续同毫秒递增，10 × 4_194_304 + 4096 + 1 = 41_947_137。
      assert {:ok, 41_947_137, _state} = UidGenerator.next(state, @epoch_ms + 10)
    end

    test "位布局：符号位 0 | 41 位毫秒 | 10 位 service | 12 位序号" do
      # 距纪元 3 ms、service 5 的第 8 个 id：3 × 4_194_304 + 5 × 4096 + 7 = 12_603_399。
      {ids, _state} = issue_many(UidGenerator.new(5), @epoch_ms + 3, 8)
      assert List.last(ids) == 12_603_399
      assert <<0::1, 3::41, 5::10, 7::12>> = <<12_603_399::64>>

      # 时间段与 service 取满：(2^41 - 1) × 2^22 + 1023 × 2^12，仍在 PostgreSQL bigint（2^63 - 1）之内。
      {:ok, max_id, _state} =
        UidGenerator.next(UidGenerator.new(1023), @epoch_ms + @max_elapsed_ms)

      assert max_id == 9_223_372_036_854_771_712
      assert <<0::1, @max_elapsed_ms::41, 1023::10, 0::12>> = <<max_id::64>>
    end

    test "纪元固定为 2021-01-01T00:00:00Z，41 位用到 2090-09-07T15:47:35.551Z；范围外显式拒绝，不回绕" do
      assert DateTime.to_unix(~U[2021-01-01 00:00:00Z], :millisecond) == @epoch_ms

      assert DateTime.to_unix(~U[2090-09-07 15:47:35.551Z], :millisecond) ==
               @epoch_ms + @max_elapsed_ms

      # 纪元当毫秒距纪元 0：id 只剩 service 位 1 × 4096。
      assert {:ok, 4096, _state} = UidGenerator.next(UidGenerator.new(1), @epoch_ms)

      assert UidGenerator.next(UidGenerator.new(1), @epoch_ms - 1) ==
               {:error, {:timestamp_out_of_range, %{now_ms: @epoch_ms - 1}}}

      assert UidGenerator.next(UidGenerator.new(1), @epoch_ms + @max_elapsed_ms + 1) ==
               {:error, {:timestamp_out_of_range, %{now_ms: @epoch_ms + @max_elapsed_ms + 1}}}
    end

    test "本版发布后签发的 id 大于旧实现可能签发过的任何 id" do
      # 旧实现（2022-06-08 引入）在同样的 41 位时间段里放“进程启动后的毫秒数”。旧进程不早于 2022-06-08 启动，
      # 到 2026-11-26 为止运行时长不超过两者之差；service、序号取满得旧 id 上界。
      release_ms = DateTime.to_unix(~U[2026-11-26 00:00:00Z], :millisecond)
      old_uptime_max = release_ms - DateTime.to_unix(~U[2022-06-08 00:00:00Z], :millisecond)
      <<old_id_max::64>> = <<0::1, old_uptime_max::41, 1023::10, 4095::12>>

      {:ok, new_id_min, _state} = UidGenerator.next(UidGenerator.new(0), release_ms)
      assert new_id_min > old_id_max
    end
  end

  describe "generate/1 GenServer 接线" do
    test "连续 20_000 次严格递增，时间段对得上墙钟，service 取应用配置" do
      pid = start_supervised!(UidGenerator)
      before_ms = System.system_time(:millisecond)

      ids =
        for _ <- 1..20_000 do
          assert {:ok, id} = UidGenerator.generate(pid)
          id
        end

      after_ms = System.system_time(:millisecond)

      assert [] == for([a, b] <- Enum.chunk_every(ids, 2, 1, :discard), a >= b, do: {a, b})

      <<0::1, first_elapsed::41, service_id::10, _::12>> = <<hd(ids)::64>>
      <<0::1, last_elapsed::41, _::22>> = <<List.last(ids)::64>>
      assert service_id == Application.get_env(:data_service, :service_id, 1)
      assert first_elapsed >= before_ms - @epoch_ms
      assert last_elapsed <= after_ms - @epoch_ms
    end

    test "时钟回拨：返回显式错误并记结构化日志，状态不变、持续拒绝" do
      pid = start_supervised!(UidGenerator)

      # 故障注入（只测试）：经公共纯函数造出“在 60 s 后的时刻签发过 id”的状态换入进程，
      # 等价于签发后系统时钟回拨 60 s。
      ahead_ms = System.system_time(:millisecond) + 60_000
      {:ok, _id, ahead_state} = UidGenerator.next(UidGenerator.new(1), ahead_ms)
      :sys.replace_state(pid, fn _state -> ahead_state end)

      log =
        capture_log(fn ->
          assert {:error, {:clock_moved_backwards, %{last_ms: ^ahead_ms, now_ms: now_ms}}} =
                   UidGenerator.generate(pid)

          assert now_ms < ahead_ms

          assert {:error, {:clock_moved_backwards, %{last_ms: ^ahead_ms}}} =
                   UidGenerator.generate(pid)
        end)

      assert log =~ "data_service_uid_generate_failed"
      assert log =~ "clock_moved_backwards"
      assert :sys.get_state(pid) == ahead_state
    end
  end
end
