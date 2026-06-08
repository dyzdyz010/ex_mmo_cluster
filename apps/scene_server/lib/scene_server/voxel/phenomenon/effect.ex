defmodule SceneServer.Voxel.Phenomenon.Effect do
  @moduledoc """
  Small constructors for phenomenon effects.

  Phenomenon rules do not mutate chunk truth directly. They return these
  structured effects and the owning `ChunkProcess` decides whether each write is
  accepted.
  """

  @type t ::
          {:emit_observe, String.t(), map()}
          | {:write_voxel_attribute, map()}
          | {:transform_voxel_material, map()}
          | {:clear_voxel_cell, map()}
          | {:apply_structural_damage, map()}
          | {:upsert_phenomenon_instance, map()}
          | {:complete_phenomenon_instance, map()}

  @doc "Builds a raw attribute write effect for a single macro cell."
  @spec write_voxel_attribute(non_neg_integer(), atom() | String.t(), integer(), map()) :: t()
  def write_voxel_attribute(macro_index, attribute, raw_value, attrs \\ %{})
      when is_integer(macro_index) and is_integer(raw_value) and is_map(attrs) do
    {:write_voxel_attribute,
     attrs
     |> Map.put(:macro_index, macro_index)
     |> Map.put(:attribute, attribute)
     |> Map.put(:raw_value, raw_value)}
  end

  @doc "Builds a material transition effect for a solid macro cell."
  @spec transform_voxel_material(non_neg_integer(), pos_integer(), map()) :: t()
  def transform_voxel_material(macro_index, material_id, attrs \\ %{})
      when is_integer(macro_index) and is_integer(material_id) and material_id > 0 and
             is_map(attrs) do
    {:transform_voxel_material,
     attrs
     |> Map.put(:macro_index, macro_index)
     |> Map.put(:material_id, material_id)}
  end

  @doc "Builds a cell clear effect for materials that burn away completely."
  @spec clear_voxel_cell(non_neg_integer(), map()) :: t()
  def clear_voxel_cell(macro_index, attrs \\ %{})
      when is_integer(macro_index) and is_map(attrs) do
    {:clear_voxel_cell, Map.put(attrs, :macro_index, macro_index)}
  end

  @doc """
  Builds an object-boundary structural damage effect for one macro cell.

  The owning `ChunkProcess` resolves voxel owner refs and routes damage to
  `ObjectRegistry`; phenomenon rules never mutate object truth directly.
  """
  @spec apply_structural_damage(non_neg_integer(), map()) :: t()
  def apply_structural_damage(macro_index, attrs \\ %{})
      when is_integer(macro_index) and is_map(attrs) do
    {:apply_structural_damage, Map.put(attrs, :macro_index, macro_index)}
  end

  @doc "Builds an authority-owned phenomenon instance upsert effect."
  @spec upsert_phenomenon_instance(atom() | String.t(), non_neg_integer(), map()) :: t()
  def upsert_phenomenon_instance(kind, macro_index, attrs \\ %{})
      when (is_atom(kind) or is_binary(kind)) and is_integer(macro_index) and is_map(attrs) do
    {:upsert_phenomenon_instance,
     attrs
     |> Map.put(:kind, kind)
     |> Map.put(:macro_index, macro_index)}
  end

  @doc "Builds an authority-owned phenomenon instance completion effect."
  @spec complete_phenomenon_instance(atom() | String.t(), non_neg_integer(), map()) :: t()
  def complete_phenomenon_instance(kind, macro_index, attrs \\ %{})
      when (is_atom(kind) or is_binary(kind)) and is_integer(macro_index) and is_map(attrs) do
    {:complete_phenomenon_instance,
     attrs
     |> Map.put(:kind, kind)
     |> Map.put(:macro_index, macro_index)}
  end

  @doc "Builds an observe-only event effect."
  @spec emit_observe(String.t(), map()) :: t()
  def emit_observe(event, fields) when is_binary(event) and is_map(fields) do
    {:emit_observe, event, fields}
  end
end
