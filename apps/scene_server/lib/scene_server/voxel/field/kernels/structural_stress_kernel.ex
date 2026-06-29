defmodule SceneServer.Voxel.Field.Kernels.StructuralStressKernel do
  @moduledoc """
  力学应力 · 结构支撑 kernel(第 5 个正交物理系统)。

  每 tick 用 `StructuralSupport` 从地锚(本 chunk 底层 local y=0 的实心结构 cell)做
  连通可达性分析,对 region AABB 内**失支撑**的实心结构 cell 发 `{:collapse_block, …}`
  效果——经 `SystemActor`/`ChunkProcess` 清掉该 cell(归零毁块 → ChunkDelta,客户端
  `debris_render` 渲成落块)。和 `ReactionKernel` 同范式:**不读/写 field 层**
  (`required_layers/1` 返回 `[]`),纯发效果改 truth。

  **链式收敛**:`FieldTickWorker` 每 tick 取**新鲜 storage**(`storage_fn`),坍掉一层后
  下一 tick 的支撑分析自然发现新失支撑层 → 逐 tick 去一层,O(结构高度) tick 后稳定
  (无失支撑 → `:done`)。region 的实际释放由 `StructuralStress` provisioner 下次 sweep
  探到「全坐地、无悬空」时 `:inactive` 完成。

  **安全阀**(EMG-7):`max_effects_per_tick` 封顶单 tick 坍塌数,防一帧塌整城;余下失
  支撑 cell 下个 tick 继续。

  见 `docs/2026-06-23-mechanical-stress-structural-collapse.md`、[[emergence-reaction-layer]]。
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext, ModelCard, StructuralSupport}

  # 单 tick 最多坍塌的 cell 数(防一帧塌整城)。链式坍塌跨 tick 收敛。
  @default_max_effects_per_tick 64

  @impl true
  def kernel_id, do: :structural_stress

  # 纯发效果改 truth,不拥有 field 层(同 ReactionKernel 范式)。
  @impl true
  def required_layers(_opts), do: []

  @impl true
  def model_card do
    ModelCard.new!(
      kernel_id: :structural_stress,
      fidelity_class: :qualitative,
      model_version: 1,
      safety_valve: %{
        type: :max_effects_per_tick,
        max_effects_per_tick: @default_max_effects_per_tick,
        note: "单 tick 坍塌数封顶防一帧塌整城;链式坍塌跨 tick 收敛;无失支撑 → :done"
      },
      description: "结构支撑连通分析(从地锚 BFS)→ 失支撑实心结构 cell 坍塌成 debris(:collapse_block,复用归零毁块路径)",
      assumptions: [
        "chunk-local 地锚(本 chunk 底层 y=0)",
        "二元 supported/unsupported(无应力幅值,留 v2)",
        "macro 级面相邻支撑(不需微接触精度)"
      ]
    )
  end

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{storage: storage}, opts) when is_map(opts) do
    case StructuralSupport.unsupported_cells(storage, region.aabb) do
      [] ->
        # 收敛:region 内全部有支撑 → 本 kernel 无事可做。
        {:done, region, []}

      unsupported ->
        effects =
          unsupported
          |> Enum.take(max_effects_per_tick(opts))
          |> Enum.map(fn macro_index ->
            {:collapse_block, %{macro_index: macro_index, source: :structural_collapse}}
          end)

        {:cont, region, effects}
    end
  end

  def tick(%FieldRegion{} = region, _context, _opts), do: {:done, region, []}

  defp max_effects_per_tick(opts) do
    case option(opts, :max_effects_per_tick, @default_max_effects_per_tick) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_max_effects_per_tick
    end
  end

  defp option(opts, key, default) do
    cond do
      Map.has_key?(opts, key) -> Map.fetch!(opts, key)
      Map.has_key?(opts, Atom.to_string(key)) -> Map.fetch!(opts, Atom.to_string(key))
      true -> default
    end
  end
end
