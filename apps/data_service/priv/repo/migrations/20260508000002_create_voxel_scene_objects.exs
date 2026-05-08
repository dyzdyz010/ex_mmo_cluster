defmodule DataService.Repo.Migrations.CreateVoxelSceneObjects do
  use Ecto.Migration

  @moduledoc """
  Canonical persistence for `DataService.Voxel.SceneObjectStore`.

  Phase 4 (D1):每个已放置的对象实例(`SceneObjectInstance`)落一行,Scene
  端 `SceneServer.Voxel.ObjectRegistry` 启动时从此表 LOAD 整 scene 的所有
  活跃对象。`object_id` 由 `voxel_scene_object_id_seq` 全局 sequence 分配,
  在 World coordinator 的 `begin_transaction` 路径同步 nextval(参考 D2)。

  `covered_chunks` 与 `part_states` 都是 `:erlang.term_to_binary/1` 编码的
  二进制 blob,只在 server 端用,不上 wire,不跨语言:

  * `covered_chunks`:`[{cx, cy, cz}, ...]`,对象覆盖的 chunk 列表
  * `part_states`:`[%{part_id, health, state_flags}, ...]`,运行时 part 状态
    (Phase 4 Step 4-3 引入 `SceneServer.Voxel.PartState` struct)

  反序列化时统一用 `[:safe]` 模式防止反序列化未知 atom 导致 atom 表膨胀。

  `anchor_world_micro_x/y/z` 是 i64 微格世界坐标,**可为负**,因此不加
  `>= 0` CHECK 约束。其它 bigint 字段沿 Phase 3-bis 风格加 `>= 0` 约束。

  PRIMARY KEY 为单列 `object_id`(全局唯一);`(logical_scene_id, object_id)`
  UNIQUE 约束兜底跨场景查询语义。
  """

  def change do
    execute(
      "CREATE SEQUENCE voxel_scene_object_id_seq START 1 INCREMENT 1",
      "DROP SEQUENCE voxel_scene_object_id_seq"
    )

    create table(:voxel_scene_objects, primary_key: false) do
      add(:object_id, :bigint, null: false, primary_key: true)
      add(:logical_scene_id, :bigint, null: false)
      add(:parcel_id, :bigint, null: false)
      add(:blueprint_id, :bigint, null: false)
      add(:blueprint_version, :integer, null: false)
      add(:anchor_world_micro_x, :bigint, null: false)
      add(:anchor_world_micro_y, :bigint, null: false)
      add(:anchor_world_micro_z, :bigint, null: false)
      add(:rotation, :smallint, null: false)
      add(:owner_actor_id, :bigint, null: false)
      add(:state_flags, :integer, null: false, default: 0)
      add(:object_attribute_ref, :integer, null: false, default: 0)
      add(:object_tag_set_ref, :integer, null: false, default: 0)
      add(:covered_chunks, :binary, null: false)
      add(:part_states, :binary, null: false)
      add(:object_version, :bigint, null: false)

      timestamps()
    end

    create(unique_index(:voxel_scene_objects, [:logical_scene_id, :object_id]))
    create(index(:voxel_scene_objects, [:logical_scene_id]))

    for {field, name} <- [
          {"object_id", "voxel_scene_objects_object_id_nonneg"},
          {"logical_scene_id", "voxel_scene_objects_logical_scene_id_nonneg"},
          {"parcel_id", "voxel_scene_objects_parcel_id_nonneg"},
          {"blueprint_id", "voxel_scene_objects_blueprint_id_nonneg"},
          {"blueprint_version", "voxel_scene_objects_blueprint_version_nonneg"},
          {"rotation", "voxel_scene_objects_rotation_nonneg"},
          {"owner_actor_id", "voxel_scene_objects_owner_actor_id_nonneg"},
          {"state_flags", "voxel_scene_objects_state_flags_nonneg"},
          {"object_attribute_ref", "voxel_scene_objects_object_attribute_ref_nonneg"},
          {"object_tag_set_ref", "voxel_scene_objects_object_tag_set_ref_nonneg"},
          {"object_version", "voxel_scene_objects_object_version_nonneg"}
        ] do
      execute(
        "ALTER TABLE voxel_scene_objects ADD CONSTRAINT #{name} CHECK (#{field} >= 0)",
        "ALTER TABLE voxel_scene_objects DROP CONSTRAINT #{name}"
      )
    end
  end
end
