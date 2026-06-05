defmodule DataService.UidGeneratorTest do
  @moduledoc """
  锁定 persist-4(UidGenerator 时序逻辑反转)回归。

  原实现 `get_sequence/3` 比较方向反转:同一毫秒内序列号恒为 0(主键碰撞),
  跨毫秒则无界累加后被 12 位字段静默截断(再次碰撞)。本测试既直接验证提纯后的
  `decide/4` 决策表,也通过黑盒 `generate/0` 验证"同毫秒唯一 + 全局严格递增"不变量。
  """
  use ExUnit.Case, async: false

  alias DataService.UidGenerator

  @max_sequence 4095

  # 把 8 字节 ID 解析回字段
  defp parse(<<0::1, ts::41, sid::10, seq::12>>), do: %{timestamp: ts, service_id: sid, sequence: seq}
  defp to_int(<<n::64>>), do: n

  describe "decide/4 纯决策表(复现并锁定 sequence 方向反转 bug)" do
    test "新毫秒:序列重置为 0" do
      assert UidGenerator.decide(100, 99, 7, @max_sequence) == {:ok, 100, 0}
    end

    test "同一毫秒:序列递增(原 bug 此处恒为 0)" do
      assert UidGenerator.decide(100, 100, 0, @max_sequence) == {:ok, 100, 1}
      assert UidGenerator.decide(100, 100, 41, @max_sequence) == {:ok, 100, 42}
    end

    test "同一毫秒序列耗尽:要求自旋到下一毫秒" do
      assert UidGenerator.decide(100, 100, @max_sequence, @max_sequence) == {:wait_next, 100}
    end

    test "首次生成(last_timestamp = -1):视为新毫秒" do
      assert UidGenerator.decide(0, -1, 0, @max_sequence) == {:ok, 0, 0}
    end

    test "时钟回拨:now < last 返回 :clock_backwards" do
      assert UidGenerator.decide(98, 100, 3, @max_sequence) == {:clock_backwards, 100}
    end
  end

  describe "generate (handle_call) 黑盒不变量" do
    # 用匿名进程 + pid 直调,刻意不注册全局名 __MODULE__:既存 worker_test.exs 的
    # setup_all 已常驻注册了 DataService.UidGenerator,共用同名会在全量 mix test 下偶发
    # {:already_started}。generate/0 只是 `GenServer.call(__MODULE__, :generate)` 的薄包装,
    # 核心逻辑在 handle_call,pid 直调等价覆盖且零全局名冲突。
    setup do
      %{uid: start_supervised!({UidGenerator, []})}
    end

    test "大量快速生成的 ID 全部唯一(跨多毫秒并触发序列回绕)", %{uid: uid} do
      ids = for _ <- 1..20_000, do: GenServer.call(uid, :generate)
      assert length(Enum.uniq(ids)) == 20_000
    end

    test "ID 转为整数后严格单调递增", %{uid: uid} do
      ints = for _ <- 1..10_000, do: to_int(GenServer.call(uid, :generate))
      assert ints == Enum.sort(ints)
      assert length(Enum.uniq(ints)) == length(ints)
    end

    test "同一毫秒内 sequence 互不重复(锁定同毫秒碰撞回归)", %{uid: uid} do
      parsed = for _ <- 1..20_000, do: parse(GenServer.call(uid, :generate))

      parsed
      |> Enum.group_by(& &1.timestamp, & &1.sequence)
      |> Enum.each(fn {_ts, seqs} ->
        assert length(seqs) == length(Enum.uniq(seqs)),
               "同一 timestamp 内出现重复 sequence,主键碰撞回归"
      end)
    end

    test "service_id 正确编码进 ID 高位段", %{uid: uid} do
      expected = Application.get_env(:data_service, :service_id, 1)
      assert parse(GenServer.call(uid, :generate)).service_id == expected
    end
  end

  describe "init 配置校验" do
    test "service_id 超出 10 位范围时 init 失败(避免静默截断导致跨节点碰撞)" do
      original = Application.get_env(:data_service, :service_id)
      on_exit(fn -> restore_env(:service_id, original) end)

      Application.put_env(:data_service, :service_id, 99_999)
      Process.flag(:trap_exit, true)

      assert {:error, _reason} = GenServer.start(UidGenerator, [])
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:data_service, key)
  defp restore_env(key, value), do: Application.put_env(:data_service, key, value)
end
