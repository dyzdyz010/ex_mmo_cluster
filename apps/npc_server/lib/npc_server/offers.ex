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

  - `offer`：有本模块导出的二元生成器，产出候选（一个条目由几个生成器给出时登记写列表）。现在五个：`registered/2`（作者登记的
    build / gather / expand / travel 项，过渡形态：参数仍是作者手写的）、`people/2`（作者登记的对人的项，如 confront_wrecker：
    按作者条件把此刻满足条件的每个人展开成一个可点名的候选，K-0 复测后用户定；travel 条目由它与 `registered/2` 共同给出）、
    `speak_to/2`（说话，对象是此刻说话范围内的人）、`eat/2` 与 `craft/2`（批 1：背包里眼下能吃一份 / 能合成一次的材料）。
  - `inside`：只在列出的技能内部当原语调用，技能本身是 offer。
  - `withheld`：不给统一形态，理由写在登记里（哪一批开放、或为什么永不开放）。

  覆盖测试（`npc_offers_test.exs`）以“全授予 profile”算出 `Abilities.entries/1` 的名字集合，与登记的键逐一对上：
  能力库新增条目不登记即红。

  ## 候选（`candidates/4`）

  候选只从覆盖登记生成（唯一来源）：`generators/1` 取登记里 offer 一类的生成器，按本模块显式写下的生成器次序
  `[:registered, :people, :speak_to, :eat, :craft]` 排列（不按名字排序；新增生成器一般追加在末尾，`:people` 紧跟登记项的理由
  写在 `@generators` 旁；登记里出现次序表没有的生成器即 raise），`candidates/4` 按这个次序逐个生成再连起来；某个条目改成
  inside / withheld，它的生成器（若没有别的 offer 条目共用）就不再出候选。现在一轮候选 = `registered/2`（登记项按建筑条件保序
  过滤，不含对人的项）++ `people/2`（对人的登记项 × 此刻满足作者条件的人）++ `speak_to/2`（与 Scene 此刻允许开新话题的目标
  取交集）++ `eat/2` ++ `craft/2`（各取前 k 项，`@per_kind` 现为 3，原创取值待 X-1）。

  ```mermaid
  flowchart LR
    O["本轮观察 + Life 视图<br/>（建筑、信任）"] --> REG["registered/2"]
    O --> PE["people/2：对人的登记项 × 满足作者条件的人"]
    O --> SP["speak_to/2 ∩ Scene 新话题资格"]
    W["World.production_options/2<br/>（每轮一次）<br/>进食 / 合成门由 World 判定"] --> EAT["eat/2：能吃一份的"]
    W --> CR["craft/2：能合成一次的"]
    EAT --> K["每类按材料号升序取前 k"]
    CR --> K
    REG --> C["本轮候选（有序）"]
    PE --> C
    SP --> C
    K --> C
  ```

  每个候选是 `%{name, kind, object, criterion, place_name, …}`：`name` 是给 Jev 的选项名（本轮唯一），`kind` 是计划与记账用的
  种类，`object` 是种类的对象（没有为 nil）。登记项 `kind` = 候选名、`object` = nil（`static/1`），`run` 是登记时构造的分支规格；
  说话项 `kind` = `"speak_to"`、`object` = `%{"actor" => cid}`，另带 `target`（冻结的目标身份与代次，Runtime 原样交给 speak 技能）；
  对人的登记项 `kind` = 登记名、`object` = `%{"actor" => cid}`，同样带 `target`（与说话项同形；树按 `kind` 分辨，travel 过去再待登记的停留）；
  背包项 `kind` = `"eat"` / `"craft"`、`object` = `%{"material" => 材料号}`，另带 `action` = `{动作名, %{"material" => 材料号}}`
  （冻结的世界动作，键名与登记项的 `run` 分开：两者含义不同；`Trees.npc/1` 按 `acts/0` 建的分支原样执行，World 仍做最后裁决）。
  被选中的候选整份冻结进选择（`NpcServer.Selector` 的 `candidate`），执行与经历都读这一份，不回查登记表。
  给 Jev 的请求体只序列化 `name → criterion`（`NpcServer.Selector`），kind / object / action 不进请求。

  **背包的可行性只由 World 判定**：进食 / 合成的门槛（可食、生产材料、余额够一份、配方每条输入够）只写在
  `VoxelRegion.World.Production`，提交与只读查询 `World.production_options/2` 共用；本模块不读余额与目录、不镜像任何条件，
  只把 World 列出的材料投影成候选。一轮之内路由至多一次（说话与库存共用），库存至多读一次（进食与合成共用）。
  库存一路只走 happy path（用户 2026-11-19 方向）：按 World 的缺省调用，失败照常退出、由发问 worker 已有的失败路径处理；
  超时转换、降级等兜底留待实验暴露失败再按设计加。已知不覆盖：选择快照里没有饥饿信号，进食被不被选中缺驱动力依据（后续议题）。

  ## 计划种类（`plan_kinds/1`，批 0b）

  日计划的词表是“种类 + 可选对象”，不是候选名：候选名（`speak_to:<cid>`、`eat:<材料号>`）逐轮变，计划写不出、记账也对不上。
  种类与候选的 `kind` 同一套名字，按生成器次序：登记项各是一个静态种类（没有对象），对人的登记项各是一个对象为人的种类（同说话），
  说话是 `speak_to`（对象是人，由 Life 展开成可点名的显示名），进食 `eat`、合成 `craft`（批 1，计划里不可点名材料）。活动结束时 `Selector.experience/1` 交出候选的
  `{kind, object}`，`Life.DayPlan.record_activity/4` 按它记账（没点名的 eat 意图对吃哪种都成立）。
  """
  alias NpcServer.Life.State
  alias SceneServer.Movement.Scene
  alias VoxelRegion.World

  # 说话候选的种类名：计划词表里说话一类的名字，也是说话候选名的前缀（`speak_to:<cid>`）。
  @speak "speak_to"

  # 生成器的次序（批 1 前置，统筹定）：一轮候选按它连起来，日计划的种类也按它排。显式写下而不按名字排序——按名字排
  # 新增的 `:craft` / `:eat` 会排到 `:registered` 之前，悄悄改变候选次序（请求体是有序对象，次序对 Jev 有意义）。
  # 新生成器一般追加在末尾；覆盖登记里出现这里没有的生成器是登记写错，`generators/1` 直接 raise。
  # `:people`（对人的登记项，K-0 复测后用户定可点名）是例外，紧跟 `:registered`：它展开的仍是作者登记的项，原来就排在登记项
  # 之中；放在这里，部署里排在最后一项登记的 confront_wrecker 在请求体里的位置不变（只是名字与判据带上了人），说话、进食、
  # 合成的相对次序也不变。追加在末尾则会把它挪到生成的说话 / 背包候选之后，改变 Jev 已经实测过的次序。
  @generators [:registered, :people, :speak_to, :eat, :craft]

  # 背包生成器：冻结的执行参数是一条世界动作 `action: {动作名, %{"material" => 材料号}}`，`Trees.npc/1` 按动作名建分支。
  # 动作名也是计划里这两类的种类名（`kinds/1`），候选的 `kind` 与计划记账靠它们相等。
  @acts %{eat: "eat", craft: "craft"}

  # 每类候选至多几项（稿 A §4 A-4 的 k）。**原创取值**：3 是 A-4 定的起点（检索 SayCan、Voyager、UE EQS、Tool search 文档，
  # 均无适用于“DeepSeek 单选封闭候选”的数），由离线实验 X-1 定终值。只套背包生成器：登记项是作者写的、条数由作者定；
  # 说话候选另由 Scene 的新话题资格限制，统筹定 k 不套它。总上限 C 推迟到 X-1，批 1 不实现。
  @per_kind 3
  @capped Map.keys(@acts)

  @coverage %{
    # —— offer：有生成器 ——
    "build" => {:offer, :registered},
    "gather" => {:offer, :registered},
    "expand" => {:offer, :registered},
    # travel 由两种作者登记项用到：去处 / 技能项（`registered/2`）与对人的登记项（`people/2`，按人展开）。
    "travel" => {:offer, [:registered, :people]},
    "speak" => {:offer, :speak_to},
    "eat" => {:offer, :eat},
    "craft" => {:offer, :craft},

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
    "dismantle" => {:withheld, "批 2 前不开放：对象（只列自己放的）要从 Life 的建筑栏生成。"},
    # inspect 不随其它感知原语归 inside（稿 A §4 初稿的说法）：统一形态里没有任何技能调用它，归 inside 就是登记了一个不存在的用法。
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
  覆盖登记：`%{条目名 => {:offer, 生成器名 | [生成器名]} | {:inside, [技能原子]} | {:withheld, 理由}}`（三类见 moduledoc）。
  `{:offer, 生成器}` 的生成器是本模块导出的二元函数；一个条目由几个生成器给出时写列表（现在只有 travel）。
  """
  def coverage, do: @coverage

  @doc """
  本轮候选（Selector 发问 worker 里调用）：按 `generators/1` 对覆盖登记给出的生成器次序，逐个生成再连起来——现在是
  登记项（`registered/2`）++ 对人的登记项（`people/2`）++ 说话 ++ 进食 ++ 合成。`life` 是这次发问的 Life 视图
  （`Life.selection_mind/2` 的结果，与心智快照同一份）：读其中的 `buildings`（建筑条件）与 `relationships`（对人登记项的作者条件）。

  - 说话候选只在 profile 配了 speak 技能时有，取 `speak_to/2` 与当前 Scene 此刻允许开新话题的目标
    （`Scene.dialogue_topic_targets/2`，按身份与代次）的交集。
  - 进食 / 合成候选取自这一刻现读的库存：每轮读 World 一次（`World.production_options/2`，`eat/2` 与 `craft/2` 共用同一份）。
    能不能吃 / 合成由 World 判定（与提交同一组条件），这里不再过滤。每类只留前 #{@per_kind} 项（生成器给完整的有序列表，在这里截断）。
  - 路由每轮至多一次，说话与库存共用（第一个要用的生成器去路由，结果留给后面的）。

  返回 `{:ok, 候选}`；说话这一路的路由或 Scene 读不到 → `{:error, {:dialogue_unavailable, 原因}}`（显式失败，不当成“没有人可说”）。
  库存这一路只走 happy path：路由或 World 调用失败照常退出，由发问 worker 已有的失败路径处理（Runtime 的 `select_worker_failed`）。
  """
  def candidates(profile, observation, context, %{
        buildings: buildings,
        relationships: relationships
      }) do
    round = %{
      profile: profile,
      observation: observation,
      context: context,
      buildings: buildings,
      relationships: relationships,
      route: nil,
      inventory: nil
    }

    Enum.reduce_while(generators(@coverage), {:ok, [], round}, fn generator, {:ok, acc, round} ->
      case offer(generator, round) do
        {:ok, offered, round} -> {:cont, {:ok, acc ++ capped(generator, offered), round}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, candidates, _round} -> {:ok, candidates}
      error -> error
    end
  end

  @doc """
  覆盖登记里 offer 一类的生成器，按模块里显式写下的生成器次序（现在 `[:registered, :people, :speak_to, :eat, :craft]`），与登记表的
  遍历次序无关；登记里出现次序表没有的生成器是登记写错，raise `ArgumentError`。`candidates/4` 与 `plan_kinds/1` 只按它生成，
  所以某个条目改成 inside / withheld 后，只要没有别的 offer 条目还用同一个生成器，它的候选与计划种类就不再出现。
  `registered/2` 一个生成器同时服务 build / gather / expand / travel 四个条目（过渡形态），只改其中一个不会让它消失。
  """
  def generators(coverage) do
    offered =
      for {_entry, {:offer, generators}} <- coverage,
          generator <- List.wrap(generators),
          into: MapSet.new(),
          do: generator

    case Enum.reject(offered, &(&1 in @generators)) do
      [] ->
        Enum.filter(@generators, &MapSet.member?(offered, &1))

      unknown ->
        raise ArgumentError,
              "覆盖登记里的生成器不在生成器次序表里：#{inspect(Enum.sort(unknown))}（次序表 #{inspect(@generators)}）"
    end
  end

  @doc """
  背包生成器冻结的世界动作名（`["eat", "craft"]`，按生成器次序）：`NpcServer.Trees.npc/1` 按它给每个动作建一条分支，
  守卫读选择应答里候选的 `action`（`{动作名, 参数}`）。
  """
  def acts,
    do: for(generator <- @generators, Map.has_key?(@acts, generator), do: @acts[generator])

  defp capped(generator, offered) when generator in @capped, do: Enum.take(offered, @per_kind)
  defp capped(_generator, offered), do: offered

  # 一个生成器本轮的候选，连同更新过的本轮读取（路由、库存）。生成器名来自 `generators/1`，这里没有的名字直接 FunctionClauseError。
  defp offer(:registered, round),
    do: {:ok, registered(round.profile.activities, round.buildings), round}

  defp offer(:people, round),
    do:
      {:ok,
       people(round.profile.activities, %{
         observation: round.observation,
         relationships: round.relationships
       }), round}

  defp offer(:speak_to, round), do: topics(round)

  defp offer(generator, round) when generator in [:eat, :craft] do
    round = inventory(round)
    registered = round.profile.activities

    offered =
      if generator == :eat,
        do: eat(registered, round.inventory),
        else: craft(registered, round.inventory)

    {:ok, offered, round}
  end

  defp topics(%{profile: %{activities: registered, skills: %{speak: _}}} = round) do
    case speak_to(registered, round.observation) do
      [] ->
        {:ok, [], round}

      topics ->
        with {:ok, round} <- route(round),
             {:ok, allowed} <-
               topic_targets(round.route.scene_ref, round.observation.self.entity_id) do
          {:ok,
           Enum.filter(topics, fn %{target: %{"entity_id" => id, "entity_epoch" => epoch}} ->
             MapSet.member?(allowed, {id, epoch})
           end), round}
        else
          {:error, reason} -> {:error, {:dialogue_unavailable, reason}}
        end
    end
  end

  defp topics(round), do: {:ok, [], round}

  # 本轮的路由：至多路由一次，成功的结果留给后面的生成器；失败原样返回，由用到它的那一路决定怎样处理。
  defp route(%{route: nil} = round) do
    %{observation: observation, context: context} = round

    with {:ok, route} <-
           context.router.route(Map.get(observation.self, :scene_id, context.scene_id)),
         do: {:ok, %{round | route: route}}
  end

  defp route(round), do: {:ok, round}

  # 本轮的库存（`World.production_options/2` 的结果）：至多读一次，进食与合成共用。
  # 只走 happy path（用户 2026-11-19 方向）：路由或 World 调用失败照常退出，由发问 worker 已有的失败路径处理
  # （Runtime 的 `select_worker_failed`）；超时、降级等兜底等实验暴露失败再按设计加。
  defp inventory(%{inventory: nil} = round) do
    {:ok, round} = route(round)

    %{
      round
      | inventory:
          World.production_options(round.route.world_ref, round.observation.self.entity_id)
    }
  end

  defp inventory(round), do: round

  defp topic_targets(scene, cid) do
    {:ok, MapSet.new(Scene.dialogue_topic_targets(scene, cid))}
  catch
    :exit, {reason, {GenServer, :call, _}} -> {:error, reason}
  end

  @doc """
  生成器（build / gather / expand / travel 的过渡形态）：作者登记的候选（`profile.activities`，`NpcServer.Registry` 构造）
  按建筑条件保序过滤——带 `requires_building` 的项只在 `buildings` 里有至少一座同名且站着时列出——每项经 `static/1`
  加上种类与对象。参数仍是作者手写的；批 1 起由各种类自己的生成器替代。对人的登记项（`run: {:person, …}`）不在这里列，
  由 `people/2` 按人展开。
  """
  def registered(activities, buildings) do
    standing = for %{name: name, standing: true} <- buildings, into: MapSet.new(), do: name

    for activity <- activities,
        not person?(activity),
        not Map.has_key?(activity, :requires_building) or
          MapSet.member?(standing, activity.requires_building),
        do: static(activity)
  end

  @doc "登记项作为候选（静态种类）：原样加 `kind`（= 候选名）与 `object`（nil）。"
  def static(%{name: name} = activity), do: Map.merge(activity, %{kind: name, object: nil})

  @doc """
  生成器（对人的登记项，K-0 复测后用户定可点名）：每项 `run: {:person, 选择器, 停留}` 的登记，按作者条件（选择器，
  `NpcServer.Mind.people/3` 判定）把此刻观察里满足条件的每个人展开成一个候选，登记次序在外、条件给的人序在内。
  `sight` 是 `%{observation: 本轮观察, relationships: 这次发问的 Life 视图里的信任}`。

  种类 = 登记名（计划与记账用它，`objects: :people`），对象 `%{"actor" => cid}`；候选名 `<登记名>:<cid>`，从已有登记名避让
  （同 `speak_to/2`）；判据是作者原句后接一句 `That person is <名字> (actor <cid>).`（**原创措辞**，未离线测）；登记的地名原样带上。
  目标身份与代次冻结在 `target`（与说话候选同形、同一条冻结路径：Runtime 交给树，树按种类 travel 过去、待登记的停留）；
  执行时不再选人，目标离开或走远由 travel 失败报出（`stale_target` / `target_moved`）。没有一个人满足条件，这一项此刻就没有候选。
  """
  def people(registered, %{observation: observation, relationships: relationships}) do
    names = MapSet.new(registered, & &1.name)

    for %{run: {:person, selector, _ticks}} = activity <- registered,
        entity <- NpcServer.Mind.people(selector, observation, relationships) do
      %{"name" => name} = target = person_target(entity)

      %{
        name: vacant_name("#{activity.name}:#{entity.entity_id}", names),
        kind: activity.name,
        object: %{"actor" => entity.entity_id},
        criterion: "#{activity.criterion} That person is #{name} (actor #{entity.entity_id}).",
        place_name: activity.place_name,
        target: target
      }
    end
  end

  defp person?(%{run: {:person, _selector, _ticks}}), do: true
  defp person?(_activity), do: false

  # 候选冻结的人（说话与对人的登记项共用）：身份与代次，加上给模型看、给 speak 技能用的名字（`State.person_name/1`）。
  defp person_target(%{entity_id: id, entity_epoch: epoch, name: actor_name}),
    do: %{"entity_id" => id, "entity_epoch" => epoch, "name" => State.person_name(actor_name)}

  @doc """
  生成器（speak）：把本轮观察里说话范围内（`SceneServer.Dialogue.limits/0` 的 `range_m`，含恰在范围上）、有位置的其他角色
  投影成说话候选，保持观察次序。目标身份与代次冻结在 `target` 里；候选名 `speak_to:<cid>` 从已有登记名避让重名
  （占了就往后加下划线）。最终接纳由 Scene 对着发言时刻的角色表裁决。
  """
  def speak_to(registered, %{self: self} = observation) do
    %{range_m: range} = SceneServer.Dialogue.limits()
    names = MapSet.new(registered, & &1.name)

    for %{entity_id: id, entity_epoch: _, name: _, position: {_, _, _} = position} = entity <-
          State.others(observation),
        State.distance(self.position, position) <= range do
      %{"name" => name} = target = person_target(entity)

      %{
        name: vacant_name("#{@speak}:#{id}", names),
        kind: @speak,
        object: %{"actor" => id},
        criterion: "Walk up to #{name} (actor #{id}) and say one thing to them.",
        place_name: nil,
        target: target
      }
    end
  end

  @doc """
  说话一类的种类名（`"speak_to"`）：`NpcServer.Trees.npc/1` 按选择应答里冻结的 `kind` 分辨说话与对人的登记项
  （两者都冻结 `target`），这里是它唯一的定义。
  """
  def speak_kind, do: @speak

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
  生成器（eat，批 1）：World 列出的“此刻能吃一份”的材料各成一个候选。`options` 是 `World.production_options/2` 的结果
  （`candidates/4` 每轮现读一次）；能不能吃（可食、生产材料、余额够一份）由 World 与提交同一处判定，这里不再过滤。
  按材料号升序给出完整列表（候选次序是本模块的策略；每类截断在 `candidates/4`）。种类 `"eat"`、对象 `%{"material" => 材料号}`；
  候选名 `eat:<材料号>` 从已有登记名避让（同 `speak_to/2`）；执行参数冻结在 `action: {"eat", %{"material" => 材料号}}`，
  World 仍做最后裁决（执行时余额已不够回 `insufficient_material`）。
  """
  def eat(registered, %{eat: edible}) do
    names = MapSet.new(registered, & &1.name)

    for row <- Enum.sort_by(edible, & &1.material),
        do:
          inventory_candidate(
            :eat,
            row.material,
            names,
            "Eat one serving of #{material_label(row)} from my inventory."
          )
  end

  @doc """
  生成器（craft，批 1）：World 列出的“此刻能合成一次”的产物各成一个候选（配方每条输入够不够由 World 判定，同 `eat/2`）。
  排序、种类、对象、避让与冻结同 `eat/2`：种类 `"craft"`、对象是产物的材料号、`action: {"craft", %{"material" => 产物}}`；
  World 执行时输入已不够回 `insufficient_material`。
  """
  def craft(registered, %{craft: craftable}) do
    names = MapSet.new(registered, & &1.name)

    for row <- Enum.sort_by(craftable, & &1.material),
        do:
          inventory_candidate(
            :craft,
            row.material,
            names,
            "Craft #{material_label(row)} from materials in my inventory."
          )
  end

  defp inventory_candidate(generator, id, names, criterion) do
    act = @acts[generator]

    %{
      name: vacant_name("#{act}:#{id}", names),
      kind: act,
      object: %{"material" => id},
      criterion: criterion,
      place_name: nil,
      action: {act, %{"material" => id}}
    }
  end

  # 判据里材料的叫法：目录有显示名时 `名字 (material <号>)`（名字原样），没有时 `material <号>`。
  defp material_label(%{material: id, name: nil}), do: "material #{id}"
  defp material_label(%{material: id, name: name}), do: "#{name} (material #{id})"

  @doc """
  日计划可以写的种类（稿 A §4 A-5，批 0b；批 1 加进食与合成），按生成器次序（`generators/1`）：

  - 登记的每个候选各是一个静态种类（种类名 = 候选名，判据原样，不论建筑条件——计划是一天的打算，眼下不可行也可以先写下）；
  - 对人的登记项各是一个对象为人的种类（种类名 = 登记名，判据原样，`objects: :people`；此刻没有人满足条件也可以先写下）；
  - 配了 speak 技能时说话一类（对象是人）；
  - 进食、合成各一类（对象是材料，计划里**不可点名**——原创决策，统筹定：计划只说“吃点东西 / 做点东西”，背包里有什么由
    每轮的候选决定；眼下背包里没有可吃 / 可合成的也可以先写下）。

      [%{kind: 种类, criterion: 判据, objects: :none | :people}]

  没有候选表的形态（profile 没有 `activities`，不在选择层选活动）没有任何种类；候选表为空也有进食与合成（登记边界不接受空表，
  `NpcServer.Registry.brain/2`）。具体能点名哪些人由 Life 起规划槽时展开（`NpcServer.Life` 的“日计划”）；
  种类的名字必须互不相同，登记边界据此拒绝与生成种类同名的候选。
  """
  def plan_kinds(%{activities: _} = profile),
    do: Enum.flat_map(generators(@coverage), &kinds(&1, profile))

  def plan_kinds(_profile), do: []

  # 一个生成器给计划的种类。判据是种类层的一句英文（**原创措辞**，与候选判据同一写法、去掉具体对象；实跑后再调）。
  defp kinds(:registered, %{activities: activities}),
    do:
      for(
        %{name: name, criterion: criterion} = activity <- activities,
        not person?(activity),
        do: %{kind: name, criterion: criterion, objects: :none}
      )

  # 对人的登记项：种类名 = 登记名、判据是作者原句，对象是人（能点名哪些人由 Life 起槽时展开，同说话一类）。
  defp kinds(:people, %{activities: activities}),
    do:
      for(
        %{name: name, criterion: criterion} = activity <- activities,
        person?(activity),
        do: %{kind: name, criterion: criterion, objects: :people}
      )

  defp kinds(:speak_to, %{skills: %{speak: _}}),
    do: [
      %{
        kind: @speak,
        criterion: "Walk up to someone and say one thing to them.",
        objects: :people
      }
    ]

  defp kinds(:speak_to, _profile), do: []

  defp kinds(:eat, _profile),
    do: [
      %{
        kind: @acts[:eat],
        criterion: "Eat one serving of something edible from my inventory.",
        objects: :none
      }
    ]

  defp kinds(:craft, _profile),
    do: [
      %{
        kind: @acts[:craft],
        criterion: "Craft something from materials in my inventory.",
        objects: :none
      }
    ]

  defp vacant_name(name, names) do
    if MapSet.member?(names, name), do: vacant_name(name <> "_", names), else: name
  end
end
