defmodule NpcServer.Offers do
  @moduledoc """
  全局系统功能：统一形态（`"npc"`）的候选从哪里来（稿 A
  `docs/10-active/cross-cutting/2026-11-18-npc-full-capability-coverage-decision.md` §4 A-1、A-2，批 0a）。

  `NpcServer.Abilities` 是后端中立的能力定义（LLM、手写树、统一形态共用）；“统一形态怎么用每一项能力”是另一个变化轴，
  只在这里登记。Selector 只管什么时候问、问谁、选定后保持多久，候选由本模块给出。

  ## 覆盖登记（`coverage/0`）

  能力库的每个条目在统一形态里归且只归一类：

  ```mermaid
  flowchart LR
    A["Abilities.entries/1<br/>全授予 profile 的全部条目"] --> R{coverage/0<br/>每条只归一类}
    R -->|"{:offer, 生成器}"| G["生成器：技能 × 眼下可行对象<br/>→ 本轮候选"]
    R -->|"{:inside, [技能]}"| S["只作这些技能内部的原语"]
    R -->|"{:withheld, 理由}"| X["不给 NPC，理由写明"]
    G --> J["Selector → Jev top1"]
  ```

  - `offer`：有一个本模块导出的二元生成器，产出候选。批 0 只有两个：`registered/2`（作者登记的 build / gather / expand /
    travel 项，过渡形态：参数仍是作者手写的）与 `speak_to/2`（说话，对象是此刻说话范围内的人）。
  - `inside`：只在列出的技能内部当原语调用，技能本身是 offer。
  - `withheld`：不给统一形态，理由写在登记里（哪一批开放、或为什么永不开放）。

  覆盖测试（`npc_offers_test.exs`）以“全授予 profile”算出 `Abilities.entries/1` 的名字集合，与登记的键逐一对上：
  能力库新增条目不登记即红。

  ## 候选（`candidates/4`）

  一轮候选 = `registered/2`（登记项按建筑条件保序过滤）++ `speak_to/2`（与 Scene 此刻允许开新话题的目标取交集）。
  每个候选是 `%{name, kind, object, criterion, place_name, …}`：`name` 是给 Jev 的选项名（本轮唯一），`kind` 是计划与记账用的
  种类，`object` 是种类的对象（没有为 nil）。登记项 `kind` = 候选名、`object` = nil（`static/1`）；说话项 `kind` = `"speak_to"`、
  `object` = `%{"actor" => cid}`，另带 `target`（冻结的目标身份与代次，Runtime 原样交给 speak 技能）。
  给 Jev 的请求体只序列化 `name → criterion`（`NpcServer.Selector`），kind / object 不进请求。

  ## 计划种类（`plan_kinds/1`，批 0b）

  日计划的词表是“种类 + 可选对象”，不是候选名：候选名（`speak_to:<cid>`）逐轮变，计划写不出、记账也对不上。种类与候选的
  `kind` 同一套名字：登记项各是一个静态种类（没有对象），说话是 `speak_to`（对象是人，由 Life 展开成可点名的显示名）。
  活动结束时 `Selector.experience/2` 交出候选的 `{kind, object}`，`Life.DayPlan.record_activity/4` 按它记账。
  """
  alias NpcServer.Life.State
  alias SceneServer.Movement.Scene

  # 说话候选的种类名：计划词表里说话一类的名字，也是说话候选名的前缀（`speak_to:<cid>`）。
  @speak "speak_to"

  @coverage %{
    # —— offer：有生成器 ——
    "build" => {:offer, :registered},
    "gather" => {:offer, :registered},
    "expand" => {:offer, :registered},
    "travel" => {:offer, :registered},
    "speak" => {:offer, :speak_to},

    # —— inside：只作技能内原语 ——
    # stop 由 `Brain.Tree.halt/1` 在放弃移动叶子时发出，属于 travel / gather 走路的收尾，不单独成为候选。
    "move_to" => {:inside, [:travel, :gather]},
    "stop" => {:inside, [:travel, :gather]},
    "probe_toward" => {:inside, [:gather]},
    "use_tool" => {:inside, [:gather]},
    "place" => {:inside, [:expand]},
    "prefab" => {:inside, [:build, :expand]},
    "look" => {:inside, [:gather, :expand]},
    "query_balances" => {:inside, [:gather, :expand]},
    "survey" => {:inside, [:expand, :travel]},
    "read_catalog" => {:inside, [:expand]},
    "get_target_status" => {:inside, [:travel]},
    "say" => {:inside, [:speak]},

    # —— withheld：不给 NPC ——
    "craft" => {:withheld, "批 1 前不开放：生成器（有料才列）与计划记账在批 1 一起做。"},
    "eat" => {:withheld, "批 1 前不开放：生成器（有可食余额才列）与计划记账在批 1 一起做。"},
    "dismantle" => {:withheld, "批 2 前不开放：对象（只列自己放的）要从 Life 的建筑栏生成。"},
    "inspect" => {:withheld, "批 2 前不开放：统一形态里还没有调用方，批 2 作为点火 / 加热等对象的来源接入。"},
    "scoop" => {:withheld, "批 3 前不开放：液体对象的空间参数要等生成器的缝稳定之后。"},
    "pour" => {:withheld, "批 3 前不开放：液体对象的空间参数要等生成器的缝稳定之后。"},
    "attach" => {:withheld, "批 3 前不开放：构件的空间参数要等生成器的缝稳定之后。"},
    "detach" => {:withheld, "批 3 前不开放：构件的空间参数要等生成器的缝稳定之后。"},
    "cast_spell" => {:withheld, "批 4（后期）：\"npc\" 登记不读 spells，要新的授予。"},
    "cancel_cast" => {:withheld, "批 4（后期）：随 cast_spell 一起开放（\"npc\" 登记不读 spells）。"},
    "design_house" => {:withheld, "批 4（后期）：要 LLM 与写作预算，作为“一项由 LLM 执行的活动”与 Brain.Llm 收编同议。"},
    "wilderness" => {:withheld, "作者施工器：要调度器端点，没有 JSON 形配置，只能由代码起。"},
    "fill_box" => {:withheld, "创世特权：只给创世登记（llm / life 行的 genesis: true）。"},
    "set_cells" => {:withheld, "创世特权：只给创世登记（llm / life 行的 genesis: true）。"},
    "get_view" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "look_at" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "get_aim" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "get_visible_entities" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "select_target" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "remove_target" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "get_targets" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "set_focus" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "cycle_focus" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "remove_focus" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "clear_targets" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "toggle_mark" => {:withheld, "关注 / 本地目标组：统一形态没有战斗调用方。"},
    "remember" => {:withheld, "统一形态的记忆归 Life + Hindsight，再给记忆工具会出第二真值。"},
    "recall" => {:withheld, "统一形态的记忆归 Life + Hindsight，再给记忆工具会出第二真值。"},
    "search_memory" => {:withheld, "统一形态的记忆归 Life + Hindsight，再给记忆工具会出第二真值。"},
    "set_plan" => {:withheld, "统一形态的计划归 Life.DayPlan，再给计划工具会出第二真值。"},
    "choose_activity" => {:withheld, "统一形态的活动选择由 Jev 选择层承担（Trees.npc 发这条命令），它本身不是候选。"}
  }

  @doc """
  覆盖登记：`%{条目名 => {:offer, 生成器名} | {:inside, [技能原子]} | {:withheld, 理由}}`（三类见 moduledoc）。
  `{:offer, 生成器}` 的生成器是本模块导出的二元函数。
  """
  def coverage, do: @coverage

  @doc """
  本轮候选（Selector 发问 worker 里调用）：`registered/2` 的结果 ++ 说话候选。profile 配了 speak 技能时，说话候选取
  `speak_to/2` 与当前 Scene 此刻允许开新话题的目标（`Scene.dialogue_topic_targets/2`，按身份与代次）的交集。
  `buildings` 是 Life 规范心智里的建筑（`Life.mind/2` 的 `buildings`）。返回 `{:ok, 候选}`；路由或 Scene 读不到时
  `{:error, {:dialogue_unavailable, 原因}}`（显式失败，不当成“没有人可说”）。
  """
  def candidates(profile, observation, context, buildings) do
    with {:ok, topics} <- topics(profile, observation, context) do
      {:ok, registered(profile.activities, buildings) ++ topics}
    end
  end

  defp topics(%{activities: registered, skills: %{speak: _}}, observation, context) do
    case speak_to(registered, observation) do
      [] ->
        {:ok, []}

      topics ->
        scene_id = Map.get(observation.self, :scene_id, context.scene_id)

        with {:ok, route} <- context.router.route(scene_id),
             {:ok, allowed} <- topic_targets(route.scene_ref, observation.self.entity_id) do
          {:ok,
           Enum.filter(topics, fn %{target: %{"entity_id" => id, "entity_epoch" => epoch}} ->
             MapSet.member?(allowed, {id, epoch})
           end)}
        else
          {:error, reason} -> {:error, {:dialogue_unavailable, reason}}
        end
    end
  end

  defp topics(_profile, _observation, _context), do: {:ok, []}

  defp topic_targets(scene, cid) do
    {:ok, MapSet.new(Scene.dialogue_topic_targets(scene, cid))}
  catch
    :exit, {reason, {GenServer, :call, _}} -> {:error, reason}
  end

  @doc """
  生成器（build / gather / expand / travel 的过渡形态）：作者登记的候选（`profile.activities`，`NpcServer.Registry` 构造）
  按建筑条件保序过滤——带 `requires_building` 的项只在 `buildings` 里有至少一座同名且站着时列出——每项经 `static/1`
  加上种类与对象。参数仍是作者手写的；批 1 起由各种类自己的生成器替代。
  """
  def registered(activities, buildings) do
    standing = for %{name: name, standing: true} <- buildings, into: MapSet.new(), do: name

    for activity <- activities,
        not Map.has_key?(activity, :requires_building) or
          MapSet.member?(standing, activity.requires_building),
        do: static(activity)
  end

  @doc "登记项作为候选（静态种类）：原样加 `kind`（= 候选名）与 `object`（nil）。"
  def static(%{name: name} = activity), do: Map.merge(activity, %{kind: name, object: nil})

  @doc """
  生成器（speak）：把本轮观察里说话范围内（`SceneServer.Dialogue.limits/0` 的 `range_m`，含恰在范围上）、有位置的其他角色
  投影成说话候选，保持观察次序。目标身份与代次冻结在 `target` 里；候选名 `speak_to:<cid>` 从已有登记名避让重名
  （占了就往后加下划线）。最终接纳由 Scene 对着发言时刻的角色表裁决。
  """
  def speak_to(registered, %{self: self} = observation) do
    %{range_m: range} = SceneServer.Dialogue.limits()
    names = MapSet.new(registered, & &1.name)

    for %{entity_id: id, entity_epoch: epoch, name: actor_name, position: {_, _, _} = position} <-
          State.others(observation),
        State.distance(self.position, position) <= range do
      name = State.person_name(actor_name)

      %{
        name: vacant_name("#{@speak}:#{id}", names),
        kind: @speak,
        object: %{"actor" => id},
        criterion: "Walk up to #{name} (actor #{id}) and say one thing to them.",
        place_name: nil,
        target: %{"entity_id" => id, "entity_epoch" => epoch, "name" => name}
      }
    end
  end

  @doc """
  对话回合里“放下手头的事去跟来话者谈”的说话候选（`NpcServer.Selector.turn_question/6`）：目标是来话者本人，带本次
  `conversation_id`（回复仍在同一会话里，不是新话题，所以不经 Scene 的新话题冷却，也不要求来话者在观察里）；
  种类、对象与候选名的避让规则同 `speak_to/2`。
  """
  def reply(registered, speech) do
    name = State.person_name(speech.speaker_name)

    %{
      name: vacant_name("#{@speak}:#{speech.speaker_id}", MapSet.new(registered, & &1.name)),
      kind: @speak,
      object: %{"actor" => speech.speaker_id},
      criterion: "Stop what I am doing, go over to #{name} and talk with them.",
      place_name: nil,
      target: %{
        "entity_id" => speech.speaker_id,
        "entity_epoch" => speech.speaker_epoch,
        "name" => name,
        "conversation_id" => speech.conversation_id
      }
    }
  end

  @doc """
  日计划可以写的种类（稿 A §4 A-5，批 0b），按次序：登记的每个候选各是一个静态种类（种类名 = 候选名，判据原样，不论建筑条件——
  计划是一天的打算，眼下不可行也可以先写下），配了 speak 技能时再加说话一类（对象是人）：

      [%{kind: 种类, criterion: 判据, objects: :none | :people}]

  没有候选表的形态（不在选择层选活动）没有任何种类。具体能点名哪些人由 Life 起规划槽时展开（`NpcServer.Life` 的“日计划”）；
  种类的名字必须互不相同，登记边界（`NpcServer.Registry.brain/2`）据此拒绝与生成种类同名的候选。
  """
  def plan_kinds(%{activities: activities} = profile) do
    static =
      for %{name: name, criterion: criterion} <- activities,
          do: %{kind: name, criterion: criterion, objects: :none}

    case profile do
      %{skills: %{speak: _}} ->
        static ++
          [
            %{
              kind: @speak,
              criterion: "Walk up to someone and say one thing to them.",
              objects: :people
            }
          ]

      _ ->
        static
    end
  end

  def plan_kinds(_profile), do: []

  defp vacant_name(name, names) do
    if MapSet.member?(names, name), do: vacant_name(name <> "_", names), else: name
  end
end
