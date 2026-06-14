defmodule MmoContracts.EnvelopeSubtypesTest do
  use ExUnit.Case, async: true

  alias MmoContracts.Envelope.{EntityHandoff, CellMigration, BoundaryEvent, CandidateEffect}

  describe "EntityHandoff(CELL-9/12)" do
    @valid %{
      entity_transfer_id: "t1",
      entity_id: "e1",
      source_cell_id: "A",
      target_cell_id: "B",
      source_owner_epoch: 3,
      target_owner_epoch: 5,
      handoff_tick: 1000,
      transfer_status: :prepare,
      transfer_payload_version: 1,
      idempotency_key: "idem",
      deadline_tick: 1100,
      transfer_seq: 1,
      entity_state_digest: "digest"
    }

    test "合法 handoff 构造成功" do
      assert {:ok, %EntityHandoff{transfer_status: :prepare}} = EntityHandoff.new(@valid)
    end

    test "信封不含、不递增 Cell owner_epoch(CELL-9/11)" do
      # 只有 source/target epoch 用于 fencing,没有裸 owner_epoch 字段
      refute Map.has_key?(%EntityHandoff{}, :owner_epoch)
      assert Map.has_key?(%EntityHandoff{}, :source_owner_epoch)
      assert Map.has_key?(%EntityHandoff{}, :target_owner_epoch)
    end

    test "transfer_status 必须合法(prepare/accept/commit/abort/timeout)" do
      assert {:error, {:invalid_transfer_status, :bogus}} =
               EntityHandoff.new(%{@valid | transfer_status: :bogus})

      assert EntityHandoff.transfer_statuses() == [:prepare, :accept, :commit, :abort, :timeout]
    end

    test "source_cell_seq 或 transfer_seq 至少其一" do
      no_seq = Map.drop(@valid, [:transfer_seq])
      assert {:error, {:missing_required, specs}} = EntityHandoff.new(no_seq)
      assert [:source_cell_seq, :transfer_seq] in specs
    end

    test "entity_state_ref 或 entity_state_digest 至少其一" do
      no_state = Map.drop(@valid, [:entity_state_digest])
      assert {:error, {:missing_required, specs}} = EntityHandoff.new(no_state)
      assert [:entity_state_ref, :entity_state_digest] in specs
    end
  end

  describe "CellMigration(CELL-10/11)" do
    test "owner_epoch 仅在此处、且必须单调递增" do
      assert {:ok, %CellMigration{new_owner_epoch: 6}} =
               CellMigration.new(%{
                 cell_id: "A",
                 old_owner_epoch: 5,
                 new_owner_epoch: 6,
                 migration_tick: 2000
               })

      assert {:error, {:owner_epoch_not_monotonic, _}} =
               CellMigration.new(%{
                 cell_id: "A",
                 old_owner_epoch: 6,
                 new_owner_epoch: 6,
                 migration_tick: 2000
               })
    end
  end

  describe "BoundaryEvent(XBOUND-3 / ANTI-37)" do
    @valid %{
      source_cell_id: "A",
      target_cell_id: "B",
      source_owner_epoch: 1,
      target_owner_epoch: 2,
      source_cell_tick: 10,
      tick_id: 11,
      source_seq: 3,
      event_id: "ev1",
      idempotency_key: "idem",
      delivery_class: :reliable_ordered,
      boundary_payload_version: 1
    }

    test "需 source/target 双 epoch(target_owner_epoch 或 target_epoch_observed)" do
      assert {:ok, %BoundaryEvent{}} = BoundaryEvent.new(@valid)

      observed =
        @valid |> Map.drop([:target_owner_epoch]) |> Map.put(:target_epoch_observed, 2)

      assert {:ok, %BoundaryEvent{}} = BoundaryEvent.new(observed)

      neither = Map.drop(@valid, [:target_owner_epoch])
      assert {:error, {:missing_required, specs}} = BoundaryEvent.new(neither)
      assert [:target_owner_epoch, :target_epoch_observed] in specs
    end
  end

  describe "CandidateEffect(RULE-15/16 / FROZEN-5)" do
    @valid %{
      candidate_effect_id: "ce1",
      rule_id: :ignition,
      rule_version: "fire@1",
      affected_object_id: "blk1",
      quantized_condition_bucket: 7,
      latch_status: :latched,
      state_class: :durable_authoritative,
      payload_version: 1,
      source_seq: 100
    }

    test "合法候选效果构造成功" do
      assert {:ok, %CandidateEffect{}} = CandidateEffect.new(@valid)
    end

    test "state_class 必须合法" do
      assert {:error, {:invalid_state_class, :nope}} =
               CandidateEffect.new(%{@valid | state_class: :nope})
    end

    test "source_seq 或 tick_range 至少其一" do
      with_range = @valid |> Map.drop([:source_seq]) |> Map.put(:tick_range, {1, 5})
      assert {:ok, _} = CandidateEffect.new(with_range)

      neither = Map.drop(@valid, [:source_seq])
      assert {:error, {:missing_required, specs}} = CandidateEffect.new(neither)
      assert [:source_seq, :tick_range] in specs
    end
  end
end
