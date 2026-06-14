defmodule WorldServer.Entity.HandoffPlanTest do
  # 梯队1 step1.6b:entity_handoff 幂等协议基元(CELL-9~15)。
  use ExUnit.Case, async: true

  alias MmoContracts.Envelope.EntityHandoff
  alias WorldServer.Entity.HandoffPlan

  defp plan_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        entity_transfer_id: "et-1",
        entity_id: 42,
        entity_kind: :player,
        source_cell_id: 10,
        target_cell_id: 11,
        source_owner_epoch: 3,
        target_owner_epoch: 5,
        handoff_tick: 100,
        transfer_seq: 1,
        transfer_payload_version: 1,
        idempotency_key: {42, 10, 11, 1},
        deadline_tick: 200,
        entity_state_ref: "snap-ref-1"
      },
      Map.new(overrides)
    )
  end

  defp prepared, do: HandoffPlan.new!(plan_attrs())

  describe "new/1 构造与校验" do
    test "合法 attrs → :prepare,source_final_tick 默认取 handoff_tick" do
      assert {:ok, plan} = HandoffPlan.new(plan_attrs())
      assert plan.transfer_status == :prepare
      assert plan.source_final_tick == 100
    end

    test "缺必填键 → {:error, {:missing, key}}" do
      assert {:error, {:missing, :deadline_tick}} =
               HandoffPlan.new(Map.delete(plan_attrs(), :deadline_tick))
    end

    test "缺 entity_state_ref 且缺 digest → 拒" do
      attrs = plan_attrs() |> Map.delete(:entity_state_ref)
      assert {:error, {:missing, :entity_state_ref_or_digest}} = HandoffPlan.new(attrs)
    end

    test "非法 entity_kind → 拒" do
      assert {:error, {:invalid_entity_kind, :dragon}} =
               HandoffPlan.new(plan_attrs(%{entity_kind: :dragon}))
    end
  end

  describe "happy path prepare → accept → commit" do
    test "完整成功路径" do
      plan = prepared()
      assert plan.transfer_status == :prepare

      assert {:ok, accepted} =
               HandoffPlan.accept(plan, %{
                 observed_target_owner_epoch: 5,
                 target_accept_seq: 7,
                 target_start_tick: 101,
                 command_forward_from_seq: 50,
                 visibility_cutover_snapshot_seq: 900
               })

      assert accepted.transfer_status == :accept
      assert accepted.target_accept_seq == 7
      assert accepted.target_start_tick == 101
      assert accepted.command_forward_from_seq == 50

      assert {:ok, committed} = HandoffPlan.commit(accepted)
      assert committed.transfer_status == :commit
      assert HandoffPlan.terminal?(committed)
    end
  end

  describe "幂等(CELL-12)" do
    test "重复 accept 不复制(no-op)" do
      {:ok, accepted} = HandoffPlan.accept(prepared(), %{observed_target_owner_epoch: 5})
      assert {:ok, ^accepted} = HandoffPlan.accept(accepted, %{observed_target_owner_epoch: 5})
      # 即便携带不同 attrs,已 accept 也是 no-op(首次 accept 状态固定)。
      assert {:ok, ^accepted} = HandoffPlan.accept(accepted, %{target_accept_seq: 999})
    end

    test "重复 commit 不重复结算(no-op)" do
      {:ok, accepted} = HandoffPlan.accept(prepared(), %{observed_target_owner_epoch: 5})
      {:ok, committed} = HandoffPlan.commit(accepted)
      assert {:ok, ^committed} = HandoffPlan.commit(committed)
      assert {:ok, ^committed} = HandoffPlan.commit(committed)
    end

    test "重复 abort / timeout no-op" do
      {:ok, aborted} = HandoffPlan.abort(prepared(), :left_region)
      assert {:ok, ^aborted} = HandoffPlan.abort(aborted, :whatever)

      {:ok, timed} = HandoffPlan.timeout(prepared())
      assert {:ok, ^timed} = HandoffPlan.timeout(timed)
    end
  end

  describe "epoch fencing(CELL-9)" do
    test "accept 时 observed target epoch 不符 → :target_epoch_mismatch" do
      assert {:error, :target_epoch_mismatch} =
               HandoffPlan.accept(prepared(), %{observed_target_owner_epoch: 6})
    end

    test "owner_epoch 在 prepare→accept→commit 全程不变(不递增,CELL-11)" do
      plan = prepared()
      {:ok, accepted} = HandoffPlan.accept(plan, %{observed_target_owner_epoch: 5})
      {:ok, committed} = HandoffPlan.commit(accepted)

      for p <- [plan, accepted, committed] do
        assert p.source_owner_epoch == 3
        assert p.target_owner_epoch == 5
      end
    end
  end

  describe "非法顺序拒绝" do
    test "commit 不能从 :prepare" do
      assert {:error, {:cannot_commit_from, :prepare}} = HandoffPlan.commit(prepared())
    end

    test "accept 不能从 :commit" do
      {:ok, accepted} = HandoffPlan.accept(prepared(), %{observed_target_owner_epoch: 5})
      {:ok, committed} = HandoffPlan.commit(accepted)
      assert {:error, {:cannot_accept_from, :commit}} = HandoffPlan.accept(committed, %{})
    end

    test "abort / timeout 在 commit 后拒" do
      {:ok, accepted} = HandoffPlan.accept(prepared(), %{observed_target_owner_epoch: 5})
      {:ok, committed} = HandoffPlan.commit(accepted)
      assert {:error, :already_committed} = HandoffPlan.abort(committed, :x)
      assert {:error, :already_committed} = HandoffPlan.timeout(committed)
    end

    test "abort 后 commit 拒" do
      {:ok, aborted} = HandoffPlan.abort(prepared(), :left)
      assert {:error, {:cannot_commit_from, :abort}} = HandoffPlan.commit(aborted)
    end
  end

  describe "abort / timeout 来源" do
    test "abort 可从 :prepare 或 :accept" do
      assert {:ok, %{transfer_status: :abort, abort_reason: :r1}} =
               HandoffPlan.abort(prepared(), :r1)

      {:ok, accepted} = HandoffPlan.accept(prepared(), %{observed_target_owner_epoch: 5})
      assert {:ok, %{transfer_status: :abort}} = HandoffPlan.abort(accepted, :r2)
    end

    test "timeout 可从 :prepare 或 :accept" do
      assert {:ok, %{transfer_status: :timeout}} = HandoffPlan.timeout(prepared())

      {:ok, accepted} = HandoffPlan.accept(prepared(), %{observed_target_owner_epoch: 5})
      assert {:ok, %{transfer_status: :timeout}} = HandoffPlan.timeout(accepted)
    end
  end

  describe "entity_handoff_envelope/1" do
    test "构出合法 EntityHandoff 信封,transfer_status 跟随" do
      {:ok, accepted} =
        HandoffPlan.accept(prepared(), %{observed_target_owner_epoch: 5, target_accept_seq: 7})

      assert {:ok, %EntityHandoff{} = env} = HandoffPlan.entity_handoff_envelope(accepted)
      assert env.entity_transfer_id == "et-1"
      assert env.entity_id == 42
      assert env.source_cell_id == 10
      assert env.target_cell_id == 11
      assert env.source_owner_epoch == 3
      assert env.target_owner_epoch == 5
      assert env.transfer_status == :accept
      assert env.target_accept_seq == 7
      assert env.idempotency_key == {42, 10, 11, 1}
    end
  end
end
