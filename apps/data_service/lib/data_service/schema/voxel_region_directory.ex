defmodule DataService.Schema.VoxelRegionDirectory do
  @moduledoc """
  Ecto schema for the `voxel_region_directory` row(阶段2)。

  每个 region 一行(主键 `region_id`),承载重建 `WorldServer.Voxel.RegionAssignment` +
  `WorldServer.Voxel.SceneLease` 所需的全部 durable 字段。是
  `DataService.Voxel.RegionDirectoryStore` 的后端,使懒物化的 region 所有权/lease 在
  World 节点重启后可恢复(CELL-23)。
  """
  use Ecto.Schema

  # PERS-5:durable_authoritative(region 所有权目录/owner_epoch/lease)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  schema "voxel_region_directory" do
    field(:region_id, :integer, primary_key: true)
    field(:logical_scene_id, :integer)
    field(:bounds_chunk_min_x, :integer)
    field(:bounds_chunk_min_y, :integer)
    field(:bounds_chunk_min_z, :integer)
    field(:bounds_chunk_max_x, :integer)
    field(:bounds_chunk_max_y, :integer)
    field(:bounds_chunk_max_z, :integer)
    field(:owner_scene_instance_ref, :integer)
    field(:owner_epoch, :integer)
    field(:lease_id, :integer)
    field(:assigned_scene_node, :string)
    field(:region_state, :string)
    field(:region_version, :integer)
    field(:expires_at_ms, :integer)

    timestamps()
  end

  @required_fields [
    :region_id,
    :logical_scene_id,
    :bounds_chunk_min_x,
    :bounds_chunk_min_y,
    :bounds_chunk_min_z,
    :bounds_chunk_max_x,
    :bounds_chunk_max_y,
    :bounds_chunk_max_z,
    :owner_scene_instance_ref,
    :owner_epoch,
    :region_state,
    :region_version
  ]

  @optional_fields [:lease_id, :assigned_scene_node, :expires_at_ms]

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
