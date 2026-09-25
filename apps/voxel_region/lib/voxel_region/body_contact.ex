defmodule VoxelRegion.BodyContact do
  @moduledoc """
  全局系统功能（魔法首片增量 4，Voxim Docs/Magic.md §6）：角色身体与世界的接触换热——纯规则，不读 World。

  身体真值（核心 / 皮肤温度、伤病）在 Scene 的 `SceneServer.Body`；Scene 每秒把身体几何与皮肤温度报给 World，
  World 把皮肤当热内核外部节点 `{T_skin, 1, 1, C_skin, 0, 1e6, 0, 0, 0, true}`（暴露面积 0：空气对流由 Body 自算），
  按这里的接触导热连边，一次热提交后把交换热 `q = C_skin·(T_后 − T_前)` 回传 Scene。

  三类接触（同一身体可同时有多条）：
  - **脚下**：脚格（与施法留热同一约定：`{⌊x⌋, ⌊y + 0.5⌋ − 1, ⌊z⌋}`）是带热容的未细分实体宏格，且其温度偏离环境超过
    热容差时，鞋底串联该格法向半程：`G = A_sole / (R_sole + d / k)`，d = 0.5 m。环境温度的地面不进内核
    （与 Body 自算的空气换热同量级；只让有温差的接触进入活动集合，同 Docs/R8 §8 原则）。同一 `R_sole` 也用于
    Scene 身体的冻伤 / 烧伤剂量：脚底组织温度按核心 ↔ 地面经鞋底的稳态分压折算（`SceneServer.Body.Thermo`）。
  - **浸没**：脚所在列里与身体竖向区间 [脚, 脚 + 身高) 重叠的液体宏格，按浸没高度比例：
    `G = A_skin·(重叠 / 身高) / (R_wet + 1 / h_water)`。液体格按均温节点处理，身体在格内，不计半格传导。
  - **触碰拟态**：已落地拟态中心到身体胶囊轴线段的距离 ≤ 拟态半径 + 身体半径（拟态不是实体，可以走进去）：
    `G = A_touch / (R_touch + r / k_s)`，与拟态接触边同一串联式。

  参数（首片常量，待资产化）与依据：
  | 参数 | 值 | 依据 |
  |---|---|---|
  | 鞋底接触面积 | 0.03 m²（两脚） | 成人单脚掌着地面积约 0.015 m² |
  | 鞋底热阻 | 0.15 m²·K/W | 冬靴：约 1 cm 橡胶外底（k ≈ 0.16 W/(m·K)，0.06）+ 约 1 cm 毛毡 / EVA 内底（k ≈ 0.1，0.1），冬靴底 0.1–0.2 量级取中 |
  | 湿衣热阻 | 0.03 m²·K/W | 1 clo（0.155）浸湿后保温大部分丧失，取约五分之一；原创取值 |
  | 静水对流 | 100 W/(m²·K) | 人体静水浸没换热系数的常见量级（约 50–200）；原创取值 |
  | 触碰面积 | 0.01 m² | 手掌；原创取值 |
  | 触碰热阻 | 0 | 裸手 |
  """

  @params %{
    sole_m2: 0.03,
    sole_m2_k_per_w: 0.15,
    wet_m2_k_per_w: 0.03,
    water_w_per_m2_k: 100.0,
    touch_m2: 0.01,
    touch_m2_k_per_w: 0.0
  }

  @doc "接触参数（首片常量，待资产化）。"
  def params, do: @params

  @doc "脚下实体格：G = A_sole / (R_sole + d/k)（W/K）；k 为 0 时不导热。"
  def sole(k, half) when k > 0, do: @params.sole_m2 / (@params.sole_m2_k_per_w + half / k)
  def sole(_k, _half), do: 0.0

  @doc "浸没：皮肤面积按浸没高度比例，G = A·(重叠/身高) / (R_wet + 1/h)（W/K）。"
  def immersion(area, overlap, height),
    do: area * overlap / height / (@params.wet_m2_k_per_w + 1 / @params.water_w_per_m2_k)

  @doc "触碰拟态：G = A_touch / (R_touch + r / k_s)（W/K）。"
  def touch(radius, k) when k > 0, do: @params.touch_m2 / (@params.touch_m2_k_per_w + radius / k)
  def touch(_radius, _k), do: 0.0

  @doc "身体竖向区间 [脚, 脚 + 身高) 与液体 [格底, 格底 + 液位) 的重叠高度（m）。"
  def overlap(feet_y, height, cell_y, fill),
    do: max(0.0, min(feet_y + height, cell_y + fill) - max(feet_y, cell_y * 1.0))

  @doc "拟态（中心 c、半径 r）是否碰到身体胶囊（轴线段 脚 + 半径 → 脚 + 身高 − 半径，半径 rb）。"
  def touching?({cx, cy, cz}, r, {fx, fy, fz}, height, rb) do
    y = cy |> max(fy + rb) |> min(fy + height - rb)
    (cx - fx) ** 2 + (cy - y) ** 2 + (cz - fz) ** 2 <= (r + rb) ** 2
  end
end
