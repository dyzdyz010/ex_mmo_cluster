defmodule NpcServer.NpcSkillsTest do
  @moduledoc "只测试：技能调用只产生一次最终结果，内部命令仍走 Body；这里的 Body 替身只手排事件。"
  use ExUnit.Case, async: false
  alias NpcServer.{Abilities, Skills}

  # 只测试：独立技能验证配置注册，不替代被测运行器或任何世界裁决。
  defmodule Survey do
    @behaviour NpcServer.Skill
    def definition(_),
      do: %{
        description: "Report the requested sample",
        parameters: %{
          type: "object",
          properties: %{sample: %{type: "integer"}},
          required: ["sample"],
          # 技能 schema 原样投影为 strict 工具（Skill 契约）。
          additionalProperties: false
        }
      }

    def run(_context, %{"sample" => sample}, _config),
      do: {:ok, %{sample: sample, metrics: %{request_count: 0, jev_request_count: 0}}}
  end

  test "a configured skill module supplies its contract and executes without changing dispatch" do
    # 技能名不与内置能力条目重名（survey 是感知条目）。
    profile = %{skills: %{sampler: %{module: Survey}}}

    assert [%{name: "sampler", parameters: %{required: ["sample"]}}] =
             Abilities.tools(Map.put(profile, :groups, [:skill]))

    command = Abilities.command("sampler", %{"sample" => 17}, 3, profile)
    assert %{id: 3, skill: :sampler} = command
    assert {:ok, %{sample: 17}} = Skills.run(%{profile: profile}, command)
    assert %{verb: :unknown_tool} = Abilities.command("unconfigured", %{}, 4, profile)

    response = %{
      "output" => [
        %{"type" => "function_call", "name" => "sampler", "arguments" => "{\"sample\":17}"}
      ]
    }

    assert [%{id: 3, verb: :skill, skill: :sampler, args: %{"sample" => 17}}] =
             NpcServer.Brain.Llm.commands(response, 3, profile)

    assert [%{id: 3, verb: :unknown_tool}] =
             NpcServer.Brain.Llm.commands(response, 3, %{skills: %{}})
  end

  defmodule Body do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}
    def handle_call(:skill_context, _, state), do: {:reply, state.context, state}

    def handle_cast({:command, command}, state) do
      send(state.owner, {:body_command, command})
      {:noreply, state}
    end
  end

  test "build is one skill call, with a distinct internal command identity and exact World outcome" do
    body =
      start_supervised!(
        {Body,
         %{owner: self(), context: {:ok, %{actor: %{cid: 71}, world: :world, scene: :scene}}}}
      )

    id = String.duplicate("2a", 32)
    profile = %{skills: %{build: %{}}, endpoint: %{model: "test"}}

    command =
      Abilities.command(
        "build",
        %{"definition" => id, "anchor_micro" => [8, 16, 24], "orientation" => 3},
        77,
        profile
      )

    active = Skills.start(body, command, profile, %{self: %{entity_id: 71}})

    assert_receive {:body_command,
                    %{
                      id: {:skill, 77, 1},
                      verb: :prefab_place,
                      definition_id: binary,
                      anchor: {8, 16, 24},
                      orientation: 3
                    }}

    assert binary == :binary.copy(<<42>>, 32)
    refute_receive {:skill_finished, 77, _}, 20

    send(
      active.pid,
      {:outcome, %{id: 1, verb: :prefab_place, status: :done, reason: nil, data: %{seq: 123}}}
    )

    assert_receive {:skill_finished, 77,
                    {:ok, %{seq: 123, metrics: %{request_count: 0, jev_request_count: 0}}}}

    assert_receive {:DOWN, ref, :process, pid, :normal}
    assert ref == active.ref and pid == active.pid
    refute_receive {:body_command, _}, 20
  end

  test "build preserves rejection and a stale session never sends a command" do
    body =
      start_supervised!(
        {Body,
         %{owner: self(), context: {:ok, %{actor: %{cid: 71}, world: :world, scene: :scene}}}}
      )

    profile = %{skills: %{build: %{}}, endpoint: %{model: "test"}}

    command =
      Abilities.command(
        "build",
        %{
          "definition" => String.duplicate("11", 32),
          "anchor_micro" => [0, 0, 0],
          "orientation" => 0
        },
        3,
        profile
      )

    active = Skills.start(body, command, profile, %{})
    assert_receive {:body_command, _}

    send(
      active.pid,
      {:outcome, %{id: 1, verb: :prefab_place, status: :rejected, reason: :occupied, data: nil}}
    )

    assert_receive {:skill_finished, 3, {:error, :occupied, _}}
    stop_supervised(Body)
    stale = start_supervised!({Body, %{owner: self(), context: {:error, :invalid_session}}})
    Skills.start(stale, command, profile, %{})
    assert_receive {:skill_finished, 3, {:error, :invalid_session, _}}
    refute_receive {:body_command, _}, 20
  end

  test "configured skill tools require all placement fields and reject unknown configuration" do
    tools =
      Abilities.tools(%{
        groups: [:skill],
        tools: %{7 => "place"},
        skills: %{build: %{}, wilderness: %{}}
      })

    assert Enum.sort(Enum.map(tools, & &1.name)) == ["build", "wilderness"]

    assert Enum.find(tools, &(&1.name == "build")).parameters.required == [
             "definition",
             "anchor_micro",
             "orientation"
           ]

    assert Enum.find(tools, &(&1.name == "wilderness")).parameters.properties.tool_id.enum == [7]
    assert Abilities.tools(%{groups: [:skill]}) == []
    assert %{verb: :unknown_tool} = Abilities.command("invent_skill", %{}, 1, %{})
  end
end
