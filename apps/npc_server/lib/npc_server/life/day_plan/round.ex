defmodule NpcServer.Life.DayPlan.Round do
  @moduledoc """
  一次规划调用的流程（实现设计 `docs/10-active/cross-cutting/2026-11-15-npc-day-plan-implementation.md` §4）：在 Life 的规划槽
  worker 里串行地取材料、写一次、检查。规则在 `NpcServer.Life.DayPlan`，提示词在 `NpcServer.Life.DayPlan.Prompt`，
  给模型看的英文渲染在 `NpcServer.Mind`；这里只把它们按离线测量 S1-R8 的做法串起来。

      write/1：此刻一块 → “自己”一问的材料（两次召回、之前的想法）→ 系统提示词 + 用户消息 → 写一次 → DayPlan.check/3

  ## 为什么这样取材

  S1-R8 的材料就是反思“自己”一问的那份（同样的两次召回、同样的“之前的想法”）：测过的输入形状才有读数可依。所以取材
  直接调用反思的同一条路径（`Reflection.Round.right_now/1`、`Reflection.Round.materials/3` 与 `Reflection.self_question/0`），不复制。

  ## 不回头问 Life，不重问

  Life 起槽那一刻把需要的一切取齐成快照交进来（见 `write/1`），I/O 只经快照里的 Hindsight 适配器、写作函数与 World 路由。
  只写一次：写作失败或检查不过都是这一次的结局，交回 Life 记一笔（`DayPlan.fail/5`），不重问——当日调用有额度
  （`DayPlan.admit/3`），重问只会把额度花在同一份材料上；下一次到点（跨日或新的 event）再规划。结果里带写作发出了没有
  （`wrote`），Life 落栏时对写作之前就失败的那次退回额度（`DayPlan.refund/1`）。

  日志每一步一行 `npc_plan cid=<cid> event=start|end …`（`end` 带 `wrote=true|false`）；计划原文（意图的 `why`、`wants`）
  不进日志，从 Life 的 observe 读。
  """
  require Logger
  alias NpcServer.Life.{DayPlan, Reflection}
  alias NpcServer.Life.DayPlan.Prompt
  alias NpcServer.Life.Reflection.Round, as: ReflectionRound

  @doc """
  规划一次。`snapshot` 由 Life 在起槽那一刻取齐：

      cid          永久 cid（日志用）
      kind         触发原因 :day | :event（`DayPlan.due/3`）
      day          此刻的游戏日号；now_minute 此刻的日内分钟（`check/3` 的 `by` 要严格晚于它）
      now_ms       Life 起槽那一刻的时钟：多久以前、召回的时刻参数都相对它
      observation  此刻的观察（带 `world_time`）
      recent       还没写进 Hindsight 的经历 `[%{at_ms:, text:}]`，旧在前
      buildings    我放下的有名字的建筑；people 有关系的人的 cid；names `%{cid => 名字}`
      latest       反思持久行里各问最新的一条（“之前的想法”）
      adapter      Hindsight 适配器；config 经历库的 config（单路超时已设好）
      context      现查 World 用（`Life.standing/2`）
      write        写作函数 `fn system, user -> {:ok, %{text:, usage:}} | {:error, 原因} end`（与反思共用写日记的接口）
      character    人格卡一行；activities 词表 `[%{name:, criterion:}]`（`profile.activities` 的次序）
      today        今天已有的意图各行（`Mind.plan_intent_line/1`），没有为 []
      wants        旧 `wants` 各行（`want` 原文），没有为 []

  返回交回 Life 落栏的结果 `%{result:, checked:, elapsed_ms:, usage:, wrote:}`：

      result   :ok | {:failed, 原因} | {:rejected, 原因}
               failed：此刻一块失败（`:no_body_state`、现查 World 失败）、召回失败、没有材料（`:no_materials`）、写作失败；
               rejected：写成了但没过 `DayPlan.check/3`（原因同它）
      checked  `DayPlan.check/3` 的 `%{intents:, wants:}`（`by` 已换成分钟），不是 :ok 时为 nil
      usage    写作应答的 usage 原样（写成了才有，含被拒的；失败为 nil）
      wrote    写作请求发出了没有：写作函数 `snapshot.write` 被调用过就为真，不论它返回成功、失败（含连接被拒、超时）
               还是应答没过检查；在它之前失败的（此刻一块、召回、没有材料）为假。Life 落栏时据此决定这一次扣不扣当日额度
               （`DayPlan.refund/1`）：额度管的是“问了模型几次”，写作函数一旦被调用就算问过了，哪怕请求没有到达模型。
  """
  def write(snapshot) do
    started = System.monotonic_time(:millisecond)
    head = "npc_plan cid=#{snapshot.cid}"
    which = "kind=#{snapshot.kind} day=#{snapshot.day}"

    Logger.info(
      "#{head} event=start #{which} minute=#{snapshot.now_minute} at_ms=#{snapshot.now_ms} " <>
        "today=#{length(snapshot.today)} wants=#{length(snapshot.wants)}"
    )

    {result, checked, usage, wrote} = plan(snapshot)
    elapsed_ms = System.monotonic_time(:millisecond) - started

    Logger.info(
      "#{head} event=end #{which} #{outcome(result, checked)} wrote=#{wrote} elapsed_ms=#{elapsed_ms} " <>
        "uncached_input_tokens=#{tokens(usage, "input_tokens")} output_tokens=#{tokens(usage, "output_tokens")}"
    )

    %{result: result, checked: checked, elapsed_ms: elapsed_ms, usage: usage, wrote: wrote}
  end

  # 取材 → 写一次 → 检查。返回 {结局, checked | nil, usage | nil, 写作发出了没有}：走到写作函数那一步就为真，
  # 在它之前的失败（`with` 的 else）为假。
  defp plan(snapshot) do
    with {:ok, right_now} <- ReflectionRound.right_now(snapshot),
         {:ok, materials} <-
           ReflectionRound.materials(Reflection.self_question(), right_now, snapshot) do
      system = Prompt.system_prompt(snapshot.character, snapshot.activities)
      user = Prompt.user_message(materials, today: snapshot.today, wants: snapshot.wants)

      case snapshot.write.(system, user) do
        {:ok, %{text: text} = written} ->
          usage = Map.get(written, :usage)
          names = Enum.map(snapshot.activities, & &1.name)

          case DayPlan.check(text, names, snapshot.now_minute) do
            {:ok, checked} -> {:ok, checked, usage, true}
            {:error, reason} -> {{:rejected, reason}, nil, usage, true}
          end

        {:error, reason} ->
          {{:failed, reason}, nil, nil, true}
      end
    else
      {:error, reason} -> {{:failed, reason}, nil, nil, false}
    end
  end

  defp outcome(:ok, checked),
    do: "result=written intents=#{length(checked.intents)} wants=#{length(checked.wants)}"

  defp outcome({:failed, reason}, nil), do: "result=failed reason=#{inspect(reason)}"
  defp outcome({:rejected, reason}, nil), do: "result=rejected reason=#{inspect(reason)}"

  # 槽日志读取 Messages 原始字段；完整输入见模型请求日志。
  defp tokens(%{} = usage, key), do: inspect(Map.get(usage, key))
  defp tokens(nil, _key), do: "nil"
end
