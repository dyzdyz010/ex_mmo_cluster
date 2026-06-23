defmodule DataService.Schema.VoxelWriteToken do
  @moduledoc """
  Ecto schema for the `voxel_write_tokens` row(梯队1 step1.2)。

  每个 region 一行(复合主键 `(logical_scene_id, region_id)`),承载 World 发布的当前 lease
  写令牌:owner_epoch/lease 身份 + 半开 AABB bounds(含 Y)+ `token_version`(CAS 单调)。
  是 `DataService.Voxel.WriteTokenStore` 的 durable 后端,使 fencing 在节点重启后仍有效。
  """
  use Ecto.Schema

  # PERS-5:durable_authoritative(lease 写令牌/owner_epoch fencing)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  schema "voxel_write_tokens" do
    field(:logical_scene_id, :integer, primary_key: true)
    field(:region_id, :integer, primary_key: true)
    field(:lease_id, :integer)
    field(:owner_scene_instance_ref, :integer)
    field(:owner_epoch, :integer)
    field(:bounds_chunk_min_x, :integer)
    field(:bounds_chunk_min_y, :integer)
    field(:bounds_chunk_min_z, :integer)
    field(:bounds_chunk_max_x, :integer)
    field(:bounds_chunk_max_y, :integer)
    field(:bounds_chunk_max_z, :integer)
    field(:expires_at_ms, :integer)
    field(:token_version, :integer)

    timestamps()
  end

  @required_fields [
    :logical_scene_id,
    :region_id,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :bounds_chunk_min_x,
    :bounds_chunk_min_y,
    :bounds_chunk_min_z,
    :bounds_chunk_max_x,
    :bounds_chunk_max_y,
    :bounds_chunk_max_z,
    :expires_at_ms,
    :token_version
  ]

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
  end
end
