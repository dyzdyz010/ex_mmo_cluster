defmodule SceneServer.Voxel.Reaction.Rule do
  @moduledoc """
  涌现反应规则(功能完善 · 反应层 R1)。

  数据化描述"什么条件下世界发生什么转变",由 `SceneServer.Voxel.Reaction.Engine` 对已提交 voxel
  truth 求值。两种规则(用户拍板"两者结合"):

    * `:phase_transition`(材料相变,阈值表驱动)——`from_material`(材料名)+ `condition`(场量算子
      阈值)成立 → 材料变 `to_material`。阈值可引 `MaterialCatalog` 属性名(如 `"melting_point"`,
      逐 cell 按 from 材料解析)或字面摄氏度。例:冰 + 温度 ≥ melting_point → 水。
    * `:tag_reaction`(标签反应,声明式)——`when_tags` 全含 + `condition` 成立 → `effect`(加/减 tag)。
      骨架阶段先定形,燃烧切片再全接。

  规则用**材料名/属性名**引用(稳定,不写裸 id),`new!/1` 在构造期校验材料名合法,坏规则编译即报错。
  """

  alias SceneServer.Voxel.MaterialCatalog

  @kinds [:phase_transition, :tag_reaction]
  @ops [:gte, :gt, :lte, :lt]

  @enforce_keys [:id, :kind]
  defstruct [
    :id,
    :kind,
    :from_material,
    :condition,
    :to_material,
    when_tags: [],
    effect: nil,
    priority: 0
  ]

  @type op :: :gte | :gt | :lte | :lt
  @type threshold :: {:material_threshold, String.t()} | {:celsius, number()}
  @type condition :: {:temperature, op(), threshold()}

  @type t :: %__MODULE__{
          id: atom(),
          kind: :phase_transition | :tag_reaction,
          from_material: atom() | nil,
          condition: condition() | nil,
          to_material: atom() | nil,
          when_tags: [atom()],
          effect: term() | nil,
          priority: integer()
        }

  @doc "合法 rule kind。"
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "合法条件算子。"
  @spec ops() :: [op()]
  def ops, do: @ops

  @doc "构造并校验反应规则,坏规则 raise(编译/启动期即暴露)。"
  @spec new!(Enumerable.t()) :: t()
  def new!(attrs) do
    attrs = Map.new(attrs)
    id = Map.fetch!(attrs, :id)
    kind = Map.fetch!(attrs, :kind)

    unless is_atom(id), do: raise(ArgumentError, "Rule: id 必须是 atom,得 #{inspect(id)}")
    unless kind in @kinds, do: raise(ArgumentError, "Rule: 非法 kind #{inspect(kind)}")

    rule = struct!(__MODULE__, attrs)
    validate!(rule)
    rule
  end

  defp validate!(%__MODULE__{kind: :phase_transition} = rule) do
    valid_material!(rule.from_material, "from_material")
    valid_material!(rule.to_material, "to_material")
    validate_condition!(rule.condition)
  end

  defp validate!(%__MODULE__{kind: :tag_reaction} = rule) do
    unless is_list(rule.when_tags) and rule.when_tags != [] do
      raise ArgumentError, "Rule(tag_reaction) #{inspect(rule.id)}: when_tags 须非空 list"
    end

    validate_condition!(rule.condition)
  end

  defp valid_material!(name, field) do
    unless is_atom(name) and not is_nil(MaterialCatalog.material_id(name)) do
      raise ArgumentError, "Rule: #{field} 非法材料名 #{inspect(name)}"
    end
  end

  defp validate_condition!({:temperature, op, threshold}) when op in @ops do
    case threshold do
      {:material_threshold, attr} when is_binary(attr) -> :ok
      {:celsius, v} when is_number(v) -> :ok
      other -> raise ArgumentError, "Rule: 非法 threshold #{inspect(other)}"
    end
  end

  defp validate_condition!(other) do
    raise ArgumentError, "Rule: 非法 condition #{inspect(other)}"
  end
end
