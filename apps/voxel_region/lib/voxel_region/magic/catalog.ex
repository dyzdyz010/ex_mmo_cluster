defmodule VoxelRegion.Magic.Catalog do
  @moduledoc """
  全局系统功能（魔法增量 1）：魔法目录——施法者常数、上限、成本参数与符号清单的唯一服务端读取入口。

  作者入口是 Voxim 的 `UVoxelMagicCatalogAsset`（`DA_MagicCatalogV1`），Publish 产出不可变
  `Content/Voxel/Magic/Published/<sha256>.json`；服务端在 World 启动时读取部署进来的同一文件
  （`:magic_catalog_path`），digest = 文件字节 sha256，与属性目录同法（`VoxelRegion.Damage.load/1`）。
  部署文件是信任边界：结构在这里校验一次，之后 `Program` 与 `Cost` 直接消费。
  `max_steps`、`draw_max_j` 属于共享目录的完整结构，这里只校验存在且为正；执行器接受的程序形态由
  `Program` 限定（至多 2 步），取能上限由 `energy.draw` 的槽上限约束，二者暂无服务端调用方。
  `max_semblances` 是每名施法者同时存在的拟态上限（增量 2）。
  符号只接受服务端已实现的动词（增量 1：`energy.draw`、`act.heat`；增量 2：`form.semblance`、`act.throw`、
  `act.dispel`），目录里出现未实现动词即拒绝启动，运行时不再为未知动词设分支。槽可带 `"integer": true`
  （枚举槽，如拟态形状），此时取值必须是整数。含 `form.semblance` 的目录必须给出 `semblance` 段：拟态的
  比热（J/(kg·K)，热容 = 质量 × 比热）与导热率（W/(m·K)），与材料共用同一属性轴与单位。`reading`（Sevara 读法占位）与 `presets` 名称只服务客户端，不参与判定；
  预设程序在这里按同一 `Program.validate/2` 校验，保证发布的预设都可施放。
  """

  alias VoxelRegion.Magic.Program

  # 服务端已实现的动词及其类别；新动词随其实现一起加入。
  @implemented %{"energy.draw" => "act", "act.heat" => "act", "form.semblance" => "form",
    "act.throw" => "act", "act.dispel" => "act"}

  @doc "读取并校验已发布目录文件；返回带 digest 的不可变值。"
  def load(path), do: decode(File.read!(path))

  @doc "目录字节 → 目录值；字节即发布物，digest 取其 sha256。"
  def decode(bytes) do
    data = Jason.decode!(bytes)
    true = data["version"] == 1

    caster = data["caster"]
    true = positive?(caster["capacity_j"]) and positive?(caster["coherence"])
    true = positive?(caster["draw_efficiency"]) and caster["draw_efficiency"] <= 1

    limits = data["limits"]

    true =
      Enum.all?(
        ~w(max_steps max_semblances range_m local_domain_m cast_interval_ms program_max_bytes draw_max_j),
        &positive?(limits[&1])
      )

    true = limits["local_domain_m"] <= limits["range_m"]

    cost = data["cost"]
    true = positive?(cost["e0_j"]) and positive?(cost["e_ref_j"]) and positive?(cost["alpha"])

    symbols =
      Map.new(data["symbols"], fn s ->
        true = @implemented[s["id"]] == s["category"] and positive?(s["weight"])
        true = length(Enum.uniq_by(s["slots"], & &1["name"])) == length(s["slots"])

        slots =
          Map.new(s["slots"], fn slot ->
            true = is_binary(slot["name"]) and is_number(slot["min"]) and slot["max"] >= slot["min"]
            {slot["name"], {slot["min"], slot["max"]}}
          end)

        integer = for slot <- s["slots"], slot["integer"] == true, do: slot["name"]
        {s["id"], %{weight: s["weight"], target: s["target"], slots: slots, integer: integer}}
      end)

    true = map_size(symbols) == length(data["symbols"])

    semblance =
      if Map.has_key?(symbols, "form.semblance") do
        section = data["semblance"]
        true = positive?(section["specific_heat_j_per_kg_k"]) and positive?(section["thermal_conductivity_w_per_m_k"])
        %{specific_heat: section["specific_heat_j_per_kg_k"] * 1.0,
          conductivity: section["thermal_conductivity_w_per_m_k"] * 1.0}
      end

    catalog = %{
      digest: :crypto.hash(:sha256, bytes),
      capacity_j: caster["capacity_j"] * 1.0,
      coherence: caster["coherence"] * 1.0,
      draw_efficiency: caster["draw_efficiency"] * 1.0,
      range_m: limits["range_m"] * 1.0,
      local_domain_m: limits["local_domain_m"] * 1.0,
      cast_interval_us: round(limits["cast_interval_ms"] * 1000),
      max_semblances: limits["max_semblances"],
      program_max_bytes: limits["program_max_bytes"],
      e0_j: cost["e0_j"] * 1.0,
      e_ref_j: cost["e_ref_j"] * 1.0,
      alpha: cost["alpha"] * 1.0,
      symbols: symbols,
      semblance: semblance
    }

    true = Enum.all?(data["presets"], &match?({:ok, _}, Program.validate(&1["program"], catalog)))
    catalog
  end

  defp positive?(value), do: is_number(value) and value > 0
end
