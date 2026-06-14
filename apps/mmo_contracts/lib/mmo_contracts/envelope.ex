defmodule MmoContracts.Envelope do
  @moduledoc """
  FROZEN-5 信封的**共享构造/校验工具**与演进纪律说明。

  ## 演进纪律(FROZEN-2 / FROZEN-4)

  - **envelope 与兼容规则冻结,payload 走版本化演进**:信封字段**只追加不破坏**;
    每个信封带 `*_version`(payload_version / schema_version / boundary_payload_version 等)。
  - 破坏性变更**必须**提供迁移计划并走规范附录 C 变更流程。

  ## 本梯队定位(梯队 0 · 骨架前置)

  这些是 typed struct **骨架**:确立字段、必填项、版本字段与构造校验,**尚未接 wire/codec**。
  wire 集成在各对应梯队按"只追加不破坏"推进(梯队 1 命令/时间、梯队 3 复制/候选效果/边界事件)。

  ## 必填语义

  `required` 列表的元素:
  - 原子 `:k` —— 该字段必须非 `nil`。
  - 列表 `[:a, :b]` —— 这组里**至少一个**非 `nil`(用于 FROZEN-5 的 "A 或 B",
    如 `target_tick` / `server_received_tick`)。
  """

  @typedoc "必填规格:原子=必填;列表=至少其一"
  @type required_spec :: atom() | [atom()]

  @doc """
  从 `fields`(map 或 keyword)构造 `module` struct,并校验 `required`。

  未知键被忽略(`struct/2` 语义)。返回 `{:ok, struct}` 或 `{:error, {:missing_required, specs}}`。
  """
  @spec cast(module(), Enumerable.t(), [required_spec()]) ::
          {:ok, struct()} | {:error, {:missing_required, [required_spec()]}}
  def cast(module, fields, required) do
    built = struct(module, fields)

    missing =
      Enum.filter(required, fn
        keys when is_list(keys) -> Enum.all?(keys, &is_nil(Map.get(built, &1)))
        key -> is_nil(Map.get(built, key))
      end)

    case missing do
      [] -> {:ok, built}
      specs -> {:error, {:missing_required, specs}}
    end
  end

  @doc "同 `cast/3`,失败时 raise `ArgumentError`。"
  @spec cast!(module(), Enumerable.t(), [required_spec()]) :: struct()
  def cast!(module, fields, required) do
    case cast(module, fields, required) do
      {:ok, built} ->
        built

      {:error, {:missing_required, specs}} ->
        raise ArgumentError, "#{inspect(module)} 缺少必填字段(FROZEN-5): #{inspect(specs)}"
    end
  end
end
