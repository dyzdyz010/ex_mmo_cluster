defmodule Mix.Tasks.GateServerDeliverySchedulerObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.GateServer.DeliverySchedulerObserve

  test "prints and logs a live voxel delivery scheduler summary" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-delivery-scheduler-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        DeliverySchedulerObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "77",
          "--chunk",
          "1,2,3",
          "--snapshot-version",
          "4",
          "--delta-version",
          "5"
        ])
      end)

    assert output =~ "gate_delivery_scheduler=ok"
    assert output =~ "logical_scene_id=77"
    assert output =~ "chunk=1,2,3"
    assert output =~ "snapshot_action=send_now"
    assert output =~ "delta_action=queued"
    assert output =~ "invalidate_action=send_now"
    assert output =~ "object_action=send_now"
    assert output =~ "field_snapshot_action=queued"
    assert output =~ "field_destroyed_action=send_now"
    assert output =~ "envelope_action=queued"
    assert output =~ "envelope_control_action=send_now"
    assert output =~ "envelope_tier=halo"
    assert output =~ "envelope_stream_class=field_state"
    assert output =~ "envelope_lease_id=100"
    assert output =~ "envelope_owner_epoch=1"
    assert output =~ "queued_count=0"
    assert output =~ "deferred_count=3"
    assert output =~ "pruned_count=3"
    assert output =~ "event_sent_count=1"
    assert output =~ "observe_log=#{observe_log}"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_voxel_delivery_scheduler_observe")
    assert log =~ ~s(event="gate_voxel_delivery_offer")
    assert log =~ ~s(event="gate_voxel_delivery_envelope_offer")
    assert log =~ "action: :queued"
    assert log =~ "frame_kind: :object_state_delta"
    assert log =~ "frame_kind: :field_region_destroyed"
    assert log =~ "stream_class: :field_state"
    assert log =~ "lease_id: 100"
    assert log =~ "owner_epoch: 1"
    assert log =~ "pruned_count: 1"
  end
end
