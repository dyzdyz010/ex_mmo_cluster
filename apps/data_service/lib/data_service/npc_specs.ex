defmodule DataService.NpcSpecs do
  @moduledoc """
  全局系统功能：NPC 注册表的持久行（`npc_specs` 表，docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §2）。

  一行 = 一个随节点启动的 NPC：`character_id` 是 characters 表的 NPC 行（`CharacterStore.ensure_npc/1`，名字即永久身份），
  `scene_id` / `spawn` 是入场 Scene 与出生点（米），`brain` 与 `params` 是大脑名与它的 JSON 形参数（字符串键），`enabled`
  决定是否随节点启动。参数的含义与校验只在 `NpcServer.Registry`（登记时校验一次，非法不落库）；这里只存取，不解释。
  位置不持久化：每次入场从 spawn 开始。

  与 `DataService.NpcMemory` 同范式：直接走 `DataService.Repo` 的模块函数。
  """
  import Ecto.Query, only: [from: 2]
  alias DataService.Repo

  @table "npc_specs"

  @doc "写入（覆盖）cid 的登记并置 `enabled = true`。`spawn` 是 `{x, y, z}`（米），`params` 是 JSON 形 map。"
  def upsert(cid, %{scene_id: scene_id, spawn: {x, y, z}, brain: brain, params: params})
      when is_integer(cid) and is_integer(scene_id) and is_binary(brain) and is_map(params) do
    now = DateTime.utc_now()

    row = %{
      character_id: cid,
      scene_id: scene_id,
      spawn: %{"x" => x, "y" => y, "z" => z},
      brain: brain,
      params: params,
      enabled: true,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(@table, [row],
      on_conflict: {:replace, [:scene_id, :spawn, :brain, :params, :enabled, :updated_at]},
      conflict_target: :character_id
    )

    :ok
  end

  @doc """
  全部登记（含已停用），按名字排序：`[%{cid:, name:, scene_id:, spawn: {x, y, z}, brain:, params:, enabled:}]`。
  名字取自 characters 行（`Body.start/2` 按名字起 NPC）。
  """
  def list do
    from(s in @table,
      join: c in "characters",
      on: c.id == s.character_id,
      select: %{
        cid: s.character_id,
        name: c.name,
        scene_id: s.scene_id,
        spawn: s.spawn,
        brain: s.brain,
        params: s.params,
        enabled: s.enabled
      }
    )
    |> Repo.all()
    |> Enum.map(fn %{spawn: spawn} = row ->
      %{row | spawn: {spawn["x"], spawn["y"], spawn["z"]}}
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "按名字停用：`{:ok, cid}`；没有这个名字的登记 → `{:error, :not_found}`。登记行与角色行都保留。"
  def disable(name) when is_binary(name) do
    query =
      from(s in @table,
        join: c in "characters",
        on: c.id == s.character_id,
        where: c.name == ^name,
        select: s.character_id
      )

    case Repo.update_all(query, set: [enabled: false, updated_at: DateTime.utc_now()]) do
      {1, [cid]} -> {:ok, cid}
      {0, []} -> {:error, :not_found}
    end
  end
end
