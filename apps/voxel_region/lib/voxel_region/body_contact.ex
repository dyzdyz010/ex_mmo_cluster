defmodule VoxelRegion.BodyContact do
  @moduledoc """
  全局系统功能（魔法首片增量 4，Voxim Docs/Magic.md §6）：角色身体与世界的接触换热——纯规则，不读 World。

  身体真值（核心 / 皮肤 / 局部接触组织块温度、伤病）在 Scene 的 `SceneServer.Body`；Scene 每秒把身体几何、皮肤温度与热容、
  组织块温度 / 热容 / 组织块-皮肤导热报给 World。World 把皮肤与组织块当热内核的两个外部节点（暴露面积 0：空气对流由 Body
  自算），两者之间一条内部边，按这里的接触导热连边；一段演进后把 `q = C_skin·ΔT_skin + C_tissue·ΔT_tissue`（经接触边进身体
  的热）与其中存进组织块的 `tissue_j = C_tissue·ΔT_tissue` 回传 Scene。烧伤 / 冻伤剂量读组织块的演化温度。

  三类接触（同一身体可同时有多条）：
  - **脚下**（接组织块）：脚格（与施法留热同一约定：`{⌊x⌋, ⌊y + 0.5⌋ − 1, ⌊z⌋}`）是带热容的未细分实体宏格，且其温度偏离
    环境超过热容差时，鞋底串联该格法向半程：`G = A_sole / (R_sole + d / k)`，d = 0.5 m。环境温度的地面不进内核
    （只让有温差的接触进入活动集合，同 Docs/R8 §8 原则）——所以寒区里处于区温的地面不冷却组织块（已知缺口）。
  - **浸没**（接皮肤）：脚所在列里与身体竖向区间 [脚, 脚 + 身高) 重叠的液体宏格，按浸没高度比例：
    `G = A_skin·(重叠 / 身高) / (R_wet + 1 / h_water)`。液体格按均温节点处理，身体在格内，不计半格传导。浸没是可达全身的
    分布接触，皮肤节点本身就是被浸的那层组织；若改接 0.03 m² 的组织块，全身 45 W/K 的换热会被组织块-皮肤导热（约 0.2–1.3 W/K）
    卡住，冷水就冷不了身体。
  - **触碰拟态**（接组织块）：已落地拟态中心到身体胶囊轴线段的距离 ≤ 拟态半径 + 身体半径（拟态不是实体，可以走进去）：
    `G = A_touch / (R_touch + r / k_s)`，与拟态接触边同一串联式。

  参数（首片常量，待资产化）与依据：
  | 参数 | 值 | 依据 |
  |---|---|---|
  | 鞋底接触面积 | 0.03 m²（两脚） | 成人单脚掌着地面积约 0.015 m² |
  | 鞋底热阻 | 0.15 m²·K/W | 冬靴：约 1 cm 橡胶外底（k ≈ 0.16 W/(m·K)，0.06）+ 约 1 cm 毛毡 / EVA 内底（k ≈ 0.1，0.1），冬靴底 0.1–0.2 量级取中 |
  | 湿衣热阻 | 0.03 m²·K/W | 浸没在水里的 1 clo 衣物：1 clo（0.155）浸透后约剩 19%；与水边界层合计 0.04 m²·K/W ≈ 0.26 clo，略高于 Nunneley, Wissler & Allan 1985（PMID 4084171）的浸没衣物总热阻 0.06–0.23 clo 上端（常规衣物取上端）。只用于浸没边；空气中的湿衣由 `SceneServer.Body` 自算（Bröde 2008 保温损失 16% + 衣面蒸发） |
  | 静水对流 | 100 W/(m²·K) | Boutelier et al. 1977（doi:10.1152/jappl.1977.42.1.93）：静水 43–54，流动水 h = 272.9·v^0.5（冷水寒战时 497.1·v^0.65），0.1–0.15 m/s 约 86–150；Hayes & Cohen 以裸体浸没 0.06 clo（≈ 107 W/(m²·K)）计。取 100 |
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
