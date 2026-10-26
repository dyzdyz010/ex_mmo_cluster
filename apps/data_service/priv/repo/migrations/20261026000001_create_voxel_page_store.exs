defmodule DataService.Repo.Migrations.CreateVoxelPageStore do
  use Ecto.Migration

  @moduledoc """
  M2a 页表（`docs/10-active/voxel-authority/2026-10-24-world-region-paging/m2a-page-store.md` §6）：取代 60 s 整世界检查点。

  - `voxel_page_segment`：页的一个段（逐格段按 16³ 子块一行，`chunk` 为子块坐标；页级段 `chunk_*` 为 0）。切点 C 的写回以 `cut_seq = C`
    新增版本，不覆盖旧版本；`payload` 是 `term_to_binary(compressed)` 的段值。
  - `voxel_world_globals`：每个切点一行全局账。
  - `voxel_safe_prefix`：已完整发布的切点（安全前缀）。恢复 = 每个段 `max(cut_seq) <= seq` 的版本 + 同 seq 的全局行 + 日志 `seq > 前缀`。
  `content_version` 与 `voxel_overlay_log` 相同（u64 按补码存 bigint）。
  """

  def change do
    create table(:voxel_page_segment, primary_key: false) do
      add(:content_version, :bigint, null: false, primary_key: true)
      add(:level, :smallint, null: false, primary_key: true)
      add(:region_x, :integer, null: false, primary_key: true)
      add(:region_y, :integer, null: false, primary_key: true)
      add(:region_z, :integer, null: false, primary_key: true)
      add(:segment, :smallint, null: false, primary_key: true)
      add(:chunk_x, :integer, null: false, primary_key: true)
      add(:chunk_y, :integer, null: false, primary_key: true)
      add(:chunk_z, :integer, null: false, primary_key: true)
      add(:cut_seq, :bigint, null: false, primary_key: true)
      add(:payload, :binary, null: false)
    end

    create table(:voxel_world_globals, primary_key: false) do
      add(:content_version, :bigint, null: false, primary_key: true)
      add(:cut_seq, :bigint, null: false, primary_key: true)
      add(:payload, :binary, null: false)
    end

    create table(:voxel_safe_prefix, primary_key: false) do
      add(:content_version, :bigint, null: false, primary_key: true)
      add(:seq, :bigint, null: false)
    end
  end
end
