defmodule VoxelRegion.Phase do
  @moduledoc """
  Global system: finite Water/Ice enthalpy and integrity transport.
  Energy zero is Ice at the published transition temperature. The latent interval
  stores energy at that temperature; canonical material changes only when the
  entire cell finishes changing phase. No quantity is inferred from geometry.
  Integrity is an extensive quantity (inventory quanta times retained HP ratio),
  so mixing, carrying, and refreezing cannot repair damaged ice for free.
  """

  def enabled?(material), do: Map.has_key?(material, "phase_peer_material_id")

  def energy(row, volume, material, ambient) do
    Map.get_lazy(row, :phase_energy_j, fn ->
      latent = if row.material == 21, do: material["latent_heat_per_macro_j"], else: 0.0
      volume * (latent + material["heat_capacity_per_macro"] *
        (Map.get(row, :temperature_kelvin, ambient) - material["phase_transition_kelvin"]))
    end)
  end

  def temperature(material, energy, volume, properties) do
    m = Map.fetch!(properties, material)
    sensible = if material == 21,
      do: max(0.0, energy - volume * m["latent_heat_per_macro_j"]),
      else: min(0.0, energy)
    m["phase_transition_kelvin"] + sensible / (volume * m["heat_capacity_per_macro"])
  end

  def material(material, energy, volume, properties) do
    latent = volume * properties[material]["latent_heat_per_macro_j"]
    cond do
      material == 21 and energy <= 0.0 -> 20
      material == 20 and energy >= latent -> 21
      true -> material
    end
  end

  # Same synchronous transfers as the quantity kernel, with source values frozen
  # at each stage. Moving through two stages must not move either field twice.
  def transport(values, quantities, transfers) do
    Enum.reduce(transfers, values, fn {from, to, units}, out ->
      {energy, integrity} = Map.fetch!(values, from)
      ratio = units / Map.fetch!(quantities, from)
      moved = {energy * ratio, integrity * ratio}
      out |> add(from, scale(moved, -1)) |> add(to, moved)
    end)
  end

  def add(values, key, {energy, integrity}) do
    Map.update(values, key, {energy, integrity}, fn {e, i} -> {e + energy, i + integrity} end)
  end
  def scale({energy, integrity}, factor), do: {energy * factor, integrity * factor}
end
