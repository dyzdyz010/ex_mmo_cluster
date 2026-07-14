defmodule DataService.Schema.VoxelLodHeightmapCell do
  @moduledoc """
  已归档 XZ heightmap 的持久化 derived cell，仅供离线迁移与对照。

  Rows are keyed by `{logical_scene_id, stride, cell_x, cell_z}` where
  `cell_x/cell_z` are grid coordinates in the stride-specific LOD grid. The
  table is a rebuildable projection of authoritative voxel chunk truth, not an
  independent source of world truth，也不属于当前在线运行时。
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  schema "voxel_lod_heightmap_cells" do
    field(:logical_scene_id, :integer, primary_key: true)
    field(:stride, :integer, primary_key: true)
    field(:cell_x, :integer, primary_key: true)
    field(:cell_z, :integer, primary_key: true)
    field(:height, :integer)
    field(:material_id, :integer)
    field(:source_chunk_x, :integer)
    field(:source_chunk_y, :integer)
    field(:source_chunk_z, :integer)
    field(:source_chunk_version, :integer)

    timestamps()
  end

  @required_fields [:logical_scene_id, :stride, :cell_x, :cell_z, :height, :material_id]
  @optional_fields [:source_chunk_x, :source_chunk_y, :source_chunk_z, :source_chunk_version]

  @doc false
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:logical_scene_id, greater_than_or_equal_to: 0)
    |> validate_number(:stride, greater_than: 0)
    |> validate_number(:height, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
    |> validate_number(:material_id, greater_than_or_equal_to: 0, less_than_or_equal_to: 65_535)
    |> validate_source_chunk_version()
  end

  defp validate_source_chunk_version(changeset) do
    case get_field(changeset, :source_chunk_version) do
      value when is_integer(value) and value < 0 ->
        add_error(changeset, :source_chunk_version, "must be >= 0")

      _other ->
        changeset
    end
  end
end
