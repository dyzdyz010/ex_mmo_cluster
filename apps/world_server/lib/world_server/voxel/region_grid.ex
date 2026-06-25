defmodule WorldServer.Voxel.RegionGrid do
  @moduledoc """
  Implicit (lattice) partition of chunk space into regions — the keystone that
  makes the voxel world **unbounded**: `region = f(chunk_coord)` is a pure
  function, so any chunk a player reaches maps to a well-defined region the
  ledger can lazily materialize. There is no hand-placed region box and therefore
  no "outside the box" — the old `:unassigned_chunk` terminal state (W1/W2)
  disappears.

  A region is an axis-aligned block of `{Sx, Sy, Sz}` chunks. `Sx`/`Sz` are the
  horizontal stride (default 8) and `Sy` the vertical stride (default 64 — worlds
  are thin vertically, so a tall stride avoids a swarm of near-empty air regions).
  Bounds are **half-open** chunk-coord AABBs (`min <= c < max`), matching
  `WorldServer.Voxel.RegionAssignment.contains_chunk?/2` and `MmoContracts.CellId`
  `:region` kind (CELL-2/3 [v2.0.2], 含 Y).

  ## region_id encoding

  `region_id` must remain a **globally-unique** integer key, because the ledger's
  `assignments` / `leases` maps and the DataService epoch / write-token rows are
  keyed by `region_id` alone (not `{logical_scene_id, region_id}`). So the id
  packs `logical_scene_id` into its high bits — the same spirit as the legacy
  `logical_scene_id * 1_000_000 + n` convention, now a fixed bit layout:

      bit  62..39 (24 bits)  logical_scene_id        0..16_777_215
      bit  38..23 (16 bits)  zigzag(region_index_x)  rx ∈ [-32_768, 32_767]
      bit  22..7  (16 bits)  zigzag(region_index_z)  rz ∈ [-32_768, 32_767]
      bit   6..0  (7 bits)   zigzag(region_index_y)  ry ∈ [-64, 63]

  Total 63 bits → fits a signed Postgres `bigint`. The horizontal reach (±32_768
  regions × 8 chunks × 16 macros ≈ ±4.2M macro cells) is effectively unbounded for
  gameplay, and the vertical reach (±64 regions × 64 chunks × 16 ≈ ±65k macros) is
  far beyond any world height; up to ~16.7M logical scenes are addressable.
  Coordinates / scene ids past the edge **raise** rather than silently aliasing a
  far region onto a near one. The encoding is a pure bijection over its domain, so
  `region_id` round-trips back to `{logical_scene_id, region_index}` for debug /
  inverse lookup.

  ## D-2 seam

  This is the **production** region encoding. The `region ↔ morton` equivalence
  the spec requires (`MmoContracts.CellId.region_to_morton/1`, currently
  `:mapping_not_implemented`) is a *separate* migration seam — the bit layout here
  is a dense lattice id, not a Morton interleave. Defining that equivalence is the
  D-2 follow-up; nothing here forecloses it.
  """

  import Bitwise

  @enforce_keys [:sx, :sy, :sz]
  defstruct sx: 8, sy: 64, sz: 8

  @type region_index :: {integer(), integer(), integer()}
  @type chunk_coord :: {integer(), integer(), integer()}

  @type t :: %__MODULE__{sx: pos_integer(), sy: pos_integer(), sz: pos_integer()}

  # Bit budgets (see @moduledoc layout). Kept here as the single source of truth
  # for both pack and unpack.
  @ls_bits 24
  @x_bits 16
  @z_bits 16
  @y_bits 7

  @y_shift 0
  @z_shift @y_bits
  @x_shift @y_bits + @z_bits
  @ls_shift @y_bits + @z_bits + @x_bits

  @ls_max (1 <<< @ls_bits) - 1
  @x_zz_max (1 <<< @x_bits) - 1
  @z_zz_max (1 <<< @z_bits) - 1
  @y_zz_max (1 <<< @y_bits) - 1

  @doc "The default grid (`Sx = Sz = 8`, `Sy = 64`)."
  @spec default() :: t()
  def default, do: %__MODULE__{sx: 8, sy: 64, sz: 8}

  @doc """
  Builds a grid with explicit strides (chunks per region edge). Each stride must
  be a positive integer.

  `Sx`/`Sy`/`Sz` are deliberately tunable (and intended to become per-logical-scene
  config rather than a global constant) — their final values are a压测 follow-up.
  """
  @spec new(pos_integer(), pos_integer(), pos_integer()) :: t()
  def new(sx, sy, sz)
      when is_integer(sx) and sx > 0 and is_integer(sy) and sy > 0 and is_integer(sz) and sz > 0 do
    %__MODULE__{sx: sx, sy: sy, sz: sz}
  end

  @doc "The lattice region index `{rx, ry, rz}` a chunk coordinate falls in (floor division, negatives included)."
  @spec region_index(t(), chunk_coord()) :: region_index()
  def region_index(%__MODULE__{sx: sx, sy: sy, sz: sz}, {cx, cy, cz})
      when is_integer(cx) and is_integer(cy) and is_integer(cz) do
    {Integer.floor_div(cx, sx), Integer.floor_div(cy, sy), Integer.floor_div(cz, sz)}
  end

  @doc "Half-open chunk-coord AABB `{min, max}` covered by a region index."
  @spec bounds(t(), region_index()) :: {chunk_coord(), chunk_coord()}
  def bounds(%__MODULE__{sx: sx, sy: sy, sz: sz}, {rx, ry, rz})
      when is_integer(rx) and is_integer(ry) and is_integer(rz) do
    {{rx * sx, ry * sy, rz * sz}, {(rx + 1) * sx, (ry + 1) * sy, (rz + 1) * sz}}
  end

  @doc """
  Packs `{logical_scene_id, region_index}` into the globally-unique `region_id`.

  Raises `ArgumentError` when any field is outside its bit budget (the world
  edge / too-large scene id) so callers fail loud instead of aliasing a distant
  region onto a near one.
  """
  @spec region_id(non_neg_integer(), region_index()) :: non_neg_integer()
  def region_id(logical_scene_id, {rx, ry, rz})
      when is_integer(logical_scene_id) and logical_scene_id >= 0 and
             is_integer(rx) and is_integer(ry) and is_integer(rz) do
    ensure_in_budget!(:logical_scene_id, logical_scene_id, 0, @ls_max)
    zz_x = ensure_zigzag_in_budget!(:region_index_x, rx, @x_zz_max)
    zz_z = ensure_zigzag_in_budget!(:region_index_z, rz, @z_zz_max)
    zz_y = ensure_zigzag_in_budget!(:region_index_y, ry, @y_zz_max)

    logical_scene_id <<< @ls_shift |||
      zz_x <<< @x_shift |||
      zz_z <<< @z_shift |||
      zz_y <<< @y_shift
  end

  @doc "Inverse of `region_id/2`: recovers `{logical_scene_id, region_index}` from a packed id."
  @spec decode_region_id(non_neg_integer()) :: {non_neg_integer(), region_index()}
  def decode_region_id(region_id) when is_integer(region_id) and region_id >= 0 do
    logical_scene_id = region_id >>> @ls_shift &&& @ls_max
    zz_x = region_id >>> @x_shift &&& @x_zz_max
    zz_z = region_id >>> @z_shift &&& @z_zz_max
    zz_y = region_id >>> @y_shift &&& @y_zz_max
    {logical_scene_id, {unzigzag(zz_x), unzigzag(zz_y), unzigzag(zz_z)}}
  end

  @doc """
  One-shot locate: everything routing needs for a chunk in a logical scene —
  the region index, its globally-unique id, and its half-open chunk bounds.
  """
  @spec locate(t(), non_neg_integer(), chunk_coord()) :: %{
          region_index: region_index(),
          region_id: non_neg_integer(),
          bounds_chunk_min: chunk_coord(),
          bounds_chunk_max: chunk_coord()
        }
  def locate(%__MODULE__{} = grid, logical_scene_id, chunk_coord) do
    index = region_index(grid, chunk_coord)
    {min, max} = bounds(grid, index)

    %{
      region_index: index,
      region_id: region_id(logical_scene_id, index),
      bounds_chunk_min: min,
      bounds_chunk_max: max
    }
  end

  # ── zigzag (signed → non-negative) ───────────────────────────────────────────

  defp zigzag(n) when n >= 0, do: n * 2
  defp zigzag(n), do: -n * 2 - 1

  defp unzigzag(z) when (z &&& 1) == 0, do: z >>> 1
  defp unzigzag(z), do: -((z + 1) >>> 1)

  defp ensure_zigzag_in_budget!(field, value, zz_max) do
    zz = zigzag(value)
    ensure_in_budget!(field, zz, 0, zz_max)
    zz
  end

  defp ensure_in_budget!(_field, value, lo, hi) when value >= lo and value <= hi, do: value

  defp ensure_in_budget!(field, value, _lo, _hi) do
    raise ArgumentError,
          "RegionGrid: #{field} out of encodable range (got #{inspect(value)} after zigzag); " <>
            "world edge or scene id exceeds the region_id bit budget"
  end
end
