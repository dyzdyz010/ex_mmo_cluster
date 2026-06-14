defmodule SceneServer.Voxel.Field.SimRuntimeTest do
  # 梯队2 step2.6:节点级场仿真调度器(统一 clock + CPU 预算)。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.SimRuntime

  defmodule FakeWorker do
    @moduledoc false
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_call(:run_tick, _from, parent) do
      send(parent, {:ticked, self()})
      {:reply, :ok, parent}
    end
  end

  defp start_sim(opts) do
    name = :"sim_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({SimRuntime, [{:name, name} | opts]})
    {pid, name}
  end

  defp start_worker do
    {:ok, pid} =
      start_supervised({FakeWorker, self()}, id: {:worker, System.unique_integer([:positive])})

    pid
  end

  defp eventually(fun, retries \\ 100)
  defp eventually(_fun, 0), do: flunk("condition not met in time")

  defp eventually(fun, retries) do
    if fun.() do
      :ok
    else
      :timer.sleep(5)
      eventually(fun, retries - 1)
    end
  end

  test "subscribe 后 prompt-drive 立即驱动一次,后续 clock 周期驱动" do
    {sim, name} = start_sim(tick_interval_ms: 30, max_concurrency: 2)
    worker = start_worker()

    assert :ok = SimRuntime.subscribe(name, worker)

    # prompt_tick:订阅后立即驱动一次。
    assert_receive {:ticked, ^worker}, 500
    # clock 周期继续驱动。
    assert_receive {:ticked, ^worker}, 500

    assert %{worker_count: 1, max_concurrency: 2, interval_ms: 30} = SimRuntime.snapshot(sim)
  end

  test "多 worker 同拍被驱动" do
    {_sim, name} = start_sim(tick_interval_ms: 30, max_concurrency: 4)
    w1 = start_worker()
    w2 = start_worker()

    SimRuntime.subscribe(name, w1)
    SimRuntime.subscribe(name, w2)

    assert_receive {:ticked, ^w1}, 500
    assert_receive {:ticked, ^w2}, 500
  end

  test "snapshot 反映订阅数与配置" do
    {sim, name} = start_sim(tick_interval_ms: 1_000, max_concurrency: 3)
    assert %{worker_count: 0, tick_count: _, max_concurrency: 3} = SimRuntime.snapshot(sim)

    worker = start_worker()
    SimRuntime.subscribe(name, worker)
    assert %{worker_count: 1} = SimRuntime.snapshot(sim)
  end

  test "unsubscribe 摘除 worker" do
    {sim, name} = start_sim(tick_interval_ms: 1_000)
    worker = start_worker()
    SimRuntime.subscribe(name, worker)
    assert %{worker_count: 1} = SimRuntime.snapshot(sim)

    assert :ok = SimRuntime.unsubscribe(name, worker)
    assert %{worker_count: 0} = SimRuntime.snapshot(sim)
  end

  test "worker 停机由 monitor DOWN 自动摘除" do
    {sim, name} = start_sim(tick_interval_ms: 1_000)
    worker = start_worker()
    SimRuntime.subscribe(name, worker)
    assert %{worker_count: 1} = SimRuntime.snapshot(sim)

    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 500

    eventually(fn -> match?(%{worker_count: 0}, SimRuntime.snapshot(sim)) end)
  end

  test "重复 subscribe 幂等(不重复登记)" do
    {sim, name} = start_sim(tick_interval_ms: 1_000)
    worker = start_worker()
    SimRuntime.subscribe(name, worker)
    SimRuntime.subscribe(name, worker)
    assert %{worker_count: 1} = SimRuntime.snapshot(sim)
  end
end
