defmodule VoxelRegion.Access do
  @moduledoc """
  World 写操作的统一授权：**谁（主体）可以做哪一类动作、可以改哪些格**，只在这里定义。

  设计稿：`docs/10-active/cross-cutting/2026-10-30-server-authorization-design.md`。分工沿用 XACML 的
  PEP / PDP：本模块是只求值的决策点（纯函数，不读 World、不持状态）；World 的请求入口与 Gate 会话入口是执行点；
  `VoxelRegion.Protection` 只回答"这格归谁"。

  ## 主体（principal）

  | 主体 | 由谁构造 | 含义 |
  |---|---|---|
  | `{:character, cid}` | 角色 owner（玩家与 NPC 走同一条角色路径） | 以角色身份行事，受保护区约束 |
  | `{:genesis, cid}` | NPC Body，仅当注册表授予创世 | 创世 NPC 的原始地形编辑，仍受保护区约束 |
  | `:operator` | World 的运维 / 作者公共 API（release rpc、维护脚本） | 不受保护区约束 |
  | `:system` | World 内部与区域流（装页、窗口、物理推进） | 不经授权；跨区域靠物理隔离 |

  主体在进入的通道处构造一次。集群内调用是可信代码，"哪个 app 能调哪类 World API"由
  `test/access_test.exs` 的白名单测试守住，不另做签名或令牌。

  ## 怎么加一种新的 World 消息

  在 `@messages` 里给它选一个动作类。没登记的消息会被 World 拒绝（`:unregistered_message`），
  `access_test.exs` 会对照 `World.Closure.registered_entries/0` 报出漏登记的消息。
  """
  require Logger
  alias VoxelRegion.Protection

  @type principal :: {:character, integer()} | {:genesis, integer()} | :operator | :system
  @type action ::
          :character_intent | :raw_edit | :gm_build | :world_authoring | :simulation | :read

  # 动作类 => 允许的主体类别。`:any` 表示只读，任何调用方都可以。
  @policy %{
    character_intent: [:character],
    raw_edit: [:operator, :genesis],
    gm_build: [:operator],
    world_authoring: [:operator],
    simulation: [:system],
    read: :any
  }

  # World 的每条消息（按首元素标签）属于哪个动作类；与 `World.Closure.registered_entries/0` 一一对应。
  # 只有原始编辑的消息显式携带主体（第二个元素）；其余消息的主体由构造它的 World 公共 API 决定。
  @messages %{
    # 角色意图：由角色 owner 生成 actor 后经 World 公共 API 进入
    tool_intent: :character_intent,
    body_tool: :character_intent,
    spell_intent: :character_intent,
    quote_cast: :character_intent,
    prepare_cast: :character_intent,
    authorize_cast: :character_intent,
    cancel_cast: :character_intent,
    production_intent: :character_intent,
    attachment_intent: :character_intent,
    prefab_intent: :character_intent,
    publish_prefab: :character_intent,
    prepare_beacon: :character_intent,
    commit_beacon: :character_intent,
    body_contact: :character_intent,
    body_death: :character_intent,
    body_detach: :character_intent,
    body_coherence: :character_intent,
    retry_death_drop: :character_intent,

    # 原始格编辑：不经玩法裁决，只给运维与创世 NPC
    apply_edit: :raw_edit,
    apply_edits: :raw_edit,

    # GM 施工（另需部署开关 VOXIM_GM_TOOLS，由 World.Gm 判定）
    gm: :gm_build,
    gm_prepare: :gm_build,

    # 运维 / 作者 / 维护写世界
    author_regions: :world_authoring,
    publish_properties: :world_authoring,
    publish_parameters: :world_authoring,
    publish_prefabs: :world_authoring,
    thermal_experiment: :world_authoring,
    liquid_experiment: :world_authoring,
    liquid_fill: :world_authoring,
    material_supply: :world_authoring,
    parcel_prepare: :world_authoring,
    parcel_install: :world_authoring,
    parcel_export: :world_authoring,
    beacon_install: :world_authoring,
    place_prefab: :world_authoring,
    remove_prefab: :world_authoring,
    replace_prefab: :world_authoring,
    compact: :world_authoring,
    maintain_residency: :world_authoring,
    retry_simulation_io: :world_authoring,

    # World 内部与区域流：装页、窗口、物理推进、任务回执
    prepare: :simulation,
    adopt_liquid: :simulation,
    page_need: :simulation,
    page_stage: :simulation,
    page_commit: :simulation,
    page_yield: :simulation,
    page_adopt: :simulation,
    page_resident_all: :simulation,
    prefab_request: :simulation,
    prefab_inputs: :simulation,
    prefab_loaded: :simulation,
    prefab_ready: :simulation,
    prefab_known: :simulation,
    window_input: :simulation,
    window_finished: :simulation,
    window_geometry: :simulation,
    simulation_windows: :simulation,
    liquid_commit: :simulation,
    thermal_commit: :simulation,
    liquid_tick: :simulation,
    thermal_tick: :simulation,
    thermal_step: :simulation,
    projectile_tick: :simulation,
    input_continue: :simulation,
    timeout: :simulation,
    reference: :simulation,
    DOWN: :simulation,

    # 只读查询与订阅
    content_version: :read,
    seq: :read,
    interactions_since: :read,
    admission_status: :read,
    residency_status: :read,
    liquid_activity: :read,
    source: :read,
    stats: :read,
    magic_range: :read,
    magic_digest: :read,
    caster_state: :read,
    send_caster_state: :read,
    tool_range: :read,
    tool_definition: :read,
    material_balances: :read,
    material_catalog: :read,
    beacon_directory: :read,
    prefab_catalog: :read,
    published_prefab_metadata: :read,
    instance_cells: :read,
    replacement_cells: :read,
    sight_snapshot: :read,
    material_snapshot: :read,
    simulation_snapshot: :read,
    canonical_snapshot: :read,
    replica_snapshot: :read,
    serve_item: :read,
    subscribe: :read,
    entries_after: :read
  }

  @doc "登记表：消息标签 => 动作类（测试与观测用）。"
  def messages, do: @messages

  @doc "策略表：动作类 => 允许的主体类别（测试与观测用）。"
  def policy, do: @policy

  # 准备包装本身不是动作，按里面的原消息判定（见 `admit/1`）。
  @wrappers [:prepare_intent, :prepared_intent]

  @doc "准备包装的消息标签（测试用）。"
  def wrappers, do: @wrappers

  @doc """
  主体能否发起这类动作。拒绝时打一行 `world_access_denied` 结构化日志，返回 `{:error, :forbidden}`。
  """
  @spec authorize(principal(), action()) :: :ok | {:error, :forbidden}
  def authorize(principal, action) do
    case Map.fetch!(@policy, action) do
      :any -> :ok
      kinds -> if kind(principal) in kinds, do: :ok, else: deny(principal, action, :forbidden)
    end
  end

  @doc """
  World 请求入口的准入：消息必须已登记；原始编辑按其携带的主体判定。
  准备包装（`prepare_intent` / `prepared_intent`）按里面的原消息判定，不能借包装绕过。
  """
  @spec admit(term()) :: :ok | {:error, :forbidden | :unregistered_message}
  def admit({:prepare_intent, message}), do: admit(message)
  def admit({:prepared_intent, _keys, message, _decoded}), do: admit(message)

  def admit(message) do
    tag = tag(message)

    case Map.fetch(@messages, tag) do
      :error -> deny(:unknown, tag, :unregistered_message)
      {:ok, :raw_edit} -> authorize(elem(message, 1), :raw_edit)
      {:ok, _action} -> :ok
    end
  end

  @doc """
  主体能否改这些宏格（保护区）。运维与系统不受保护区约束；角色与创世 NPC 只能改野外和自己持有的区域。
  """
  @spec authorize_cells(principal(), map(), [{integer(), integer(), integer()}], action()) ::
          :ok | {:error, :protected_region}
  def authorize_cells(principal, protection, cells, action) do
    case principal do
      p when p in [:operator, :system] ->
        :ok

      {kind, cid} when kind in [:character, :genesis] ->
        if Protection.permitted?(protection, {:character, cid}, cells),
          do: :ok,
          else: deny(principal, action, :protected_region)
    end
  end

  defp kind({kind, _cid}), do: kind
  defp kind(kind) when is_atom(kind), do: kind

  # 任务回执等以引用为首元素的消息归为 :reference（与 Closure 登记同口径）。
  defp tag(message) when is_atom(message), do: message
  defp tag(message) when is_tuple(message) and is_reference(elem(message, 0)), do: :reference
  defp tag(message) when is_tuple(message), do: elem(message, 0)

  # 唯一的拒绝出口：所有授权拒绝都经这里，日志字段固定，便于检索与统计。
  defp deny(principal, action, reason) do
    Logger.warning(
      "world_access_denied principal=#{inspect(principal)} action=#{inspect(action)} reason=#{reason}"
    )

    {:error, reason}
  end
end
