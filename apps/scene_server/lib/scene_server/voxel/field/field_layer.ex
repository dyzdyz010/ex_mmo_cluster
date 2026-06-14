defmodule SceneServer.Voxel.Field.FieldLayer do
  # PERS-5:derived(密集场数组,不落盘)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :derived

  @moduledoc """
  Phase 6 局部场:chunk 内 macro cell 场层。

  **梯队2 step2.7c(BND-1):场层本体常驻 Rust `ResourceArc<FieldLayerSim>`。** FieldLayer 退化为
  **句柄 + 元数据**:`cell_sim`(Rust 资源 reference)持稀疏 delta;`baseline`/`threshold`/
  `quantization` 元数据留 Elixir(避免读元数据也走 NIF)。所有 cell 读写经
  `SceneServer.Native.FieldKernel` 的 `cell_sim_*` NIF,**计算热路径数据不再每 tick 进出序列化**。

  **语义变更(原子 flip)**:FieldLayer 从"不可变值"变为"可变句柄"——`put`/`put_delta` **原地改
  cell_sim 并返回同句柄 layer**(调用方 `layer = put(layer, ..)` 的 rebind 仍成立;同一 cell_sim 的
  两个 FieldLayer 引用共享可变态)。`FieldRegion.new` 为每 field_type 预建唯一句柄,kernel
  orchestration 的顺序 mutation 与句柄语义对齐。

  设计要点:
    * 一个 FieldLayer 对应单一 field type;层内只保存相对 `baseline` 的稀疏 delta。
    * temperature 层可 `quantization: :integer`;wire codec 仍按 f32 发 active value。
    * `active_cells/2,3` 供 codec 抽稀疏快照(经 NIF 读 cell_sim active 缓冲)。
  """

  alias SceneServer.Native.FieldKernel

  @cell_count 4096
  @default_baseline 0.0
  @default_threshold 0.0001
  @default_quantization :float

  defstruct cell_sim: nil,
            baseline: @default_baseline,
            threshold: @default_threshold,
            quantization: @default_quantization

  @type quantization :: :float | :integer
  @type t :: %__MODULE__{
          cell_sim: reference() | nil,
          baseline: number(),
          threshold: number(),
          quantization: quantization()
        }

  @doc "Returns a fresh sparse FieldLayer backed by a Rust `ResourceArc<FieldLayerSim>`."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    quantization = Keyword.get(opts, :quantization, @default_quantization)

    unless quantization in [:float, :integer] do
      raise ArgumentError,
            "FieldLayer.new/1: unknown quantization #{inspect(quantization)}; expected :float or :integer"
    end

    baseline = quantize(Keyword.get(opts, :baseline, @default_baseline), quantization)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    %__MODULE__{
      cell_sim:
        FieldKernel.cell_sim_new(baseline * 1.0, threshold * 1.0, Atom.to_string(quantization)),
      baseline: baseline,
      threshold: threshold,
      quantization: quantization
    }
  end

  @doc "Total cell count per layer (always 4096 in v1)."
  @spec cell_count() :: 4096
  def cell_count, do: @cell_count

  @doc "Reads the absolute value at the given macro_index (0..4095)。"
  @spec get(t(), 0..4095) :: number()
  def get(%__MODULE__{} = layer, macro_index)
      when is_integer(macro_index) and macro_index >= 0 and macro_index < @cell_count do
    cast_value(FieldKernel.cell_sim_get(layer.cell_sim, macro_index), layer.quantization)
  end

  @doc "Reads the stored delta from baseline at the given macro_index。"
  @spec get_delta(t(), 0..4095) :: number()
  def get_delta(%__MODULE__{} = layer, macro_index)
      when is_integer(macro_index) and macro_index >= 0 and macro_index < @cell_count do
    cast_value(get(layer, macro_index) - layer.baseline, layer.quantization)
  end

  @doc "Writes an absolute value at the given macro_index。**原地改 cell_sim,返回同句柄 layer。**"
  @spec put(t(), 0..4095, number()) :: t()
  def put(%__MODULE__{} = layer, macro_index, value)
      when is_integer(macro_index) and macro_index >= 0 and macro_index < @cell_count and
             is_number(value) do
    :ok = FieldKernel.cell_sim_put(layer.cell_sim, macro_index, value * 1.0)
    layer
  end

  @doc "Writes a delta from baseline at the given macro_index。**原地改,返回同句柄 layer。**"
  @spec put_delta(t(), 0..4095, number()) :: t()
  def put_delta(%__MODULE__{} = layer, macro_index, delta)
      when is_integer(macro_index) and macro_index >= 0 and macro_index < @cell_count and
             is_number(delta) do
    put(layer, macro_index, layer.baseline + delta)
  end

  @doc """
  Returns `[{macro_index, value}]` for cells whose stored `|delta|` exceeds `epsilon`,
  filtered to the cells contained in `aabb`(经 NIF 读 cell_sim active 缓冲)。
  """
  @spec active_cells(t(), {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}}, number() | nil) ::
          [{0..4095, number()}]
  def active_cells(layer, aabb, epsilon \\ nil)

  def active_cells(%__MODULE__{} = layer, aabb, nil) do
    FieldKernel.cell_sim_active_cells(layer.cell_sim, aabb, layer.threshold * 1.0)
  end

  def active_cells(%__MODULE__{} = layer, aabb, epsilon) when is_number(epsilon) do
    FieldKernel.cell_sim_active_cells(layer.cell_sim, aabb, epsilon * 1.0)
  end

  defp quantize(value, :float), do: value * 1.0
  defp quantize(value, :integer), do: round(value)

  # NIF 始终回 f64;:integer 层按整数语义还原(与旧纯 Elixir 路径一致)。
  defp cast_value(value, :float), do: value * 1.0
  defp cast_value(value, :integer), do: round(value)
end
