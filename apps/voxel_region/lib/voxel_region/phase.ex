defmodule VoxelRegion.Phase do
  @moduledoc """
  全局系统功能：水/冰当量（含雪）与玄武岩/熔岩的有限焓和完整度搬运。
  各相族以凝固相在目录转变温度处为零焓；潜热段恒温，整格完成后换材料。
  完整度为数量乘HP比例的广延量，流动、携带与再凝固不会免费修复。
  """

  def enabled?(material), do: Map.has_key?(material, "phase_peer_material_id")

  @doc "当前已实现的液态身份；相变能力仍由目录字段接纳。"
  def liquid?(material), do: material in [21,22]

  @doc "本轮明确支持的有向相变；雪融水后只重新凝固为冰。"
  def valid_pair?(material, peer), do: {material,peer} in [{4,21},{20,21},{21,20},{13,22},{22,13}]

  def energy(row, volume, material, ambient) do
    Map.get_lazy(row, :phase_energy_j, fn ->
      latent = if liquid?(row.material), do: material["latent_heat_per_macro_j"], else: 0.0
      volume * (latent + material["heat_capacity_per_macro"] *
        (Map.get(row, :temperature_kelvin, ambient) - material["phase_transition_kelvin"]))
    end)
  end

  def temperature(material, energy, volume, properties) do
    m = Map.fetch!(properties, material)
    sensible = if liquid?(material),
      do: max(0.0, energy - volume * m["latent_heat_per_macro_j"]),
      else: min(0.0, energy)
    m["phase_transition_kelvin"] + sensible / (volume * m["heat_capacity_per_macro"])
  end

  def material(material, energy, volume, properties) do
    latent = volume * properties[material]["latent_heat_per_macro_j"]
    cond do
      liquid?(material) and energy <= 0.0 -> properties[material]["phase_peer_material_id"]
      not liquid?(material) and energy >= latent -> properties[material]["phase_peer_material_id"]
      true -> material
    end
  end

  # 与数量内核共用同步通量，每阶段冻结来源，不能在两个阶段重复转移。
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
