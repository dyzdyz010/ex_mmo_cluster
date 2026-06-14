defmodule GateServer.Replication.EgressTest do
  # 梯队3 step3.10a:统一 Replicator per-observer 出口控制器纯核
  # (REPL-2/4/6、NET-3/4/5、LOAD-5)。
  use ExUnit.Case, async: true

  alias GateServer.Replication.Egress
  alias MmoContracts.Envelope.ReplicationOut

  defp big(n), do: :binary.copy(<<0>>, n)

  # per-observer 控制器必须有 observer 身份(ReplicationOut 强制 observer_id);测试默认注入。
  defp new(opts), do: Egress.new(Keyword.put_new(opts, :observer_id, 1))

  describe "reliability_class 分类(REPL-4)" do
    test "下行 kind 映射到四类" do
      assert Egress.reliability_class(:voxel_chunk_delta_payload) == :reliable_unordered
      assert Egress.reliability_class(:voxel_object_state_delta_payload) == :reliable_unordered

      assert Egress.reliability_class(:voxel_field_region_snapshot_payload) ==
               :unreliable_snapshot

      assert Egress.reliability_class(:voxel_chunk_snapshot_payload) == :bulk_stream
      assert Egress.reliability_class(:voxel_field_region_destroyed_payload) == :reliable_ordered
      assert Egress.reliability_class(:voxel_chunk_invalidate_payload) == :reliable_ordered
      assert Egress.reliability_class(:anything_else) == :reliable_ordered
    end

    test "enqueue_payload 实例化 ReplicationOut 信封并路由" do
      e = new(observer_id: 7)
      e = Egress.enqueue_payload(e, :voxel_chunk_delta_payload, {0, 0, 0}, big(10), delta_base: 3)
      assert Egress.pending_count(e) == 1
      assert [%ReplicationOut{} = env] = e.reliable
      assert env.observer_id == 7
      assert env.reliability_class == :reliable_unordered
      assert env.budget_class == :state
      assert env.delta_base == 3
      assert {:voxel_chunk_delta_payload, _bin} = env.payload
    end
  end

  describe "0 回归不变量:子预算下即时全发、顺序不变(D3.10-6)" do
    test "充足预算 flush 一次发完且顺序=入队序" do
      e = new(capacity_bytes: 1_000_000, now_ms: 0)

      e =
        e
        |> Egress.enqueue_payload(:voxel_chunk_delta_payload, {0, 0, 0}, <<1, 1>>, delta_base: 0)
        |> Egress.enqueue_payload(:voxel_chunk_delta_payload, {0, 0, 0}, <<2, 2>>, delta_base: 1)
        |> Egress.enqueue_payload(:voxel_chunk_delta_payload, {1, 0, 0}, <<3, 3>>, delta_base: 0)

      {out, e} = Egress.flush(e, 0)

      assert out == [
               {:voxel_chunk_delta_payload, <<1, 1>>},
               {:voxel_chunk_delta_payload, <<2, 2>>},
               {:voxel_chunk_delta_payload, <<3, 3>>}
             ]

      refute Egress.pending?(e)
      assert Egress.stats(e).sent == 3
      assert Egress.stats(e).bytes_sent == 6
    end

    test "控制类不受预算、最先发、保序;reliable 受预算留队" do
      # 容量 100:首 delta 占满到 40,次 delta(60)预算不足留队;控制类绕预算仍最先发。
      e = new(capacity_bytes: 100, now_ms: 0)

      e =
        e
        |> Egress.enqueue_payload(:voxel_chunk_delta_payload, {0, 0, 0}, big(60), delta_base: 0)
        |> Egress.enqueue_payload(:voxel_chunk_delta_payload, {0, 0, 0}, big(60), delta_base: 1)
        |> Egress.enqueue_payload(:voxel_chunk_invalidate_payload, {0, 0, 0}, <<9>>)
        |> Egress.enqueue_payload(:voxel_field_region_destroyed_payload, {0, 0, 0}, <<8>>)

      {out, e} = Egress.flush(e, 0)

      # 控制类先发(保序:invalidate 在 destroyed 前入队),不占预算;首 delta 发出,次 delta 留队。
      assert out == [
               {:voxel_chunk_invalidate_payload, <<9>>},
               {:voxel_field_region_destroyed_payload, <<8>>},
               {:voxel_chunk_delta_payload, big(60)}
             ]

      assert Egress.pending_count(e) == 1
    end
  end

  describe "per-observer 出口预算 token bucket(REPL-2 / LOAD-5)" do
    test "预算耗尽则憋帧,后续帧留队" do
      e = new(capacity_bytes: 100, window_ms: 100, now_ms: 0)

      e =
        e
        |> Egress.enqueue_payload(:voxel_chunk_delta_payload, {0, 0, 0}, big(60), delta_base: 0)
        |> Egress.enqueue_payload(:voxel_chunk_delta_payload, {0, 0, 0}, big(60), delta_base: 1)

      {out, e} = Egress.flush(e, 0)
      assert length(out) == 1
      assert Egress.pending_count(e) == 1
      assert Egress.stats(e).sent == 1
    end

    test "惰性补充:时间推进后预算回血放行剩余帧" do
      e = new(capacity_bytes: 100, window_ms: 100, now_ms: 0)

      e =
        e
        |> Egress.enqueue_payload(:voxel_chunk_delta_payload, {0, 0, 0}, big(60), delta_base: 0)
        |> Egress.enqueue_payload(:voxel_chunk_delta_payload, {0, 0, 0}, big(60), delta_base: 1)

      {out0, e} = Egress.flush(e, 0)
      assert length(out0) == 1

      # 100ms 后满桶补充(refill_per_ms = 100/100 = 1 byte/ms → 100ms 回血 100 字节)。
      {out1, e} = Egress.flush(e, 100)
      assert length(out1) == 1
      refute Egress.pending?(e)
    end

    test "单帧超整桶容量:满桶时仍放行一次(防大帧永久卡死)" do
      e = new(capacity_bytes: 50, now_ms: 0)
      e = Egress.enqueue_payload(e, :voxel_field_region_snapshot_payload, {0, 0, 0}, big(500))
      {out, e} = Egress.flush(e, 0)
      assert length(out) == 1
      refute Egress.pending?(e)
    end
  end

  describe "聚合 / 合并到最新(REPL-6)" do
    test "unreliable_snapshot 同 region 合并保最新" do
      # 预算极小,迫使憋帧;两帧同 key 应合并为一(最新)。
      e = new(capacity_bytes: 1, now_ms: 0)
      e = Egress.enqueue_payload(e, :voxel_field_region_snapshot_payload, 42, <<1>>)
      e = Egress.enqueue_payload(e, :voxel_field_region_snapshot_payload, 42, <<2>>)
      # 合并后只剩一帧待发。
      assert Egress.pending_count(e) == 1

      # 满预算后 flush 得到最新帧。
      e2 = new(capacity_bytes: 1_000_000, now_ms: 0)
      e2 = Egress.enqueue_payload(e2, :voxel_field_region_snapshot_payload, 42, <<1>>)
      e2 = Egress.enqueue_payload(e2, :voxel_field_region_snapshot_payload, 42, <<2>>)
      {out, _} = Egress.flush(e2, 0)
      assert out == [{:voxel_field_region_snapshot_payload, <<2>>}]
    end

    test "不同 key 不合并、保插入序" do
      e = new(capacity_bytes: 1_000_000, now_ms: 0)
      e = Egress.enqueue_payload(e, :voxel_field_region_snapshot_payload, 1, <<1>>)
      e = Egress.enqueue_payload(e, :voxel_field_region_snapshot_payload, 2, <<2>>)
      {out, _} = Egress.flush(e, 0)

      assert out == [
               {:voxel_field_region_snapshot_payload, <<1>>},
               {:voxel_field_region_snapshot_payload, <<2>>}
             ]
    end

    test "delta 链 reliable_unordered 不合并(保完整链)" do
      e = new(capacity_bytes: 1_000_000, now_ms: 0)
      e = Egress.enqueue_payload(e, :voxel_chunk_delta_payload, {0, 0, 0}, <<1>>, delta_base: 0)
      e = Egress.enqueue_payload(e, :voxel_chunk_delta_payload, {0, 0, 0}, <<2>>, delta_base: 1)
      assert Egress.pending_count(e) == 2
      {out, _} = Egress.flush(e, 0)
      assert length(out) == 2
    end
  end

  describe "大流隔离 + 背压(NET-3/4/5)" do
    test "bulk_stream 在 reliable/snapshot 之后用剩余预算发" do
      # 预算只够一帧;snapshot 应先于 bulk。
      e = new(capacity_bytes: 10, now_ms: 0)
      e = Egress.enqueue_payload(e, :voxel_chunk_snapshot_payload, {0, 0, 0}, big(10))
      e = Egress.enqueue_payload(e, :voxel_field_region_snapshot_payload, 1, big(10))
      {out, e} = Egress.flush(e, 0)
      assert out == [{:voxel_field_region_snapshot_payload, big(10)}]
      # bulk 延后,计入 deferred 统计。
      assert Egress.stats(e).deferred_bulk >= 1
      assert Egress.pending_count(e) == 1
    end

    test "bulk 同 chunk 合并到最新(延后不清零)" do
      e = new(capacity_bytes: 1, now_ms: 0)
      e = Egress.enqueue_payload(e, :voxel_chunk_snapshot_payload, {0, 0, 0}, <<1>>)
      e = Egress.enqueue_payload(e, :voxel_chunk_snapshot_payload, {0, 0, 0}, <<2>>)
      assert Egress.pending_count(e) == 1
    end
  end

  describe "reliable 队列溢出:丢最旧 + 登记 resync(显式非静默)" do
    test "超 max_queue_depth 丢最旧并记 resync cell" do
      e = new(capacity_bytes: 1_000_000, max_queue_depth: 2, now_ms: 0)
      e = Egress.enqueue_payload(e, :voxel_chunk_delta_payload, {7, 0, 0}, <<1>>, delta_base: 0)
      e = Egress.enqueue_payload(e, :voxel_chunk_delta_payload, {7, 0, 0}, <<2>>, delta_base: 1)
      # 第三帧触发溢出,丢最旧(<<1>>),登记 cell {7,0,0} resync。
      e = Egress.enqueue_payload(e, :voxel_chunk_delta_payload, {7, 0, 0}, <<3>>, delta_base: 2)

      assert Egress.pending_count(e) == 2
      assert Egress.stats(e).dropped_reliable == 1
      assert MapSet.member?(Egress.resync_cells(e), {7, 0, 0})

      {out, _} = Egress.flush(e, 0)

      assert out == [
               {:voxel_chunk_delta_payload, <<2>>},
               {:voxel_chunk_delta_payload, <<3>>}
             ]
    end

    test "clear_resync_cells 清空已消费的 resync 集合" do
      e = new(capacity_bytes: 1_000_000, max_queue_depth: 1, now_ms: 0)
      e = Egress.enqueue_payload(e, :voxel_chunk_delta_payload, {1, 0, 0}, <<1>>, delta_base: 0)
      e = Egress.enqueue_payload(e, :voxel_chunk_delta_payload, {1, 0, 0}, <<2>>, delta_base: 1)
      assert MapSet.size(Egress.resync_cells(e)) == 1
      e = Egress.clear_resync_cells(e)
      assert MapSet.size(Egress.resync_cells(e)) == 0
    end
  end

  describe "first flush 锚定单调时间" do
    test "last_refill 为 nil 时首 flush 仅锚定不补充" do
      e = new(capacity_bytes: 100)
      assert e.last_refill_ms == nil
      {_out, e} = Egress.flush(e, 5000)
      assert e.last_refill_ms == 5000
      # 满桶起步,available 仍为容量。
      assert Egress.available_tokens(e) == 100.0
    end
  end
end
