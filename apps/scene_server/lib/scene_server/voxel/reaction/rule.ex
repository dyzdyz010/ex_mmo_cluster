defmodule SceneServer.Voxel.Reaction.Rule do
  @moduledoc """
  涌现反应规则(功能完善 · 反应层 R1 起,R5a 泛化 tag_reaction)。

  数据化描述"什么条件下世界发生什么转变",由 `SceneServer.Voxel.Reaction.Engine` 对已提交 voxel
  truth 求值。两种规则(用户拍板"两者结合"):

    * `:phase_transition`(材料相变,阈值表驱动)——`from_material` + `condition` 成立 → 材料变
      `to_material`。例:冰 + 温度 ≥ melting_point → 水。
    * `:tag_reaction`(标签/状态反应,声明式)——`require_tags` 全含 + `forbid_tags` 全不含 +
      `condition`(可空=只看 tag)成立 → 物化 `effects`(一组效果)。例(燃烧):
      ignite(forbid [:burning] + 温度≥ignition → add :burning)/ burn(require [:burning] → 注焦耳 +
      推进 burn_progress)/ burn_out(require [:burning] + burn_progress≥1 → 变 ash + 去 :burning)。

  `condition` 形如 `{field, op, threshold}`,`field` ∈ `:temperature`/`:burn_progress`;`op` ∈
  `:gte`/`:gt`/`:lte`/`:lt`;`threshold` ∈ `{:material_threshold, attr_name}`(逐 cell 按 from 材料解析)/
  `{:celsius, v}`/`{:value, v}`(比率等无量纲)。`effects` 模板见 `@effect_kinds`。

  规则用**材料名/属性名/tag 名**引用(稳定,不写裸 id),`new!/1` 构造期校验,坏规则编译即报错。
  """

  alias SceneServer.Voxel.MaterialCatalog

  @kinds [:phase_transition, :tag_reaction]
  @ops [:gte, :gt, :lte, :lt]
  @condition_fields [:temperature, :burn_progress]
  @effect_kinds [:add_tag, :remove_tag, :emit_heat_joules, :advance_attribute, :transform]

  @enforce_keys [:id, :kind]
  defstruct [
    :id,
    :kind,
    :from_material,
    :condition,
    :to_material,
    # Optional material filter for `:tag_reaction` rules: when set, the rule only
    # applies to cells of this material (device-specific behaviour, e.g. a
    # `:powered` heater vs a `:powered` door). nil = any material.
    :material,
    require_tags: [],
    forbid_tags: [],
    effects: [],
    priority: 0
  ]

  @type op :: :gte | :gt | :lte | :lt
  @type threshold ::
          {:material_threshold, String.t()} | {:celsius, number()} | {:value, number()}
  @type condition :: {:temperature | :burn_progress, op(), threshold()} | nil

  @type t :: %__MODULE__{
          id: atom(),
          kind: :phase_transition | :tag_reaction,
          from_material: atom() | nil,
          condition: condition(),
          to_material: atom() | nil,
          material: atom() | nil,
          require_tags: [atom()],
          forbid_tags: [atom()],
          effects: [tuple()],
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
    validate_condition!(rule.condition, required: true)
  end

  defp validate!(%__MODULE__{kind: :tag_reaction} = rule) do
    valid_tag_list!(rule.require_tags, "require_tags")
    valid_tag_list!(rule.forbid_tags, "forbid_tags")
    validate_material_filter!(rule.material)
    validate_condition!(rule.condition, required: false)

    unless is_list(rule.effects) and rule.effects != [] do
      raise ArgumentError, "Rule(tag_reaction) #{inspect(rule.id)}: effects 须非空 list"
    end

    Enum.each(rule.effects, &validate_effect!(&1, rule.id))
  end

  defp validate_material_filter!(nil), do: :ok
  defp validate_material_filter!(name), do: valid_material!(name, "material")

  defp valid_material!(name, field) do
    unless is_atom(name) and not is_nil(MaterialCatalog.material_id(name)) do
      raise ArgumentError, "Rule: #{field} 非法材料名 #{inspect(name)}"
    end
  end

  defp valid_tag_list!(tags, field) do
    unless is_list(tags) and Enum.all?(tags, &is_atom/1) do
      raise ArgumentError, "Rule: #{field} 须是 atom tag list,得 #{inspect(tags)}"
    end
  end

  defp validate_condition!(nil, required: false), do: :ok

  defp validate_condition!(nil, required: true) do
    raise ArgumentError, "Rule: phase_transition 须有 condition"
  end

  defp validate_condition!({field, op, threshold}, _opts)
       when field in @condition_fields and op in @ops do
    case threshold do
      {:material_threshold, attr} when is_binary(attr) -> :ok
      {:celsius, v} when is_number(v) -> :ok
      {:value, v} when is_number(v) -> :ok
      other -> raise ArgumentError, "Rule: 非法 threshold #{inspect(other)}"
    end
  end

  defp validate_condition!(other, _opts) do
    raise ArgumentError, "Rule: 非法 condition #{inspect(other)}"
  end

  defp validate_effect!({:add_tag, tag}, _id) when is_atom(tag), do: :ok
  defp validate_effect!({:remove_tag, tag}, _id) when is_atom(tag), do: :ok
  defp validate_effect!({:emit_heat_joules, j}, _id) when is_number(j) and j >= 0, do: :ok

  defp validate_effect!({:advance_attribute, attr, delta}, _id)
       when is_binary(attr) and is_number(delta),
       do: :ok

  defp validate_effect!({:transform, mat}, _id) do
    unless is_atom(mat) and not is_nil(MaterialCatalog.material_id(mat)) do
      raise ArgumentError, "Rule: transform 非法材料名 #{inspect(mat)}"
    end
  end

  defp validate_effect!(other, id) do
    raise ArgumentError,
          "Rule #{inspect(id)}: 非法 effect #{inspect(other)};合法 kind #{inspect(@effect_kinds)}"
  end
end
