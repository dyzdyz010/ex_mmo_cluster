defmodule SceneServer.Voxel.Field.Provisioners.StructuralStress do
  @moduledoc """
  力学应力 provisioner(世界内容驱动场 provisioning 的**第 3 个**,电路 / 涌现之后)。

  chunk 内**存在失支撑的实心结构 cell**时,起一个 `[structural_stress]` region;
  `StructuralStressKernel` 逐 tick 把失支撑 cell 坍成 debris,链式收敛。结构稳定(全部
  连到地锚 / 已坍完)后,下次 sweep 探到**无失支撑** → `:inactive` 释放。

  ## 为何 active 谓词只取「有失支撑」(偏离决策稿 §2.6 的「或 有离地结构」)

  决策稿原拟「有失支撑 *或* 有离地结构即起」。但**离地 ≠ 失支撑**:一面经立柱连回
  地锚的墙,绝大多数 cell 离地却**完全有支撑**;若仅因「离地」起 region,它会**永久
  空转**(每 tick 算出失支撑=[] 却不释放,因释放靠 sweep 而非 kernel `:done`)。故
  active 谓词收紧为**仅「有失支撑」**——region 只在**真有东西要坍**时存在,坍完即由
  下次 sweep 释放。

  动态失支撑(如烧断承重梁后上方变悬空)由**块变更/field-commit 重 sweep**捕获:truth
  变更触发 sweep → detect 重算 → 新出现失支撑 → 起 region 坍塌(烧梁→坍塌链,见 step5)。

  ## AABB 与地锚

  v1 用**全 chunk AABB**(`{{0,0,0},{15,15,15}}`,同 ElectricCircuit):保证含地锚层
  (local y=0),且 `StructuralSupport` 逐 cell O(1) header 访问 → 单次分析 O(chunk 体积)
  而非 O(n²)。区域**仅在坍塌期间** tick(数 tick 收敛后释放),非常驻负载。更紧的局部
  AABB(随结构 bbox,min_y 钉 0)留 v2 优化。

  见 `docs/2026-06-23-mechanical-stress-structural-collapse.md`、[[field-provisioning-framework]]。
  """

  @behaviour SceneServer.Voxel.Field.FieldProvisioner

  alias SceneServer.Voxel.Field.Kernels.StructuralStressKernel
  alias SceneServer.Voxel.Field.StructuralSupport
  alias SceneServer.Voxel.Storage

  # 全 chunk AABB:含地锚层 y=0;StructuralSupport O(1) header 访问 → 单次 O(体积)。
  @stress_aabb {{0, 0, 0}, {15, 15, 15}}

  @impl true
  def telemetry_event, do: "voxel_structural_stress_provision"

  @impl true
  def source_key(%{logical_scene_id: scene_id, chunk_coord: chunk_coord}) do
    {:structural_stress, scene_id, chunk_coord}
  end

  @impl true
  def detect(%{storage: %Storage{} = storage, chunk_coord: chunk_coord}) do
    case StructuralSupport.unsupported_cells(storage, @stress_aabb) do
      [] ->
        {:inactive, :no_unsupported_structure, %{unsupported_count: 0}}

      unsupported ->
        attrs = %{
          chunk_coord: chunk_coord,
          aabb: @stress_aabb,
          kernels: [%{id: :structural_stress, module: StructuralStressKernel, opts: %{}}],
          max_ticks: nil
        }

        {:active, attrs, %{unsupported_count: length(unsupported)}}
    end
  end

  def detect(_context), do: {:inactive, :no_storage, %{unsupported_count: 0}}

  @doc "活性谓词:chunk 是否含失支撑实心结构(有则需起 stress region)。"
  @spec unsupported_structure?(Storage.t()) :: boolean()
  def unsupported_structure?(%Storage{} = storage) do
    StructuralSupport.unsupported_cells(storage, @stress_aabb) != []
  end

  def unsupported_structure?(_storage), do: false
end
