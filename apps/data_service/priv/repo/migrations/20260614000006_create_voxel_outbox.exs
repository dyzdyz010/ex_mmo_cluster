defmodule DataService.Repo.Migrations.CreateVoxelOutbox do
  use Ecto.Migration

  @moduledoc """
  Durable replication outbox(梯队3 step3.9,AUTH-9/10)。

  每条 committed 的 ChunkDelta 在落 truth(durable persist,durable-before-ack)之后、fanout 给
  subscribers 之前同步追加一行。供:
    * 可靠重投:重连 / 丢包的 observer 用 `read_since(scene, chunk, since_version)` 重放错过的 delta,
      而非每次拉整 ChunkSnapshot。
    * `visibility_watermark`:`watermark(scene, chunk)` = 该 chunk 已 committed 的 max `new_chunk_version`。
      复制只发 ≤ watermark 的态(speculative 不下行,AUTH-8)——voxel 路径本就只在 commit 后推,watermark
      在此 formalize。

  成本:热路径每 committed delta 一次 INSERT;表增长需 TTL/trim(后续按需)。
  """

  def change do
    create table(:voxel_outbox) do
      add(:logical_scene_id, :bigint, null: false)
      add(:coord_x, :integer, null: false)
      add(:coord_y, :integer, null: false)
      add(:coord_z, :integer, null: false)
      add(:base_chunk_version, :bigint, null: false)
      add(:new_chunk_version, :bigint, null: false)
      add(:reliability_class, :string, null: false, default: "state")
      add(:payload, :binary, null: false)

      timestamps(updated_at: false)
    end

    # read_since + watermark 的复合索引(按 chunk 定位 + 版本范围/最大)。
    create(
      index(:voxel_outbox, [:logical_scene_id, :coord_x, :coord_y, :coord_z, :new_chunk_version])
    )
  end
end
