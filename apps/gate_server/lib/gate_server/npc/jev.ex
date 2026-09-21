defmodule GateServer.Npc.Jev do
  @moduledoc """
  全局系统功能：NPC 调度层的分类模型（TypeSafe System One，“Jev”）。它不生成参数、不做规划，只在预先写好的选项里选，
  并给出置信度；规划归 LLM，逐格施工归代码。与它的交互一律用英文。

  一次请求最多问两件事（多个问题共用一份 state，只计一次费，延迟几乎不变）：
    * `activity`：现在该干哪件事（`activities/0` 里的一项；选中 `replan` 就是“交给规划者”）；
    * `harm`：只在给了 `planned_action` 时问——这个动作会不会拆到别人建的东西。

  实测定下来的两条：调度用一个五选一，不拆成几个并行的是否题（state 没提到的事，是否题停在 0.3 上下，35 条里只有 14 条能自动通过）；
  不另问“是否出乎意料”（着火也出乎意料，它会把一个十足把握的“去安全处”改成先问规划者）。

  `verdict/2` 把应答折成 Brain 能直接用的一个决定；置信度不够就升级给规划者，而不是硬选。
  评测与数字见 docs/10-active/cross-cutting/tools/jev/。

  endpoint: `%{url:, key:, model:, cacertfile: 可选}`
  """

  # 高风险动作才需要这么高；调度选错的代价是多问一次 LLM 或白走一趟，取官方建议的高档值，评测集上自动通过 85.7 %、零错。
  @confidence 0.85

  # 判据的措辞是实测调出来的：continue / replan 写得含糊时，最平常的情况置信度只有 0.6 上下，会白白升级给 LLM。
  @activities %{
    "continue_building" => "Nothing is wrong: keep executing the current building plan.",
    "fetch_material" => "Stop building and go gather more building material.",
    "respond_to_player" => "Pause work and respond to a player who is addressing the NPC.",
    "move_to_safety" => "Get away from an immediate physical danger.",
    "replan" =>
      "The world contradicts the blueprint, or the same step failed repeatedly, so the plan cannot proceed as written."
  }

  def activities, do: Map.keys(@activities)

  @doc "请求体。`situation` 是英文的当前情况摘要（代码能算的结论先算好写进去）；`planned_action` 是将要做的破坏性动作（英文），没有就不问 harm。"
  def body(endpoint, situation, planned_action \\ nil) do
    questions = %{
      activity: %{
        type: "choice",
        instructions:
          "What should the builder NPC do right now? If several apply, the priority is: move_to_safety first, then " <>
            "respond_to_player, then replan, then fetch_material, and continue_building only if none of the others apply.",
        criteria: @activities
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

    state = if planned_action, do: situation <> " Planned action: " <> planned_action, else: situation
    %{model: endpoint.model, state: state, questions: questions}
  end

  @doc """
  应答 → 一个决定：
    * `{:blocked, :harms_others}`   计划中的动作会拆到别人的东西（或拿不准）：不做；
    * `{:act, activity}`            有把握的调度；
    * `{:escalate, reason}`         拿不准（`:low_confidence`）或计划走不下去（`:unexpected`）：交给规划者。
  """
  def verdict(%{"answers" => answers}, confidence \\ @confidence) do
    activity = answers["activity"]
    harm = answers["harm"]

    cond do
      # 破坏别人的东西不可逆：只有明确判否（≤ 1 − 置信度）才放行。
      harm != nil and harm["noul"] > 1 - confidence -> {:blocked, :harms_others}
      activity["confidence"] < confidence -> {:escalate, :low_confidence}
      activity["choice"] == "replan" -> {:escalate, :unexpected}
      true -> {:act, String.to_existing_atom(activity["choice"])}
    end
  end

  @doc "问一次。`{:ok, verdict, response}` / `{:error, reason}`；HTTP 与 LLM 后端共用同一个发送函数。"
  def ask(endpoint, situation, planned_action \\ nil, request \\ &GateServer.Npc.Brain.Llm.request/2) do
    with {:ok, response} <- request.(endpoint, body(endpoint, situation, planned_action)),
         do: {:ok, verdict(response), response}
  end

  # verdict/2 用 String.to_existing_atom：这些原子在这里定义一次。
  @doc false
  def activity_atoms, do: [:continue_building, :fetch_material, :respond_to_player, :move_to_safety, :replan]
end
