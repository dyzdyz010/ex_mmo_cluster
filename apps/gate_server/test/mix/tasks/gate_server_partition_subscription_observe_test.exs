defmodule Mix.Tasks.GateServerPartitionSubscriptionObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.GateServer.PartitionSubscriptionObserve

  test "prints and logs chunk boundary subscription rebinding summary" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-partition-subscription-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionSubscriptionObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "1",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "1650,100,100"
        ])
      end)

    assert output =~ "gate_partition_subscription=ok"
    assert output =~ "cid=42"
    assert output =~ "from_chunk=0,0,0"
    assert output =~ "to_chunk=1,0,0"
    assert output =~ "boundary=region"
    assert output =~ "subscription_apply_status=ok"
    assert output =~ "subscribe_count=1"
    assert output =~ "unsubscribe_count=1"
    assert output =~ "retained_count=0"
    assert output =~ "observe_log=#{observe_log}"

    log = File.read!(observe_log)
    assert log =~ ~s(event="voxel_subscription_diff_applied")
    assert log =~ ~s(event="gate_partition_subscription_resolved")
    assert log =~ "subscription_apply_status: :ok"
  end

  test "prints same-chunk no-op without rebinding streams" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-partition-subscription-same-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionSubscriptionObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "1",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "200,100,100"
        ])
      end)

    assert output =~ "gate_partition_subscription=ok"
    assert output =~ "from_chunk=0,0,0"
    assert output =~ "to_chunk=0,0,0"
    assert output =~ "boundary=none"
    assert output =~ "subscription_apply_status=none"
    assert output =~ "subscribe_count=0"
    assert output =~ "unsubscribe_count=0"
    assert output =~ "retained_count=0"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_partition_subscription_resolved")
    assert log =~ "boundary_kind: :none"
  end

  test "prints halo ghost prewarm counts when snapshot budget is reserved for the near chunk" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-partition-subscription-ghost-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionSubscriptionObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "1",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "1650,100,100",
          "--partition-radius",
          "1",
          "--voxel-snapshot-cap",
          "128"
        ])
      end)

    assert output =~ "gate_partition_subscription=ok"
    assert output =~ "snapshot_subscriptions=1"
    assert output =~ "ghost_subscriptions=1"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_partition_subscription_resolved")
    assert log =~ "initial_snapshot_count: 1"
    assert log =~ "ghost_subscription_count: 1"
  end

  test "prints ghost promotion counts when the destination chunk was already prewarmed" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-partition-subscription-promote-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionSubscriptionObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "1",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "1650,100,100",
          "--partition-radius",
          "1",
          "--voxel-snapshot-cap",
          "128",
          "--prewarm-destination-ghost"
        ])
      end)

    assert output =~ "gate_partition_subscription=ok"
    assert output =~ "promoted_subscriptions=1"
    assert output =~ "promotion_snapshots=1"

    log = File.read!(observe_log)
    assert log =~ "promoted_count: 1"
    assert log =~ "promotion_snapshot_count: 1"
  end

  test "prints forwarded-only known version as forced snapshot" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-partition-subscription-forwarded-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionSubscriptionObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "1",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "1650,100,100",
          "--known-version-mode",
          "forwarded",
          "--known-version",
          "9"
        ])
      end)

    assert output =~ "target_known_version_source=forwarded_only_rejected"
    assert output =~ "target_known_version_for_scene=none"

    log = File.read!(observe_log)
    assert log =~ "target_known_version_source: :forwarded_only_rejected"
    assert log =~ "target_known_version_for_scene: nil"
  end

  test "prints ack-backed known version reuse" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-partition-subscription-acked-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionSubscriptionObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "1",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "1650,100,100",
          "--known-version-mode",
          "acked",
          "--known-version",
          "9"
        ])
      end)

    assert output =~ "target_known_version_source=client_ack"
    assert output =~ "target_known_version_for_scene=9"

    log = File.read!(observe_log)
    assert log =~ "target_known_version_source: :client_ack"
    assert log =~ "target_known_version_for_scene: 9"
  end

  test "prints resync-required ack as forced snapshot" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-partition-subscription-resync-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionSubscriptionObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "1",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "1650,100,100",
          "--known-version-mode",
          "acked-resync",
          "--known-version",
          "9"
        ])
      end)

    assert output =~ "target_known_version_source=resync_required"
    assert output =~ "target_known_version_for_scene=none"

    log = File.read!(observe_log)
    assert log =~ "target_known_version_source: :resync_required"
    assert log =~ "target_known_version_for_scene: nil"
  end
end
