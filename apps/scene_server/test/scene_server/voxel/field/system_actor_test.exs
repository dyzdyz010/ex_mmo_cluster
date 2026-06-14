defmodule SceneServer.Voxel.Field.SystemActorTest do
  # 梯队3 step3.8:派生→权威 system_actor 桥(candidate_effect 阈值锁存 + 幂等,RULE-11/15/16)。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.SystemActor

  defmodule FakeChunk do
    @moduledoc false
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_call({:apply_field_effects, effects, _context}, _from, parent) do
      send(parent, {:committed, effects})
      {:reply, {:ok, %{applied_count: length(effects)}}, parent}
    end
  end

  defp start_sa(bucket_size \\ 5.0) do
    name = :"sa_#{System.unique_integer([:positive])}"
    {:ok, _} = start_supervised({SystemActor, [name: name, bucket_size: bucket_size]})
    name
  end

  defp start_chunk do
    {:ok, pid} =
      start_supervised({FakeChunk, self()}, id: {:chunk, System.unique_integer([:positive])})

    pid
  end

  defp temp_effect(macro_index, temp) do
    {:write_voxel_attribute,
     %{attribute: :temperature, macro_index: macro_index, target_temperature_celsius: temp}}
  end

  defp ctx(tick), do: %{region_id: 1, chunk_coord: {0, 0, 0}, kernel_id: :temp, source_tick: tick}

  test "首次候选提交;同量化分桶 latch(幂等去抖,不重复写权威)" do
    sa = start_sa()
    chunk = start_chunk()

    assert {:ok, %{committed_count: 1, latched_count: 0}} =
             SystemActor.submit_field_effects(sa, chunk, [temp_effect(0, 100.0)], ctx(1))

    assert_receive {:committed, [_]}

    # 101/5 → round 20 = 与 100/5 同桶 → latch,不提交。
    assert {:ok, %{committed_count: 0, latched_count: 1}} =
             SystemActor.submit_field_effects(sa, chunk, [temp_effect(0, 101.0)], ctx(2))

    refute_receive {:committed, _}, 100
  end

  test "跨量化分桶阈再提交" do
    sa = start_sa()
    chunk = start_chunk()

    SystemActor.submit_field_effects(sa, chunk, [temp_effect(0, 100.0)], ctx(1))
    assert_receive {:committed, _}

    # 120/5 = 24 ≠ 20 → 跨桶 → 再提交。
    assert {:ok, %{committed_count: 1}} =
             SystemActor.submit_field_effects(sa, chunk, [temp_effect(0, 120.0)], ctx(2))

    assert_receive {:committed, _}
  end

  test "不同 cell / kernel 独立 latch" do
    sa = start_sa()
    chunk = start_chunk()

    SystemActor.submit_field_effects(sa, chunk, [temp_effect(0, 100.0)], ctx(1))
    assert_receive {:committed, _}

    # 不同 macro_index → 不同 latch_key → 提交。
    assert {:ok, %{committed_count: 1}} =
             SystemActor.submit_field_effects(sa, chunk, [temp_effect(1, 100.0)], ctx(2))

    assert_receive {:committed, _}
  end

  test "unsupported effect 透传(交 ChunkProcess 显式拒绝,不静默吞)" do
    sa = start_sa()
    chunk = start_chunk()

    assert {:ok, %{committed_count: 1}} =
             SystemActor.submit_field_effects(sa, chunk, [{:unsupported_action, %{}}], ctx(1))

    assert_receive {:committed, [{:unsupported_action, _}]}
  end

  test "candidate_effect_id 稳定:同 cell+rule+bucket 重复 latch 同 id" do
    sa = start_sa()
    chunk = start_chunk()

    {:ok, %{results: [{:committed, id1}]}} =
      SystemActor.submit_field_effects(sa, chunk, [temp_effect(0, 100.0)], ctx(1))

    {:ok, %{results: [{:latched, id2}]}} =
      SystemActor.submit_field_effects(sa, chunk, [temp_effect(0, 102.0)], ctx(9))

    # 同 latch_key + 同 bucket(100/5=20、102/5=round 20.4=20)→ 同稳定 id(不含 tick)。
    assert id1 == id2
  end

  test "snapshot / reset" do
    sa = start_sa()
    chunk = start_chunk()

    SystemActor.submit_field_effects(sa, chunk, [temp_effect(0, 100.0)], ctx(1))
    assert %{latch_count: 1} = SystemActor.snapshot(sa)

    assert :ok = SystemActor.reset(sa)
    assert %{latch_count: 0} = SystemActor.snapshot(sa)
  end
end
