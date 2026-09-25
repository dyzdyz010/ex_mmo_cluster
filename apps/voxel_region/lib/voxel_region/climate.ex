defmodule VoxelRegion.Climate do
  @moduledoc """
  全局系统功能：气候查询的唯一入口——“某格的空气是什么状态”。热模拟里一切按位置取的环境温度（空气换热、对天辐射、
  未记录格默认温度、相变天然温度、静止判据、显热参考）与 Scene 身体的空气温度 / 风速都只经这里查询。

  `config` 是热环境配置（`DA_ThermalEnvironment` 发布的 environment.json，经 World 快照 `property_context` 到达 Scene）。
  当前唯一提供者是资产里的静态“气候区”：

      "climate_zones": [{"min": [x0, z0], "max": [x1, z1], "ambient_kelvin": K, "wind_mps": v}]

  canonical 宏格 x/z 闭矩形、全高，列表在前者优先；`wind_mps` 可选（缺省 0 = 静止空气）。区外（或无该字段）为全局
  `ambient_kelvin`、风速 0。

  ## 给未来真实气候系统（时变提供者）的契约

  1. **查询面不变**：提供者只替换 `at/2`、`region/2` 背后的取值；消费者不直接读配置里的气候字段。
  2. **变化必须通知**：热模拟只在活动集合里推进，偏离环境超过容差的记录格才会被拉入。提供者改变某区的空气温度后，
     必须让 World 重新派生活动种子并唤醒热提交（World 内 `rebuild_thermal_work/1`：按新环境重算偏离的记录格，
     非空即置活动；冷启动已经走这条路）。不通知则静止格会停在旧温度。未记录格没有独立温度——它们按定义就在所在区的
     空气温度，随提供者即时改变，不产生能量账目（大气是无限热库）。
  3. **区边界是绝热切断**：两格 `region/2` 不同即热分区不同，导热、辐射视线、拟态接触都不跨（与受保护区域同为理想
     绝热镜面）。否则两侧各在自己环境温度的未记录格会在两个无限热库之间持续导热、永不落定。时变提供者若给出连续
     温度场，必须仍给出离散分区（或同等的静止判据），不能让相邻静止格之间出现持续温差流。
  4. **冷重启以提供者状态为准**：配置里的气候由资产（将来是气候状态）决定，不从存档回放；世界存档只保存格的记录温度。
  5. **账目参考不是气候**：无位置的库存相态、拟态账与报价以全局 `ambient_kelvin` 为固定参考温度，不随气候变化。

  风速目前只作用于身体对流（`SceneServer.Body.Thermo`）；格与空气的换热系数 `environment_w_per_m2_k` 仍为常数，
  不随风速变化（未建模）。
  """

  @type air :: %{air_k: number(), wind_mps: number()}

  @doc "格所在位置的空气：温度 K 与风速 m/s。区外（或无气候区）为全局 `ambient_kelvin`、风速 0。"
  @spec at(map(), {integer(), integer(), integer()}) :: air()
  def at(config, cell) do
    case region(config, cell) do
      nil -> %{air_k: config["ambient_kelvin"], wind_mps: 0}
      index -> zone_air(Enum.at(config["climate_zones"], index))
    end
  end

  @doc "格所在位置的空气温度 K（`at/2` 的温度分量；热模拟的热路径只要这一项）。"
  @spec air_k(map(), {integer(), integer(), integer()}) :: number()
  def air_k(config, cell), do: at(config, cell).air_k

  @doc "格所在气候区的下标；区外（或无气候区）为 nil。两格下标不同即热分区不同（绝热切断，见契约 3）。"
  def region(config, {x, _y, z}) do
    config
    |> Map.get("climate_zones", [])
    |> Enum.find_index(fn %{"min" => [x0, z0], "max" => [x1, z1]} -> x >= x0 and x <= x1 and z >= z0 and z <= z1 end)
  end

  @doc "热环境是否声明了气候区。"
  def zoned?(config), do: Map.get(config, "climate_zones", []) != []

  @doc "气候区字段合法：列表，每项整数闭矩形（min ≤ max）、正区温、可选非负风速；缺省视为空列表。"
  def valid?(config) do
    case Map.get(config, "climate_zones", []) do
      zones when is_list(zones) ->
        Enum.all?(zones, fn
          %{"min" => [x0, z0], "max" => [x1, z1], "ambient_kelvin" => k} = zone ->
            wind = Map.get(zone, "wind_mps", 0)

            Enum.all?([x0, z0, x1, z1], &is_integer/1) and x0 <= x1 and z0 <= z1 and is_number(k) and k > 0 and
              is_number(wind) and wind >= 0

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  defp zone_air(zone), do: %{air_k: zone["ambient_kelvin"], wind_mps: Map.get(zone, "wind_mps", 0)}
end
