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

  defmodule FailingChunk do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_), do: {:ok, nil}

    @impl true
    def handle_call({:apply_field_effects, _effects, _context}, _from, state) do
      {:reply, {:error, :chunk_unavailable}, state}
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

  # 功能完善 · 反应层 R2:材料转变同经本桥(bucket = to_material_id)。
  defp transform_effect(macro_index, from_id, to_id) do
    {:transform_material,
     %{macro_index: macro_index, from_material_id: from_id, to_material_id: to_id, rule_id: :demo}}
  end

  test "材料转变首次提交;同目标材料 latch(防同 tick 重复转)" do
    sa = start_sa()
    chunk = start_chunk()

    assert {:ok, %{committed_count: 1, latched_count: 0}} =
             SystemActor.submit_field_effects(sa, chunk, [transform_effect(0, 4, 8)], ctx(1))

    assert_receive {:committed, [{:transform_material, _}]}

    # 同 {cell,macro,目标材料=8} → latched 幂等跳过。
    assert {:ok, %{committed_count: 0, latched_count: 1}} =
             SystemActor.submit_field_effects(sa, chunk, [transform_effect(0, 4, 8)], ctx(2))

    refute_receive {:committed, _}, 100
  end

  test "材料转变目标变(水→蒸汽)→ 新桶再提交" do
    sa = start_sa()
    chunk = start_chunk()

    SystemActor.submit_field_effects(sa, chunk, [transform_effect(0, 4, 8)], ctx(1))
    assert_receive {:committed, _}

    # 目标材料 8 → 9(不同 bucket)→ 再提交。
    assert {:ok, %{committed_count: 1}} =
             SystemActor.submit_field_effects(sa, chunk, [transform_effect(0, 8, 9)], ctx(2))

    assert_receive {:committed, [{:transform_material, _}]}
  end

  test "材料转变与温度写在同 cell 独立 latch(:material vs :temperature 维)" do
    sa = start_sa()
    chunk = start_chunk()

    SystemActor.submit_field_effects(sa, chunk, [temp_effect(0, 100.0)], ctx(1))
    assert_receive {:committed, _}

    # 同 macro_index 但 attribute 维不同(:material)→ 独立 latch → 提交。
    assert {:ok, %{committed_count: 1}} =
             SystemActor.submit_field_effects(sa, chunk, [transform_effect(0, 4, 8)], ctx(2))

    assert_receive {:committed, [{:transform_material, _}]}
  end

  # 功能完善 · 反应层 R5b:连续注入效果(燃烧)绕去抖锁存,每 tick 都提交。
  defp heat_effect(macro_index, joules) do
    {:write_voxel_attribute,
     %{attribute: :temperature, macro_index: macro_index, heat_energy_joules: joules}}
  end

  defp burn_progress_effect(macro_index, delta) do
    {:write_voxel_attribute,
     %{attribute: "burn_progress", macro_index: macro_index, delta: delta}}
  end

  defp set_tag_effect(macro_index, add, remove) do
    {:set_tag, %{macro_index: macro_index, add: add, remove: remove}}
  end

  test "heat_energy_joules 连续注热绕锁存:重复提交都 commit(火自维持)" do
    sa = start_sa()
    chunk = start_chunk()

    assert {:ok, %{committed_count: 1, latched_count: 0}} =
             SystemActor.submit_field_effects(sa, chunk, [heat_effect(0, 30_000_000.0)], ctx(1))

    assert_receive {:committed, _}

    # 同 cell 同效果再来 → 仍 commit(不被去抖锁存,否则火熄)。
    assert {:ok, %{committed_count: 1, latched_count: 0}} =
             SystemActor.submit_field_effects(sa, chunk, [heat_effect(0, 30_000_000.0)], ctx(2))

    assert_receive {:committed, _}
  end

  test "burn_progress delta 累进绕锁存:重复提交都 commit" do
    sa = start_sa()
    chunk = start_chunk()

    SystemActor.submit_field_effects(sa, chunk, [burn_progress_effect(0, 0.025)], ctx(1))
    assert_receive {:committed, _}

    assert {:ok, %{committed_count: 1}} =
             SystemActor.submit_field_effects(sa, chunk, [burn_progress_effect(0, 0.025)], ctx(2))

    assert_receive {:committed, _}
  end

  test "set_tag 始终 commit(storage 幂等 + 规则前置门控)" do
    sa = start_sa()
    chunk = start_chunk()

    assert {:ok, %{committed_count: 1}} =
             SystemActor.submit_field_effects(
               sa,
               chunk,
               [set_tag_effect(0, [:burning], [])],
               ctx(1)
             )

    assert_receive {:committed, [{:set_tag, _}]}
  end

  test "commit 失败不前进 latch(下个 tick 重试)且把错误透传(数据丢失回归)" do
    sa = start_sa()

    {:ok, failing} =
      start_supervised({FailingChunk, nil}, id: {:fail_chunk, System.unique_integer([:positive])})

    # 权威写失败 → submit 透传 {:error,_}(FieldTickWorker 据此记 dispatch_failed)。
    assert {:error, :chunk_unavailable} =
             SystemActor.submit_field_effects(sa, failing, [temp_effect(0, 100.0)], ctx(1))

    # latch 未前进——否则被丢弃的效果会被当「已提交」幂等跳过(静默数据丢失)。
    assert %{latch_count: 0} = SystemActor.snapshot(sa)

    # 换个能 commit 的 chunk 再提交同效果 → 真正提交(没被错误跳过)。
    chunk = start_chunk()

    assert {:ok, %{committed_count: 1, latched_count: 0}} =
             SystemActor.submit_field_effects(sa, chunk, [temp_effect(0, 100.0)], ctx(2))

    assert_receive {:committed, _}
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
