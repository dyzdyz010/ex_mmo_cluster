defmodule WorldServer.Voxel.MigrationPlanTest do
  # 梯队1 step1.6a:cell_migration 正名——migration_tick/commit_watermark + CellMigration 信封。
  use ExUnit.Case, async: true

  alias MmoContracts.Envelope.CellMigration
  alias WorldServer.Voxel.MigrationPlan

  defp lease(owner_epoch) do
    %{
      logical_scene_id: 1,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 2_000,
      owner_epoch: owner_epoch,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {1, 1, 1}
    }
  end

  defp build_plan(opts \\ []) do
    MigrationPlan.new(%{
      migration_id: "mig-1",
      logical_scene_id: 1,
      region_id: 10,
      source_scene_instance_ref: 1_000,
      target_scene_instance_ref: 2_000,
      old_lease: Keyword.get(opts, :old_lease, lease(2)),
      new_lease: Keyword.get(opts, :new_lease, lease(7)),
      affected_chunk_min: {0, 0, 0},
      affected_chunk_max: {1, 1, 1},
      token_version: 7,
      inserted_at_ms: 0,
      updated_at_ms: 0
    })
  end

  # 驱动单 slice 计划到 cutover,final-catchup 的 max_chunk_version 即前沿。
  defp drive_to_cutover(plan, max_chunk_version) do
    {:ok, slice, plan} = MigrationPlan.plan_next_slice(plan, 1)

    {:ok, plan, _slice} =
      MigrationPlan.mark_slice_prewarmed(plan, %{slice_id: slice.slice_id}, 2)

    {:ok, plan} = MigrationPlan.mark_prewarmed(plan, 3)

    {:ok, plan, _slice} =
      MigrationPlan.mark_slice_final_caught_up(
        plan,
        %{slice_id: slice.slice_id, max_chunk_version: max_chunk_version},
        4
      )

    MigrationPlan.cutover(plan, 5)
  end

  test "cutover 写入 migration_tick / commit_watermark = final-catchup 前沿" do
    {:ok, cutover_plan} = drive_to_cutover(build_plan(), 42)

    assert cutover_plan.state == :cutover
    assert cutover_plan.migration_tick == 42
    assert cutover_plan.commit_watermark == 42
  end

  test "cell_migration_envelope 构 CellMigration(new>old 单调)" do
    {:ok, cutover_plan} = drive_to_cutover(build_plan(old_lease: lease(2), new_lease: lease(7)), 42)

    assert {:ok, %CellMigration{} = env} = MigrationPlan.cell_migration_envelope(cutover_plan)
    assert env.cell_id == 10
    assert env.old_owner_epoch == 2
    assert env.new_owner_epoch == 7
    assert env.migration_tick == 42
    assert env.commit_watermark == 42
    assert env.snapshot_ref == "mig-1"
  end

  test "退化迁移(new == old)拒发信封(信封强制 new>old)" do
    {:ok, cutover_plan} = drive_to_cutover(build_plan(old_lease: lease(7), new_lease: lease(7)), 10)

    assert {:error, {:owner_epoch_not_monotonic, _}} =
             MigrationPlan.cell_migration_envelope(cutover_plan)
  end

  test "未 cutover(无 migration_tick)拒构信封" do
    assert {:error, :migration_not_cutover} =
             MigrationPlan.cell_migration_envelope(build_plan())
  end

  test "nil old_lease 视作 old_owner_epoch 0" do
    {:ok, cutover_plan} = drive_to_cutover(build_plan(old_lease: nil, new_lease: lease(1)), 5)

    assert {:ok, env} = MigrationPlan.cell_migration_envelope(cutover_plan)
    assert env.old_owner_epoch == 0
    assert env.new_owner_epoch == 1
  end

  test "summary 暴露 migration_tick / commit_watermark" do
    {:ok, cutover_plan} = drive_to_cutover(build_plan(), 13)
    summary = MigrationPlan.summary(cutover_plan)

    assert summary.migration_tick == 13
    assert summary.commit_watermark == 13
  end
end
