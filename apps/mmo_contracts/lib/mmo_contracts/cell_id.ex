defmodule MmoContracts.CellId do
  @moduledoc """
  Cell 寻址标识(CELL-2/3,含 v2.0.2 反哺修订)。

  统一容纳两种**等价**的所有权单位编码:

  - `:morton` —— 规范 CELL-2 的 `(level, morton)` 四叉树路径(XZ-column,CELL-3 推荐默认)。
  - `:region` —— v2.0.2 聚合等价:`region_id` + 连续 chunk **3D AABB**(`bounds_chunk_min/max`,
    **含 Y**,用于垂直分片;CELL-2/3 [v2.0.2] / D-2)。这是本仓**当前生产路径**(`region` 由
    `WorldServer.Voxel.MapLedger` 在隐式格点 `WorldServer.Voxel.RegionGrid` 上懒物化分配;
    生产 `region_id` 编码 = `RegionGrid.region_id/2`,把 `logical_scene_id` + 格点索引打包成
    全局唯一 bigint,**是稠密格点 id 而非 morton 交织**——morton 等价是下方独立的 D-2 接缝)。

  bounds 采用**半开区间** `min <= c < max`(与 `WorldServer.Voxel.RegionAssignment.contains_chunk?` 一致)。

  `region_to_morton/1` / `morton_to_region/1` 是 **D-2 要求的等价/迁移接缝**:规范要求 region 编码
  必须提供与 morton 的等价/迁移说明。本骨架先留显式占位(返回 `{:error, :mapping_not_implemented}`),
  待 region↔morton 映射策略定稿后实现。
  """

  @typedoc "chunk 坐标 {x, y, z}"
  @type chunk_coord :: {integer(), integer(), integer()}

  @type kind :: :morton | :region

  defstruct [
    :kind,
    :level,
    :morton,
    :region_id,
    :logical_scene_id,
    :bounds_chunk_min,
    :bounds_chunk_max
  ]

  @type t :: %__MODULE__{
          kind: kind() | nil,
          level: non_neg_integer() | nil,
          morton: non_neg_integer() | nil,
          region_id: term() | nil,
          logical_scene_id: term() | nil,
          bounds_chunk_min: chunk_coord() | nil,
          bounds_chunk_max: chunk_coord() | nil
        }

  @doc """
  构造 `(level, morton)` 四叉树 Cell(CELL-2,XZ-column)。
  """
  @spec morton(non_neg_integer(), non_neg_integer()) :: t()
  def morton(level, code)
      when is_integer(level) and level >= 0 and is_integer(code) and code >= 0 do
    %__MODULE__{kind: :morton, level: level, morton: code}
  end

  @doc """
  构造 region 聚合等价 Cell(v2.0.2,3D AABB 含 Y)。

  `min`/`max` 为 chunk 坐标三元组,半开区间 `min <= c < max`,要求各轴 `max > min`。
  """
  @spec region(term(), term(), chunk_coord(), chunk_coord()) :: t()
  def region(region_id, logical_scene_id, {minx, miny, minz} = min, {maxx, maxy, maxz} = max)
      when is_integer(minx) and is_integer(miny) and is_integer(minz) and
             is_integer(maxx) and is_integer(maxy) and is_integer(maxz) and
             maxx > minx and maxy > miny and maxz > minz do
    %__MODULE__{
      kind: :region,
      region_id: region_id,
      logical_scene_id: logical_scene_id,
      bounds_chunk_min: min,
      bounds_chunk_max: max
    }
  end

  @doc "是否为结构良好的 CellId。"
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{kind: :morton, level: l, morton: m})
      when is_integer(l) and l >= 0 and is_integer(m) and m >= 0,
      do: true

  def valid?(%__MODULE__{
        kind: :region,
        region_id: rid,
        bounds_chunk_min: {_, _, _},
        bounds_chunk_max: {_, _, _}
      })
      when not is_nil(rid),
      do: true

  def valid?(_), do: false

  @doc "编码种类。"
  @spec kind(t()) :: kind()
  def kind(%__MODULE__{kind: k}), do: k

  @doc """
  region Cell 是否覆盖某 chunk 坐标(3D AABB 半开区间,**含 Y**,D-2)。

  对 `:morton` Cell 抛出(morton 不携带显式 bounds;XZ-column 覆盖语义由四叉树层级决定)。
  """
  @spec contains_chunk?(t(), chunk_coord()) :: boolean()
  def contains_chunk?(
        %__MODULE__{
          kind: :region,
          bounds_chunk_min: {minx, miny, minz},
          bounds_chunk_max: {maxx, maxy, maxz}
        },
        {cx, cy, cz}
      ) do
    cx >= minx and cx < maxx and
      cy >= miny and cy < maxy and
      cz >= minz and cz < maxz
  end

  def contains_chunk?(%__MODULE__{kind: :morton}, _coord) do
    raise ArgumentError, "morton CellId 不携带显式 chunk bounds;请用四叉树层级覆盖判定"
  end

  @doc """
  region → (level, morton) 等价映射(**D-2 迁移接缝,未实现**)。

  规范 CELL-2 [v2.0.2] 要求 region 编码提供与 morton 的等价/迁移说明。映射策略定稿前返回占位。
  """
  @spec region_to_morton(t()) :: {:ok, t()} | {:error, :mapping_not_implemented}
  def region_to_morton(%__MODULE__{kind: :region}), do: {:error, :mapping_not_implemented}

  @doc """
  (level, morton) → region 等价映射(**D-2 迁移接缝,未实现**)。
  """
  @spec morton_to_region(t()) :: {:ok, t()} | {:error, :mapping_not_implemented}
  def morton_to_region(%__MODULE__{kind: :morton}), do: {:error, :mapping_not_implemented}
end
