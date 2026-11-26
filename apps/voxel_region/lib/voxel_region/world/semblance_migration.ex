defmodule VoxelRegion.World.SemblanceMigration do
  @moduledoc """
  全局系统功能（魔法 v2 切片 4c，决策稿 `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md` Q4-6）：旧存档拟态的
  一次性迁移。

  切片 3 起施法不再建拟态，切片 4c 删除了拟态运行时（能量、寿命、弹道采样）；Hello 46 客户端也已看不到拟态记录。
  存档里仍可能留着 `thermal.semblances`（master / Hello 45 时代经正常施放产生）。World 恢复时（`World.init/1`）调用
  `migrate/1`：每个拟态按旧规则的剩余能量（显热 C·(T − T_amb) + 飞行中动能 + 发光余量 glow_w·(lifetime − age)，
  T_amb 取热环境 `ambient_kelvin`，与旧 `Magic.Semblance.stored_j/2` 同式）散入空气、记 `semblance_released_j`，
  再以一笔热事务删除 `semblances` 键。不转写成结构（Q4-6：不另设第二个运行时）。

  - 为什么一律散入空气：恢复时世界页未必驻留，旧规则里“落入接触格”需要读 canonical；旧的恢复路径
    （`Projectiles.settle_restored/1`）对在飞投射物同样散入空气。能量全部入账，不写任何格。
  - 已冻结的身体命中交付（`impact_delivery`）同样散解：恢复时 Scene 尚未接入，不重投。
  - 迁移之后运行时代码里不再出现 `semblances` 键；本模块是唯一例外，退出条件是确认生产与测试存档都已迁移（切片 8 合入前
    盘点）后删除本模块。

  可观测：`voxel_structure_migrated seq count released_j`（决策稿 §4.2）。
  """
  require Logger
  alias VoxelRegion.World.HeatCommit

  @doc "恢复后的 World 若仍带旧拟态表，就一次散解入账并写一笔热事务删除该键；否则原样返回。"
  def migrate(%{thermal: %{semblances: semblances} = thermal} = state) do
    ambient = thermal.config["ambient_kelvin"]
    released = semblances |> Enum.sort() |> Enum.map(fn {_id, s} -> stored_j(s, ambient) end) |> Enum.sum()

    thermal =
      thermal
      |> Map.delete(:semblances)
      |> Map.update(:semblance_released_j, released, &(&1 + released))

    next = HeatCommit.thermal_commit(%{state | thermal: thermal}, [])

    Logger.info(
      "voxel_structure_migrated seq=#{next.seq} count=#{map_size(semblances)} released_j=#{released} " <>
        "ids=#{inspect(semblances |> Map.keys() |> Enum.sort())}"
    )

    next
  end

  def migrate(state), do: state

  # 旧规则的剩余能量（J）：显热 + 飞行中动能 + 发光余量（旧 `Magic.Semblance.stored_j/2`，切片 4c 随拟态运行时删除）。
  defp stored_j(s, ambient) do
    s.capacity * (s.temperature_k - ambient) + s.kinetic_j + s.glow_w * max(s.lifetime_s - s.age_s, 0.0)
  end
end
