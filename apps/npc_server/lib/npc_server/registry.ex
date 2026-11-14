defmodule NpcServer.Registry do
  @moduledoc """
  全局系统功能：NPC 注册表（docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §2）。运维登记一次，节点重启后
  自动回来：一行 `DataService.NpcSpecs`（`npc_specs` 表）= 一个 NPC 的名字（永久身份，`CharacterStore.ensure_npc/1`）、
  入场 Scene、出生点、大脑名与它的 JSON 形参数。运维经 release `rpc` 调 `put/2` / `remove/1` / `list/0`；NPC 正式监督树在
  `NpcServer.BodySupervisor` 之后起常驻 `NpcServer.Bootstrap` 调 `start_all/0`。

  信任边界在登记：`put/2` 先把参数规范化成 JSON 形（存的与解析的是同一份），再经 `brain/2` 解析成 `{大脑模块, profile}`
  并当场校验（建树、投影工具表、巡逻路线），任何一步 raise 都变成 `{:error, {:invalid_params, 说明}}`，不落库、不起 Body。
  `start_all/0` 读回的是持久化数据，按同一个函数再解析一次（持久化加载也是信任边界）。

  `brain/2` 是唯一把 JSON 参数变成 `{模块, profile}` 的地方：

  | brain | 模块 | params（JSON） |
  |---|---|---|
  | `"npc"` | `Brain.Tree` + `Trees.npc/1` + `Life` | 统一形态（控制链“选择 → 执行”加心智与记忆，见下）：`who`、`persona`、`activities`、`tools`（必填）；必带 Life（规则模式），`life` 省略时从 `NPC_LIFE_HINDSIGHT_URL` 取服务地址，也可显式给 `life: %{"url" => ...}`，不能是 `false`。Jev 的 endpoint 不入库：每次解析时取运行环境 `TYPESAFE_API_URL` / `TYPESAFE_API_KEY` / `TYPESAFE_MODEL`（必须）；反思写日记的 endpoint（profile 的 `reflect`，`Life.Reflection.Writer`）同样不入库，取 `NPC_REFLECT_URL`（完整的 `/v1/messages` 地址）/ `NPC_REFLECT_KEY` / `NPC_REFLECT_MODEL`（必须） |
  | `"settler"` | `Brain.Tree` + `Trees.settler/1` | `definition`、`sites`、`quarries`（可缺省）、`revisit_ticks`、`tools`、`expansion`（可缺省：`{"region": [[x0, z0], [x1, z1]], "spacing": n ≥ 0, "tool_id": t}`）；技能固定 build / gather / travel，配了 expansion 再加 expand |
  | `"llm"` | `Brain.Llm` | `goal`、`tools`（必填）；`groups`、`skills`（build / gather / expand / travel；design_house 带会话预算 `design_budget`，缺省 12 轮 / 240 000 token / 每轮输出 4096）、`spells`、`max_requests_per_hour`、`genesis`（可选）。endpoint 不入库：每次解析时取运行环境 `NPC_LLM_URL` / `NPC_LLM_KEY` / `NPC_LLM_MODEL`（必须）与 `NPC_LLM_EFFORT` / `NPC_LLM_CACERTFILE` / `NPC_LLM_TIMEOUT_MS`（可选） |
  | `"life"` | `Brain.Llm` + `Life` + `Memory` | 独立可选的人生后端，复用 `llm` 参数；强制启用 `life`，省略时从 `NPC_LIFE_HINDSIGHT_URL` 取服务地址，也可显式给 `life: %{"url" => ...}`。默认 60 次/小时，上限 60；当前意图、笔记、心智与 Hindsight 由既有 owner 提供 |
  | `"patrol"` | `Brain.Patrol` | `route`（≥ 2 个 `[x, z]`）、`dig`（可缺省） |

  `"npc"` 的参数（目标形态，以后的薄片把其余形态并进来）：

      who         英文自称（名字与身份，如 "Lin, a builder"），给 Jev 的人格描述以它开头；注册名可以是中文，不进模型。
      persona     人格卡 {"traits": {高标记形容词: 1..9}, "personal": 英文自由文本}，由 `NpcServer.Persona.new/1` 校验。
      activities  有序候选表（非空，名字唯一；次序即给 Jev 的次序）。每项：
                    {"name": 候选名, "criterion": 给 Jev 当判据的一句英文, "skill": 技能名, "args": 技能参数（JSON 形，原样透传）}
                    {"name": 候选名, "criterion": 同上, "place": [x, z], "stay_ticks": 待多久（tick，60 Hz，正整数）}
                    {"name": 候选名, "criterion": 同上, "person": 选择器, "stay_ticks": 同上}
                  技能只能是 build / gather / expand / travel（参数见 `NpcServer.Brain` 的共用技能命令）；去处由 travel 走过去。
                  “去找某人”的选择器只有 "distrusted"（附近信任 ≤ −0.2 中最低的那个人，`NpcServer.Mind.person/2`），
                  选中时由 travel 走到他身边再待 stay_ticks。每项恰好四个键：place 与 person 同写、未知选择器都被拒。
                  三种形状都可以另加第五个键 "place_name"：这项活动在哪里的名字（非空字符串，如 "the plaza"）。
                  它只进记忆：活动结束时 Life 把它写成那条经历的 `place:<地名>` tag，召回按地点调取（`NpcServer.Life.activity/2`）；
                  不进给 Jev 的候选，也不决定去哪里。空串、非字符串被拒；不写就是没有地名（profile 里为 nil）。
      tools       工具带（同 settler）。
      life        可省略。统一形态必带 Life：情绪与关系、近期经历、Hindsight 的认识与召回都经它进心智快照（`NpcServer.Mind`）。
                  省略或 true → Hindsight 地址取运行环境 `NPC_LIFE_HINDSIGHT_URL`（没有即拒绝登记）；`{"url": 地址}` 显式给出；
                  false 被拒。情绪评价是规则模式；不套 `Brain.Social`（情绪只通过快照影响 Jev 的选择）。

  profile 的技能表由候选推出（用到哪些技能就配哪些；有去处或“去找某人”就加 travel），不另写 `skills`。选择不用 LLM 接口
  （Hindsight 服务自己的后台巩固用它自己的模型）；只有 Life 的反思写日记要一个（`NPC_REFLECT_*`，见上表）。

  JSON 里工具带与采石盒的键是字符串化的整数（`{"1": "镐"}`）。创世授予（`NpcServer.Genesis`）只来自 llm / life 行的
  `genesis: true`：它同时成为 `profile.genesis`（投影创世条目）与 Body 启动选项 `genesis`（Body 受理 `genesis_edit`）。

  在跑的 Body 按 cid 登记在 `NpcServer.Names`（`Body.start/2` 填）。同名再登记先停旧 Body 再起新的：不能只靠 claim 顶替，
  旧 Body 若正处于重新 claim，稍后会反过来顶掉新的（`Body.start/2` 的说明）。不做：位置持久化（与玩家同义）、Web / CLI 界面、
  多节点分布。
  """
  require Logger
  alias DataService.NpcSpecs
  alias NpcServer.{Abilities, Body, Brain, Persona, Trees}

  @names NpcServer.Names
  # 注册表可登记的技能：build / gather / expand / travel 无配置；design_house 的配置只有会话预算（params 的 `design_budget`，缺省同
  # D2 验收配置），模型接口与大脑同一个 endpoint。wilderness 需要调度器端点，没有 JSON 形配置，仍用代码起。
  @skills %{
    "build" => :build,
    "gather" => :gather,
    "expand" => :expand,
    "travel" => :travel,
    "design_house" => :design_house
  }
  @design_budget %{rounds: 12, tokens: 240_000, max_output_tokens: 4096}
  # 统一形态的候选活动可用的技能：都不需要模型接口（design_house 要 LLM，不在其中）。
  @activity_skills %{
    "build" => :build,
    "gather" => :gather,
    "expand" => :expand,
    "travel" => :travel
  }
  # “去找某人”候选可用的选择器（`NpcServer.Mind.person/2`）：现在只有 confront_wrecker 要用的 distrusted。
  @people %{"distrusted" => :distrusted}
  # 一次 Jev 请求的超时（毫秒）。选择是秒级决策（离线实验 4,076 次里最慢 3.12 秒），不沿用给 LLM 定的 60 秒缺省。
  @jev_timeout_ms 10_000
  @life_llm_limit 60

  @type spec :: %{
          scene_id: non_neg_integer(),
          spawn: {number(), number(), number()},
          brain: String.t(),
          params: map()
        }

  @doc """
  登记（或改登记）名为 `name` 的 NPC 并（重）启它：参数不合法 → `{:error, {:invalid_params, 说明}}`，不落库、不建角色；
  否则建 / 取 NPC 角色行、写注册表行（`enabled = true`）、停掉同 cid 在跑的 Body、`Body.start/2` → `{:ok, %{cid:, pid:}}`。

      NpcServer.Registry.put("创世者", %{scene_id: 1, spawn: {4.0, 66.0, 10.0}, brain: "llm",
        params: %{"goal" => "把出生点西边整平", "tools" => %{}, "genesis" => true}})
  """
  @spec put(String.t(), spec()) :: {:ok, %{cid: integer(), pid: pid()}} | {:error, term()}
  def put(name, %{scene_id: scene_id, spawn: {_, _, _} = spawn, brain: brain, params: params})
      when is_binary(name) and is_integer(scene_id) and is_binary(brain) do
    with {:ok, json, parsed} <- parse(brain, params) do
      {:ok, character} = DataService.CharacterStore.ensure_npc(name)

      :ok =
        NpcSpecs.upsert(character.id, %{
          scene_id: scene_id,
          spawn: spawn,
          brain: brain,
          params: json
        })

      restart(name, character.id, scene_id, spawn, parsed)
    end
  end

  @doc "停用名为 `name` 的 NPC 并停掉它的 Body；角色行、余额、记忆与注册表行都保留（cid 永不复用）。没有这个登记 → `{:error, :not_found}`。"
  def remove(name) do
    with {:ok, cid} <- NpcSpecs.disable(name) do
      stop(cid)
      :ok
    end
  end

  @doc "全部注册表行（`DataService.NpcSpecs.list/0` 的行），各加 `running`：本节点上是否有这个 cid 的 Body 在跑。"
  def list,
    do: for(row <- NpcSpecs.list(), do: Map.put(row, :running, running(row.cid) != []))

  @doc """
  拉起全部 enabled 行（应用启动或上游监督器恢复时由 Bootstrap 调用；手动再调也只是逐个重启）。Scene 还没就绪没关系：
  Body 自己 1 秒后重试 claim。逐行返回 `[{name, {:ok, %{cid:, pid:}} | {:error, 原因}}]`，每行记一条
  `npc_registry_start name= cid= brain= result=`；一行失败不影响其余行。
  """
  def start_all do
    for %{enabled: true} = row <- NpcSpecs.list() do
      result =
        with {:ok, _json, parsed} <- parse(row.brain, row.params),
             do: restart(row.name, row.cid, row.scene_id, row.spawn, parsed)

      line =
        "npc_registry_start name=#{row.name} cid=#{row.cid} brain=#{row.brain} result=#{inspect(result)}"

      if match?({:ok, _}, result), do: Logger.info(line), else: Logger.error(line)
      {row.name, result}
    end
  end

  @doc """
  注册表行的大脑名与 JSON 形参数 → `{大脑模块, profile}`（形状见 moduledoc 的表）。参数不合法时 raise：缺必填键、类型不对、
  建树失败（`Brain.Tree.init/1`）、工具表投影失败（`Abilities.tools/1`）、巡逻路线不足两点（`Brain.Patrol.init/1`）、
  组名不在本 profile 的条目里、llm 的运行环境没有模型接口；npc 的人格卡不合法、候选表为空或重名、候选的地名不是非空字符串、
  运行环境没有 Jev 接口或反思写日记的接口（`NPC_REFLECT_*`）、
  `life` 为 false 或没有 Hindsight 地址。
  """
  def brain(
        "npc",
        %{"who" => who, "persona" => persona, "activities" => activities, "tools" => tools} =
          params
      )
      when is_binary(who) and is_list(activities) do
    if Map.get(params, "life") == false,
      do: raise(ArgumentError, "npc 必带 Life，不能配置 life=false")

    card =
      case Persona.new(persona) do
        {:ok, card} -> card
        {:error, reason} -> raise ArgumentError, "persona 不合法：#{inspect(reason)}"
      end

    activities = Enum.map(activities, &activity/1)
    names = Enum.map(activities, & &1.name)

    if activities == [], do: raise(ArgumentError, "activities 不能为空")

    if names != Enum.uniq(names),
      do: raise(ArgumentError, "activities 的 name 重复：#{inspect(names -- Enum.uniq(names))}")

    profile = %{
      tree: &Trees.npc/1,
      who: who,
      persona: card,
      activities: activities,
      tools: belt(tools),
      # 技能表由候选推出：技能候选用到的技能，去处与“去找某人”候选用 travel。
      skills:
        Map.new(activities, fn
          %{run: {:skill, name, _}} -> {Map.fetch!(@activity_skills, name), %{}}
          %{run: {:place, _, _}} -> {:travel, %{}}
          %{run: {:person, _, _}} -> {:travel, %{}}
        end),
      jev: %{
        url: System.fetch_env!("TYPESAFE_API_URL"),
        key: System.fetch_env!("TYPESAFE_API_KEY"),
        model: System.fetch_env!("TYPESAFE_MODEL"),
        timeout_ms: @jev_timeout_ms
      },
      # 反思写日记的接口（`NpcServer.Life.Reflection.Writer`，Anthropic Messages 形状）：同 Jev，不入库，每次解析时取运行环境。
      reflect: %{
        url: System.fetch_env!("NPC_REFLECT_URL"),
        key: System.fetch_env!("NPC_REFLECT_KEY"),
        model: System.fetch_env!("NPC_REFLECT_MODEL")
      }
    }

    # 建树即校验：能力名与节点形状（与 Body 起树同一个函数）。
    Brain.Tree.init(profile)

    # 必带 Life：不套 Brain.Social，Runtime 按规则模式起 Life，心智经快照进选择。
    {Brain.Tree, with_life(profile, Map.put_new(params, "life", true))}
  end

  def brain(
        "settler",
        %{
          "definition" => definition,
          "sites" => sites,
          "revisit_ticks" => revisit,
          "tools" => tools
        } =
          params
      )
      when is_binary(definition) and is_list(sites) and is_integer(revisit) and revisit > 0 do
    profile = %{
      tree: &Trees.settler/1,
      definition: definition,
      sites: Enum.map(sites, &site/1),
      quarries: Map.new(Map.get(params, "quarries", %{}), &quarry/1),
      revisit_ticks: revisit,
      tools: belt(tools),
      skills: %{build: %{}, gather: %{}, travel: %{}}
    }

    # 可选的扩张区域（放置阶段决策稿 §7）：配了才有 expansion 与 expand 技能，Settler 树才多一步扩张。
    profile =
      case Map.fetch(params, "expansion") do
        {:ok, expansion} ->
          %{profile | skills: Map.put(profile.skills, :expand, %{})}
          |> Map.put(:expansion, expansion(expansion))

        :error ->
          profile
      end

    # 建树即校验：能力名、静态参数（如 read_catalog 的定义 id）与节点形状，不合法 raise（与 Body 起树同一个函数）。
    Brain.Tree.init(profile)
    profile = with_life(profile, params)
    {if(Map.has_key?(profile, :life), do: Brain.Social, else: Brain.Tree), profile}
  end

  # 独立登记名只负责强制组成完整人生能力；决策、记忆与预算规则继续由原 owner 维护。
  def brain("life", params) when is_map(params) do
    if Map.get(params, "life") == false,
      do: raise(ArgumentError, "life 后端不能配置 life=false")

    brain("llm", Map.put_new(params, "life", true))
  end

  def brain("llm", %{"goal" => goal, "tools" => tools} = params) when is_binary(goal) do
    profile =
      %{
        goal: goal,
        tools: belt(tools),
        endpoint: endpoint(),
        skills: Map.new(Map.get(params, "skills", []), &skill(&1, params)),
        spells: Map.new(Map.get(params, "spells", %{}), &spell/1),
        genesis: flag(Map.get(params, "genesis", false)),
        cadence: cadence(Map.get(params, "cadence", "automatic")),
        groups: nil
      }
      |> Map.merge(
        case Map.fetch(params, "max_requests_per_hour") do
          {:ok, "unlimited"} ->
            %{max_requests_per_hour: :infinity}

          {:ok, limit} when is_integer(limit) and limit > 0 ->
            %{max_requests_per_hour: limit}

          :error ->
            %{}

          {:ok, value} ->
            raise ArgumentError, "max_requests_per_hour 必须是正整数或 unlimited，收到 #{inspect(value)}"
        end
      )

    profile = %{profile | groups: groups(profile, Map.get(params, "groups"))}

    # 投影一次即校验技能与法术（与每次模型请求的工具表同一个函数）。
    Abilities.tools(profile)
    profile = with_life(profile, params)

    profile =
      if Map.has_key?(profile, :life) do
        limit = Map.get(profile, :max_requests_per_hour, @life_llm_limit)

        if limit != :infinity and limit > @life_llm_limit,
          do:
            raise(
              ArgumentError,
              "启用 Life 时 max_requests_per_hour 必须在 1..#{@life_llm_limit}，收到 #{limit}"
            )

        Map.put(profile, :max_requests_per_hour, limit)
      else
        profile
      end

    {Brain.Llm, profile}
  end

  def brain("patrol", %{"route" => route} = params) do
    profile = %{route: Enum.map(route, &point/1), dig: dig(Map.get(params, "dig"))}
    # Patrol.init 要求至少两个路点。
    Brain.Patrol.init(profile)
    {Brain.Patrol, profile}
  end

  defp cadence("automatic"), do: :automatic
  defp cadence("manual"), do: :manual

  defp cadence(value),
    do: raise(ArgumentError, "cadence 必须是 automatic 或 manual，收到 #{inspect(value)}")

  # JSON 规范化 + 解析；任何一步 raise 都是参数不合法（登记被拒，或 start_all 跳过这一行）。
  defp parse(brain, params) do
    json = params |> Jason.encode!() |> Jason.decode!()
    {:ok, json, brain(brain, json)}
  rescue
    error -> {:error, {:invalid_params, Exception.message(error)}}
  end

  # 缺省关闭；登记边界只接受正式可配置 URL，不把测试依赖写进 JSON 档案。
  defp with_life(profile, params) do
    case Map.get(params, "life", false) do
      false ->
        profile

      true ->
        Map.put(profile, :life, %{url: life_url!(System.fetch_env!("NPC_LIFE_HINDSIGHT_URL"))})

      %{"url" => url} = options when map_size(options) == 1 ->
        Map.put(profile, :life, %{url: life_url!(url)})
    end
  end

  defp life_url!(url) when is_binary(url) do
    uri = URI.parse(url)
    true = uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.userinfo == nil
    url
  end

  defp restart(name, cid, scene_id, spawn, {module, profile}) do
    stop(cid)

    with {:ok, pid} <-
           Body.start(name,
             scene_id: scene_id,
             spawn: spawn,
             brain: {module, profile},
             genesis: Map.get(profile, :genesis, false)
           ),
         do: {:ok, %{cid: cid, pid: pid}}
  end

  defp stop(cid) do
    for pid <- running(cid), do: DynamicSupervisor.terminate_child(NpcServer.BodySupervisor, pid)
    :ok
  end

  defp skill("design_house", params),
    do: {:design_house, %{budget: design_budget(Map.get(params, "design_budget", %{}))}}

  defp skill(name, _params), do: {Map.fetch!(@skills, name), %{}}

  # 会话预算：给了的键覆盖缺省，每项必须是正整数。
  defp design_budget(budget) when is_map(budget) do
    Map.new(@design_budget, fn {key, default} ->
      value = Map.get(budget, Atom.to_string(key), default)
      true = is_integer(value) and value > 0
      {key, value}
    end)
  end

  # 重复键 Registry 的条目在进程退出后异步清理：只算还活着的（Body 都在本节点的 NpcSup 下）。
  defp running(cid),
    do: for({pid, _} <- Registry.lookup(@names, cid), Process.alive?(pid), do: pid)

  defp endpoint do
    optional =
      for {key, env} <- [effort: "NPC_LLM_EFFORT", cacertfile: "NPC_LLM_CACERTFILE"],
          value = System.get_env(env),
          into: %{},
          do: {key, value}

    # 可选的单次请求超时（毫秒，正整数），缺省用 `NpcServer.Http` 的值。
    timeout =
      case System.get_env("NPC_LLM_TIMEOUT_MS") do
        nil -> %{}
        text -> %{timeout_ms: String.to_integer(text) |> tap(&(true = &1 > 0))}
      end

    Map.merge(
      %{
        url: System.fetch_env!("NPC_LLM_URL"),
        key: System.fetch_env!("NPC_LLM_KEY"),
        model: System.fetch_env!("NPC_LLM_MODEL")
      },
      Map.merge(optional, timeout)
    )
  end

  # 组名只取本 profile 的条目里出现的组（如没授予创世就没有 :genesis）；nil = 全部组。
  defp groups(_profile, nil), do: nil

  defp groups(profile, names) when is_list(names) do
    known = MapSet.new(Abilities.entries(profile), & &1.group)

    for name <- names do
      group = String.to_existing_atom(name)

      MapSet.member?(known, group) ||
        raise ArgumentError, "unknown ability group #{inspect(name)}"

      group
    end
  end

  defp belt(tools) when is_map(tools),
    do: Map.new(tools, fn {id, text} when is_binary(text) -> {String.to_integer(id), text} end)

  defp site(%{
         "anchor_micro" => [x, y, z] = anchor,
         "orientation" => o,
         "stand" => [sx, sz] = stand
       })
       when is_integer(x) and is_integer(y) and is_integer(z) and o in 0..23 and is_number(sx) and
              is_number(sz),
       do: %{anchor_micro: anchor, orientation: o, stand: stand}

  defp quarry({material, %{"box" => [[_, _, _], [_, _, _]] = box, "tool_id" => tool}})
       when is_integer(tool),
       do: {String.to_integer(material), %{box: box, tool_id: tool}}

  defp expansion(%{
         "region" => [[x0, z0], [x1, z1]] = region,
         "spacing" => spacing,
         "tool_id" => tool
       })
       when is_integer(x0) and is_integer(z0) and is_integer(x1) and is_integer(z1) and
              is_integer(spacing) and spacing >= 0 and is_integer(tool),
       do: %{region: region, spacing: spacing, tool_id: tool}

  # 统一形态的一项候选：技能调用，去一个地点待一段时间，或去找某人（按选择器）待一段时间；可选的地名 place_name
  # （非空字符串）先拿出来，其余四个键按三种形状之一校验。没写地名的候选 place_name 为 nil。
  defp activity(%{"place_name" => place_name} = json)
       when is_binary(place_name) and place_name != "",
       do: %{activity(Map.delete(json, "place_name")) | place_name: place_name}

  defp activity(
         %{"name" => name, "criterion" => criterion, "skill" => skill, "args" => args} = json
       )
       when map_size(json) == 4 and is_binary(name) and name != "" and is_binary(criterion) and
              is_map_key(@activity_skills, skill) and is_map(args),
       do: %{name: name, criterion: criterion, run: {:skill, skill, args}, place_name: nil}

  defp activity(
         %{
           "name" => name,
           "criterion" => criterion,
           "place" => [x, z] = place,
           "stay_ticks" => ticks
         } =
           json
       )
       when map_size(json) == 4 and is_binary(name) and name != "" and is_binary(criterion) and
              is_number(x) and is_number(z) and is_integer(ticks) and ticks > 0,
       do: %{name: name, criterion: criterion, run: {:place, place, ticks}, place_name: nil}

  defp activity(
         %{"name" => name, "criterion" => criterion, "person" => person, "stay_ticks" => ticks} =
           json
       )
       when map_size(json) == 4 and is_binary(name) and name != "" and is_binary(criterion) and
              is_map_key(@people, person) and is_integer(ticks) and ticks > 0,
       do: %{
         name: name,
         criterion: criterion,
         run: {:person, Map.fetch!(@people, person), ticks},
         place_name: nil
       }

  defp spell({name, program}) when is_binary(program), do: {name, program}
  defp flag(value) when is_boolean(value), do: value
  defp point([x, z]) when is_number(x) and is_number(z), do: {x, z}
  defp dig(nil), do: nil

  defp dig(%{"direction" => [dx, dy, dz], "tool_id" => tool})
       when is_number(dx) and is_number(dy) and is_number(dz) and is_integer(tool),
       do: %{direction: {dx, dy, dz}, tool_id: tool}
end
