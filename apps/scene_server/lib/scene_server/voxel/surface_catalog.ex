defmodule SceneServer.Voxel.SurfaceCatalog do
  @moduledoc """
  表面元件类型表(形态轨 · 表面元件层)。

  决策稿 `docs/voxel-server-authority/2026-06-17-unit-morphology-and-surface-element-layer.md`。
  表面元件 = 绑在**单个宏格面**上的零体积单元(贴面条件 / 单面装置),走 terrain-bypass:**绝不进
  occupancy mask、不改宿主邻接**;状态用 per-face attribute/tag 承载,物理参与由材料属性向量派生。

  本模块是表面元件**类型**的静态 append-only 查表(同 `MaterialCatalog` 范式,而非运行时 truth):

    * `kind`:`:condition` 被动表面条件(氧化/霜/焦痕,可由系统沉积、被处理刮除)/ `:fixture` 单面装置
      (火炬/拉杆,带亮灭/开关状态机)。两者皆 terrain-bypass(D-2);kind 仅作语义标注。
    * `visibility`:`:hide_when_neighbor_occupied`(被相邻实格覆盖即隐,truth 留存)/ `:always_visible`。
    * `material`:物理参与借用的材料属性向量名(`MaterialCatalog`),`nil` = 暂不参与物理系统。

  类型 id 一旦发出即冻结(wire append-only),只尾部追加。面(face)ordinal 与
  `ParticipantProjection` 的 face_rank 一致,保证 wire 稳定。
  """

  # 6 个宏格面;ordinal 与 ParticipantProjection.face_rank 一致(wire 稳定,只追加不重排)。
  @faces [:x_neg, :x_pos, :y_neg, :y_pos, :z_neg, :z_pos]
  @face_ordinals %{x_neg: 0, x_pos: 1, y_neg: 2, y_pos: 3, z_neg: 4, z_pos: 5}
  @face_by_ordinal %{0 => :x_neg, 1 => :x_pos, 2 => :y_neg, 3 => :y_pos, 4 => :z_neg, 5 => :z_pos}

  # 表面元件类型 id(append-only)。名 ↔ id 冻结。
  @surface_type_ids %{
    rust_decal: 1,
    frost: 2,
    scorch: 3,
    torch: 4,
    lever: 5
  }

  @surface_types %{
    # 被动条件:氧化锈渍——S4 氧化的"皮相级"可见出口(借 rust 属性:不导电),被覆盖即隐,可被清理刮除。
    1 => %{
      name: :rust_decal,
      kind: :condition,
      visibility: :hide_when_neighbor_occupied,
      material: :rust
    },
    # 被动条件:结霜(借 ice 属性);相变皮相现象。
    2 => %{
      name: :frost,
      kind: :condition,
      visibility: :hide_when_neighbor_occupied,
      material: :ice
    },
    # 被动条件:焦痕(借 ash 属性);燃烧皮相现象。
    3 => %{
      name: :scorch,
      kind: :condition,
      visibility: :hide_when_neighbor_occupied,
      material: :ash
    },
    # 单面装置:火炬(始终可见;借 ember 材料属性向量参与热系统——heat_output>0 持续向宿主格注热)。
    4 => %{name: :torch, kind: :fixture, visibility: :always_visible, material: :ember},
    # 单面装置:拉杆(始终可见;开关状态机可复用 S3 Actuator 数据表)。
    5 => %{name: :lever, kind: :fixture, visibility: :always_visible, material: nil}
  }

  @doc "全部宏格面 atom(固定 6 个)。"
  @spec faces() :: [atom()]
  def faces, do: @faces

  @doc "面 atom → wire ordinal(0..5);未知返回 nil。"
  @spec face_ordinal(atom()) :: 0..5 | nil
  def face_ordinal(face) when is_atom(face), do: Map.get(@face_ordinals, face)

  @doc "wire ordinal(0..5)→ 面 atom;越界返回 nil。"
  @spec face_from_ordinal(integer()) :: atom() | nil
  def face_from_ordinal(ordinal) when is_integer(ordinal), do: Map.get(@face_by_ordinal, ordinal)

  @doc "是否合法面 atom。"
  @spec valid_face?(term()) :: boolean()
  def valid_face?(face), do: is_atom(face) and Map.has_key?(@face_ordinals, face)

  @doc "表面类型名 → append-only id(未知名返回 nil)。"
  @spec surface_type_id(atom()) :: pos_integer() | nil
  def surface_type_id(name) when is_atom(name), do: Map.get(@surface_type_ids, name)

  @doc "id → 表面类型名(未知 id 返回 nil)。"
  @spec surface_type_name(integer()) :: atom() | nil
  def surface_type_name(id) when is_integer(id) do
    case Map.get(@surface_types, id) do
      %{name: name} -> name
      _other -> nil
    end
  end

  @doc "id 是否已定义的表面类型。"
  @spec known_surface_type?(term()) :: boolean()
  def known_surface_type?(id), do: Map.has_key?(@surface_types, id)

  @doc "表面类型定义(name/kind/visibility/material);未知 id 返回 nil。"
  @spec definition(integer()) :: map() | nil
  def definition(id) when is_integer(id), do: Map.get(@surface_types, id)

  @doc "表面类型 kind(:condition | :fixture);未知返回 nil。"
  @spec kind(integer()) :: :condition | :fixture | nil
  def kind(id), do: field(id, :kind)

  @doc "表面类型可见性策略;未知返回 nil。"
  @spec visibility(integer()) :: :hide_when_neighbor_occupied | :always_visible | nil
  def visibility(id), do: field(id, :visibility)

  @doc "表面类型物理参与借用的材料名(nil = 不参与物理 / 未知 id)。"
  @spec material(integer()) :: atom() | nil
  def material(id), do: field(id, :material)

  @doc "全部表面类型名 → id 映射。"
  @spec surface_type_ids() :: %{atom() => pos_integer()}
  def surface_type_ids, do: @surface_type_ids

  defp field(id, key) do
    case Map.get(@surface_types, id) do
      %{} = defn -> Map.get(defn, key)
      _other -> nil
    end
  end
end
