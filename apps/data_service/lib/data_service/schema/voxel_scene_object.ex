defmodule DataService.Schema.VoxelSceneObject do
  @moduledoc """
  Canonical Ecto schema for one persisted scene object instance.

  Mirrors the `voxel_scene_objects` table created by
  `DataService.Repo.Migrations.CreateVoxelSceneObjects`. Each row represents
  one `SceneObjectInstance`(协议 §8.2)落地后的真相记录:`object_id`、所属
  蓝图、世界锚点、`part_states`、覆盖到哪些 chunk。

  `covered_chunks` 与 `part_states` 都是 `:erlang.term_to_binary/1` 编码的
  服务端 blob(详见 `DataService.Voxel.SceneObjectStore` moduledoc)。

  See `docs/voxel-server-authority/phase-4-object-provenance.md` for the
  decision context (D1)。
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:object_id, :integer, autogenerate: false}
  schema "voxel_scene_objects" do
    field(:logical_scene_id, :integer)
    field(:parcel_id, :integer)
    field(:blueprint_id, :integer)
    field(:blueprint_version, :integer)
    field(:anchor_world_micro_x, :integer)
    field(:anchor_world_micro_y, :integer)
    field(:anchor_world_micro_z, :integer)
    field(:rotation, :integer)
    field(:owner_actor_id, :integer)
    field(:state_flags, :integer, default: 0)
    field(:object_attribute_ref, :integer, default: 0)
    field(:object_tag_set_ref, :integer, default: 0)
    field(:covered_chunks, :binary)
    field(:part_states, :binary)
    field(:object_version, :integer)

    timestamps()
  end

  @required_fields [
    :object_id,
    :logical_scene_id,
    :parcel_id,
    :blueprint_id,
    :blueprint_version,
    :anchor_world_micro_x,
    :anchor_world_micro_y,
    :anchor_world_micro_z,
    :rotation,
    :owner_actor_id,
    :state_flags,
    :object_attribute_ref,
    :object_tag_set_ref,
    :covered_chunks,
    :part_states,
    :object_version
  ]

  # `anchor_world_micro_*` 是 i64 世界坐标,可负;不加非负约束。
  @nonneg_fields [
    :object_id,
    :logical_scene_id,
    :parcel_id,
    :blueprint_id,
    :blueprint_version,
    :rotation,
    :owner_actor_id,
    :state_flags,
    :object_attribute_ref,
    :object_tag_set_ref,
    :object_version
  ]

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_nonneg(@nonneg_fields)
    |> validate_covered_chunks_nonempty()
    |> validate_part_states_nonempty()
    |> unique_constraint(
      [:logical_scene_id, :object_id],
      name: :voxel_scene_objects_logical_scene_id_object_id_index,
      error_key: :object_id,
      message: "scene object already present"
    )
  end

  defp validate_nonneg(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case get_field(acc, field) do
        value when is_integer(value) and value < 0 ->
          add_error(acc, field, "must be >= 0")

        _ ->
          acc
      end
    end)
  end

  defp validate_covered_chunks_nonempty(changeset) do
    case get_field(changeset, :covered_chunks) do
      <<>> -> add_error(changeset, :covered_chunks, "must not be empty")
      _ -> changeset
    end
  end

  defp validate_part_states_nonempty(changeset) do
    case get_field(changeset, :part_states) do
      <<>> -> add_error(changeset, :part_states, "must not be empty")
      _ -> changeset
    end
  end
end
