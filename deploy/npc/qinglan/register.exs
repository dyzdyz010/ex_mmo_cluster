# 青岚首批 NPC 登记包的登记脚本：运维经 release rpc 执行（登记前的核对、命令与停用见 deploy/README.md“青岚 NPC 登记包”）。
#
#   bin/voxim_server rpc 'Code.eval_string(File.read!("<dir>/register.exs"), residents_file: "<dir>/residents.json")'
#
# `residents_file` 是同目录 residents.json 在 release 节点上的路径。登记参数的权威说明是 `NpcServer.Registry` 的 moduledoc；
# 本脚本不校验参数，只把数据文件拼成 `Registry.put/2` 的入参（三人共用 tools 与 activities，各自的名字、出生点、who、persona），
# 合法性由登记边界判一次。
#
# 次序与理由（本节是发布次序、幂等与重跑语义的唯一说明，README 只链接这里）：
#   0. 登记任何人之前，先读 World 的发布元信息（`VoxelRegion.World.published_prefab_metadata/1`，只读，不需要会话），
#      看建造活动的定义是否已发布、名字是否就是该活动的 place_name：
#        - 已以同名发布 → 之后跳过发布；
#        - 已以别的非空名字发布 → raise，一人不登记。World 保留首个发布名（`VoxelRegion.World.Prefabs.persist_prefab/5`），
#          重发改不了名，只能把 residents.json 里建造活动与同名去处的 place_name（及 criterion 里的称呼）改成那个名字；
#        - 已以空名发布（如 NPC design_house 发布）→ raise，一人不登记。空名的定义在 Mind 里没有名字，place_name 又不能为空，
#          只能换一个定义。
#   1. 登记第一位居民，等它的 Body 取得正式 Scene 会话（`NpcServer.Body.skill_context/1`，最多 30 秒）。
#   2. 尚未发布时，用这位居民自己的会话把定义以 place_name 发布一次（`VoxelRegion.World.publish_prefab/4`：玩家发布与
#      NPC design_house 技能用的同一个入口，主体是角色，过同一道角色门）。发布由运维发起、以这位居民的会话署名，
#      审计记录是本脚本打印的 `npc_qinglan_publish` 一行。不起额外的发布角色，也不用 Test-only 入口。
#      为什么要在任何人第一次建成之前：发布名就是 Mind 里 `My building "<名>" at (…)` 与建筑经历用的名字，Life 读入建造事件时
#      按当时的发布元信息定名（`NpcServer.Life` 的 buildings/2），之后不再改写。新居民余额为 0，要先采够石料才建得成，
#      第 2 步在那之前就完成。
#   3. 登记其余居民。
#
# 失败：`Registry.put/2` 返回 `{:error, _}` 时打印该人一行，第一人失败即 raise；其余人逐个登记完再一起 raise。
# `Registry.put/2` 内部的 match（建角色、写登记行）以及本脚本的读回 match 失败时会直接 raise（MatchError 等），
# 后面的人不再登记。不论哪种，rpc 都以非零退出；已登记到哪一步看已打印的 `npc_qinglan_register` / `npc_qinglan_publish` 行。
# 发布失败时第一位居民已登记并在跑；不能马上修好重跑就先 `NpcServer.Registry.remove/1` 停掉它（见 README）。
#
# 重跑：整份可重跑。同名再登记是改登记（同一 cid，Body 重启）；第 0 步看到已同名发布就跳过发布。
# 脚本的值是 `[{注册名, cid 或 nil, Registry.put/2 的结果}]`。

alias NpcServer.{Body, Registry}
alias VoxelRegion.World

%{"scene_id" => scene_id, "tools" => tools, "activities" => activities, "residents" => [first | rest]} =
  residents_file |> File.read!() |> Jason.decode!()

# 建造活动（本包恰有一项）：要发布的定义与名字都取自它，不另写一份。
[%{"args" => %{"definition" => definition}, "place_name" => building}] =
  for %{"skill" => "build"} = activity <- activities, do: activity

id = Base.decode16!(definition, case: :lower)

published_names = fn world ->
  for row <- World.published_prefab_metadata(world), row.id == id, do: {row.name, row.publisher}
end

register = fn %{"name" => name, "spawn" => [x, y, z], "who" => who, "persona" => persona} ->
  params = %{"who" => who, "persona" => persona, "tools" => tools, "activities" => activities}
  result = Registry.put(name, %{scene_id: scene_id, spawn: {x, y, z}, brain: "npc", params: params})
  cid = with {:ok, %{cid: cid}} <- result, do: cid, else: (_ -> nil)
  IO.puts("npc_qinglan_register name=#{name} cid=#{inspect(cid)} result=#{inspect(result)}")
  {name, cid, result}
end

# Body 起来后要先完成 Scene claim 才有会话；Scene 已就绪时通常一两秒内完成，这里最多等 30 秒。
await_session = fn await, name, pid, tries ->
  case Body.skill_context(pid) do
    {:ok, context} ->
      context

    {:error, reason} when tries == 0 ->
      raise "#{name} 的 Body 30 秒内没有取得 Scene 会话（#{inspect(reason)}）；#{name} 已登记，未发布、未登记其余居民"

    {:error, _} ->
      Process.sleep(250)
      await.(await, name, pid, tries - 1)
  end
end

# 第 0 步：发布状态与冲突（World 是本节点注册名 `VoxelRegion.World`，只读）
publish? =
  case published_names.(World) do
    [] ->
      true

    [{^building, _}] ->
      false

    [{"", _}] ->
      raise "定义 #{definition} 已以空名发布，Mind 里不会有建筑名，place_name 又不能为空；只能换定义。一人未登记"

    [{other, _}] ->
      raise "定义 #{definition} 已以 #{inspect(other)} 发布，World 保留首个发布名；" <>
              "把 residents.json 里建造活动与同名去处的 place_name（及 criterion 里的称呼）改成它后重跑。一人未登记"
  end

# 第 1 步
{first_name, _, first_result} = registered_first = register.(first)

pid =
  case first_result do
    {:ok, %{pid: pid}} -> pid
    error -> raise "#{first_name} 登记失败（#{inspect(error)}），未发布、未登记其余居民"
  end

# 第 2 步
context = await_session.(await_session, first_name, pid, 120)

if publish? do
  with {:ok, bytes} <- World.prefab_definition(context.world, id),
       {:ok, ^id} <- World.publish_prefab(context.world, context.actor, bytes, building) do
    :ok
  else
    error ->
      raise "以 #{first_name} 的会话发布 #{definition} 为 #{inspect(building)} 失败：#{inspect(error)}。" <>
              "#{first_name} 已登记并在跑，未登记其余居民"
  end
end

# 读回：发布元信息里这个定义的名字必须就是建造活动的 place_name。
[{^building, publisher}] = published_names.(context.world)

IO.puts(
  "npc_qinglan_publish definition=#{definition} name=#{inspect(building)} " <>
    "action=#{if publish?, do: "published", else: "already_published"} publisher=#{publisher}"
)

# 第 3 步
results = [registered_first | Enum.map(rest, register)]
failed = for {name, nil, result} <- results, do: {name, result}

if failed != [],
  do: raise("登记失败 #{length(failed)} 人：#{inspect(failed)}（其余已登记，见上面每人一行）")

results
