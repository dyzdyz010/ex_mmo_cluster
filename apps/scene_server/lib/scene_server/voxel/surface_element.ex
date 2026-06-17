defmodule SceneServer.Voxel.SurfaceElement do
  @moduledoc """
  单个表面元件的 truth 记录(形态轨 · 表面元件层 M2)。

  绑在一个宏格的一个面上(`{macro_index, face}` 唯一);**零体积**——不进 occupancy mask、不改宿主邻接
  /碰撞/面剔除(决策稿 D-2 不变量)。状态由 per-face `attribute_set_ref`/`tag_set_ref` 承载(氧化度/
  抛光度/亮灭),类型见 `SurfaceCatalog`,物理参与由类型借用的材料属性向量派生。

  字段:
    * `macro_index` 宿主宏格(0..4095) + `face`(:x_neg..:z_pos)= 唯一键;
    * `surface_type_id` SurfaceCatalog 类型;
    * `attribute_set_ref`/`tag_set_ref` per-face 动态状态引用(0 = 无);
    * `owner_actor_id` 放置者(0 = 系统/terrain 沉积,如 S4 锈渍)。
  """

  alias SceneServer.Voxel.SurfaceCatalog

  @max_u32 0xFFFF_FFFF
  @max_u63 9_223_372_036_854_775_807
  @max_macro_index 4095

  @enforce_keys [:macro_index, :face, :surface_type_id]
  defstruct macro_index: 0,
            face: :x_neg,
            surface_type_id: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0,
            owner_actor_id: 0

  @type t :: %__MODULE__{
          macro_index: 0..4095,
          face: atom(),
          surface_type_id: pos_integer(),
          attribute_set_ref: 0..0xFFFF_FFFF,
          tag_set_ref: 0..0xFFFF_FFFF,
          owner_actor_id: 0..9_223_372_036_854_775_807
        }

  @doc "构造并校验表面元件记录(坏记录 raise)。"
  @spec new(Enumerable.t()) :: t()
  def new(attrs), do: normalize!(Map.new(attrs))

  @doc "规范化 / 校验。macro_index∈0..4095、face 合法、surface_type 已知、refs u32、owner u63。"
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = element), do: element |> Map.from_struct() |> normalize!()

  def normalize!(attrs) when is_map(attrs) do
    macro_index = macro_index!(fetch(attrs, :macro_index, 0))
    face = face!(fetch(attrs, :face, :x_neg))
    surface_type_id = surface_type_id!(fetch(attrs, :surface_type_id, 0))

    %__MODULE__{
      macro_index: macro_index,
      face: face,
      surface_type_id: surface_type_id,
      attribute_set_ref: uint!(fetch(attrs, :attribute_set_ref, 0), @max_u32, :attribute_set_ref),
      tag_set_ref: uint!(fetch(attrs, :tag_set_ref, 0), @max_u32, :tag_set_ref),
      owner_actor_id: uint!(fetch(attrs, :owner_actor_id, 0), @max_u63, :owner_actor_id)
    }
  end

  @doc "规范排序键 `{macro_index, face_ordinal}`(canonical 排序用,保 wire/hash 稳定)。"
  @spec sort_key(t()) :: {0..4095, 0..5}
  def sort_key(%__MODULE__{macro_index: macro_index, face: face}) do
    {macro_index, SurfaceCatalog.face_ordinal(face)}
  end

  defp fetch(attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp macro_index!(value) when is_integer(value) and value >= 0 and value <= @max_macro_index,
    do: value

  defp macro_index!(value),
    do: raise(ArgumentError, "SurfaceElement: macro_index 须 0..4095,得 #{inspect(value)}")

  defp face!(value) do
    if SurfaceCatalog.valid_face?(value) do
      value
    else
      raise ArgumentError, "SurfaceElement: 非法 face #{inspect(value)}"
    end
  end

  defp surface_type_id!(value) when is_integer(value) do
    if SurfaceCatalog.known_surface_type?(value) do
      value
    else
      raise ArgumentError, "SurfaceElement: 未知 surface_type_id #{inspect(value)}"
    end
  end

  defp surface_type_id!(value),
    do: raise(ArgumentError, "SurfaceElement: surface_type_id 须整数,得 #{inspect(value)}")

  defp uint!(value, max, _field) when is_integer(value) and value >= 0 and value <= max, do: value

  defp uint!(value, max, field) do
    raise ArgumentError, "SurfaceElement: #{field} 须 0..#{max},得 #{inspect(value)}"
  end
end
