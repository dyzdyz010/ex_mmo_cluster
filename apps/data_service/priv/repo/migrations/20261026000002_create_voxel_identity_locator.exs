defmodule DataService.Repo.Migrations.CreateVoxelIdentityLocator do
  use Ecto.Migration

  @moduledoc """
  M2b 身份定位表（`docs/10-active/voxel-authority/2026-10-24-world-region-paging/m2b-on-demand-pages.md` §2.3）：
  实例 id（`kind = 1`，`{a, b}` = `{birth, occurrence}`）或有主附件 id（`kind = 2`，`a` = aid、`b` = 0）→ 所在实例树的根与根的 home L0 页。

  根与根 home 自身份创建起不变（父 id 与 anchor 不改；搬移 / 替换产生新身份），所以世界存续期间只插入、不更新、不删除：
  随切点批次与页段同一 PG 事务写入（`ON CONFLICT DO NOTHING`）；身份删除后行仍在，查到后装根页即知其已不存在。
  测试专用 `OverlayLogStore.reset/reset_world` 退休整个世界时一并清除此表，不改变运行时身份删除的语义。
  `content_version` 与其他体素表相同（u64 按补码存 bigint）。
  """

  def change do
    create table(:voxel_identity_locator, primary_key: false) do
      add(:content_version, :bigint, null: false, primary_key: true)
      add(:kind, :smallint, null: false, primary_key: true)
      add(:id_a, :bigint, null: false, primary_key: true)
      add(:id_b, :bigint, null: false, primary_key: true)
      add(:root_a, :bigint, null: false)
      add(:root_b, :bigint, null: false)
      add(:home_x, :integer, null: false)
      add(:home_y, :integer, null: false)
      add(:home_z, :integer, null: false)
    end
  end
end
