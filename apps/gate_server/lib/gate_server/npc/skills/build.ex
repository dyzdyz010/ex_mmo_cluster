defmodule GateServer.Npc.Skills.Build do
  @moduledoc "全局系统功能：把已发布定义交给正式 Body prefab_place，按权威结果结束。"
  @behaviour GateServer.Npc.Skill
  alias GateServer.Npc.Body
  @metrics %{request_count: 0, jev_request_count: 0}
  @impl true
  def definition(_profile) do
    %{
      description:
        "将已发布的 definition 整体放到地图上，经现有 prefab_place 结算。锚点是 micro 坐标，1米=8micro；先走到工具射程内。",
      parameters: %{
        type: "object",
        properties:
          Map.put(GateServer.Npc.Skill.placement_properties(), :definition, %{type: "string"}),
        required: ["definition", "anchor_micro", "orientation"],
        additionalProperties: false
      }
    }
  end

  @impl true
  def run(context, %{"definition" => text, "anchor_micro" => anchor, "orientation" => o}, _config)
      when is_binary(text) do
    with {:ok, <<id::binary-size(32)>>} <- Base.decode16(text, case: :mixed),
         {:ok, anchor} <- GateServer.Npc.Skill.anchor(anchor, o) do
      Body.command(context.body, %{
        id: {:skill, context.call_id, 1},
        verb: :prefab_place,
        definition_id: id,
        anchor: anchor,
        orientation: o
      })

      receive do
        {:outcome, %{id: 1, status: :done, data: data}} ->
          {:ok, Map.put(data, :metrics, @metrics)}

        {:outcome, %{id: 1, reason: reason}} ->
          {:error, reason, @metrics}
      after
        300_000 -> {:error, :body_timeout, @metrics}
      end
    else
      _ -> {:error, :invalid_skill_arguments, @metrics}
    end
  end

  def run(_, _, _), do: {:error, :invalid_skill_arguments, @metrics}
end
