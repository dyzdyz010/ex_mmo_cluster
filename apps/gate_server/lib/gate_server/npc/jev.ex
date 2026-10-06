defmodule GateServer.Npc.Jev do
  @moduledoc """
  全局系统功能：NPC 调度层的分类模型（TypeSafe System One，Jev）。
  活动选项、判据和优先级由调用方显式传入，不认识任何特定技能。与模型的交互一律用英文。

  `profile` 为 `%{instructions: 英文问题及优先级, activities: %{字符串选项 => 英文判据}}`。
  一次请求共享同一份 state：`activity` 是单个多选一问题；给出 `planned_action` 时另问 `harm`。
  保留多选一问法而不拆成多个是非题，置信度不足交回大脑；历史问法评测见
  docs/10-active/cross-cutting/tools/jev/。

  选中的 activity 保持字符串，必须属于 profile；其技能含义由调用方解释。
  harm 护栏独立于活动：可能损坏他人放置物时禁止动作。
  endpoint: `%{url:, key:, model:, cacertfile: 可选}`。
  """
  @confidence 0.85
  @behaviour GateServer.Npc.Scheduler
  require Logger

  @doc """
  中断检查（`profile.interrupt_policy = {Jev, config}`）。config 为
  `%{scheduler: endpoint, activities: 活动 profile, continue_activity: 继续的选项, request: 可选发送函数}`。
  只有有把握地选了非继续的选项才中断；拿不准（置信度不足、选项不属于 profile）等同继续，下次检查再问。
  """
  @impl true
  def decide(context, config) do
    situation =
      "An NPC is executing the #{context.skill} skill. " <>
        heard(context.heard) <>
        " Current observation: " <>
        Jason.encode!(
          GateServer.Npc.Context.plain(
            Map.take(context.observation, [:self, :entities, :balances, :pending])
          )
        )

    result =
      ask(
        config.scheduler,
        config.activities,
        situation,
        nil,
        Map.get(config, :request, &GateServer.Npc.Http.request/2)
      )

    decision =
      case result do
        {:ok, {:act, activity}, _} when activity == config.continue_activity -> :continue
        {:ok, {:act, activity}, _} -> {:interrupt, activity}
        {:ok, {:escalate, _}, _} -> :continue
        {:ok, decision, _} -> {:interrupt, decision}
        {:error, reason} -> {:error, reason}
      end

    verdict = with {:ok, verdict, _} <- result, do: verdict

    Logger.info(
      "npc_interrupt_check skill=#{context.skill} verdict=#{inspect(verdict)} decision=#{inspect(decision)}"
    )

    decision
  end

  # 听到的话原样转述（玩家原文可以是任何语言）；没有就明确说没有，不让分类器猜。
  defp heard([]), do: "No player is addressing the NPC."

  defp heard(messages),
    do:
      "Players are addressing the NPC (newest first): " <>
        Jason.encode!(GateServer.Npc.Context.plain(messages)) <> "."

  @doc "请求体。profile 与 situation 为英文；planned_action 是将做的破坏性动作，没有则不问 harm。"
  def body(endpoint, profile, situation, planned_action \\ nil) do
    questions = %{
      activity: %{
        type: "choice",
        instructions: profile.instructions,
        criteria: profile.activities
      }
    }

    questions =
      if planned_action,
        do:
          Map.put(questions, :harm, %{
            type: "noul",
            instructions:
              "Would carrying out the planned action damage or remove something that was built by someone other than this NPC?",
            criteria: %{
              true: "The target was built or placed by another player or NPC.",
              false: "The target is natural terrain or the NPC's own work."
            }
          }),
        else: questions

    state =
      if planned_action, do: situation <> " Planned action: " <> planned_action, else: situation

    %{model: endpoint.model, state: state, questions: questions}
  end

  @doc """
  应答折成一个决定：
    * `{:blocked, :harms_others}`：可能拆到他人放置物，不做；
    * `{:act, activity}`：有把握且属于 profile 的字符串选项；
    * `{:escalate, :low_confidence | :unknown_activity}`：拿不准或选项不属于 profile，交回大脑。
  """
  def verdict(%{"answers" => answers}, profile, confidence \\ @confidence) do
    activity = answers["activity"]
    harm = answers["harm"]

    cond do
      # 破坏他人放置物不可逆：只有明确判否才放行。
      harm != nil and harm["noul"] > 1 - confidence -> {:blocked, :harms_others}
      activity["confidence"] < confidence -> {:escalate, :low_confidence}
      not Map.has_key?(profile.activities, activity["choice"]) -> {:escalate, :unknown_activity}
      true -> {:act, activity["choice"]}
    end
  end

  @doc "问一次，返回 {:ok, verdict, response} 或 {:error, reason}；HTTP 与 LLM 共用发送函数。"
  def ask(
        endpoint,
        profile,
        situation,
        planned_action \\ nil,
        request \\ &GateServer.Npc.Http.request/2
      ) do
    with {:ok, response} <-
           request.(endpoint, body(endpoint, profile, situation, planned_action)),
         do: {:ok, verdict(response, profile), response}
  end
end
