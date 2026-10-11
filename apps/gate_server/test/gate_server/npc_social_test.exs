defmodule GateServer.NpcSocialTest do
  @moduledoc "只测试：纯 Social/Tree 接缝；权威 Outcome 控制取消与移动完成，不启动网络。"
  use ExUnit.Case, async: true
  alias GateServer.Npc.Brain.Social
  alias GateServer.Npc.Life.State

  defp observation(state, position \\ {0.0, 64.0, 0.0}, actor \\ {1.0, 64.0, 0.0}) do
    %{
      self: %{entity_id: 1, tick: 1, position: position},
      entities: [%{entity_id: 2, position: actor}],
      life: %{state: state, now_ms: 1000},
      pending: []
    }
  end

  defp mind do
    Social.init(%{
      tree: fn _ -> {{:repeat, :forever, {:act, "travel", %{"x" => 10, "z" => 0}}}, %{}} end,
      tools: %{},
      skills: %{travel: %{}}
    })
  end

  defp angry do
    {state, _} =
      State.advance(
        State.new(1, "world", 0, 0),
        [
          %{
            seq: 1,
            at_ms: 1000,
            actor: 2,
            kind: :damage,
            cell: {0, 64, 1},
            material: 11,
            placed_by: 1
          }
        ],
        1,
        1000
      )

    state
  end

  test "social movement waits for halted skill terminal and preserves authority failure" do
    {[%{id: skill, verb: :skill}], mind} =
      Social.handle_event(
        {:observation, %{observation(State.new(1, "world", 0, 0)) | entities: []}},
        mind()
      )

    {[%{verb: :cancel_skill, call: ^skill}], mind} =
      Social.handle_event({:observation, observation(angry())}, mind)

    {[], mind} = Social.handle_event({:observation, observation(angry())}, mind)

    {[], mind} =
      Social.handle_event({:outcome, %{id: skill, status: :rejected, reason: :cancelled}}, mind)

    {[%{verb: :move_to, id: id}], mind} =
      Social.handle_event({:observation, observation(angry())}, mind)

    {[], mind} =
      Social.handle_event({:outcome, %{id: id, status: :rejected, reason: :unreachable}}, mind)

    assert mind.last_outcome.reason == :unreachable
    assert mind.social.mode == :avoid
    assert {[], _} = Social.handle_event({:observation, observation(angry())}, mind)
  end

  test "caution holds while stranger remains visible, including after reaching stand-off" do
    state = State.new(1, "world", 0, 0)

    {[%{verb: :move_to, id: id}], mind} =
      Social.handle_event({:observation, observation(state)}, mind())

    {[], mind} = Social.handle_event({:outcome, %{id: id, status: :done, reason: nil}}, mind)

    assert {[], _} =
             Social.handle_event({:observation, observation(state, {-4.0, 64.0, 0.0})}, mind)

    {commands, _} =
      Social.handle_event({:observation, %{observation(state) | entities: []}}, mind)

    assert [%{verb: :skill}] = commands
  end

  test "completed gratitude is acknowledged once and does not reapproach when work moves away" do
    {state, _} =
      State.advance(
        angry(),
        [
          %{
            seq: 2,
            at_ms: 1000,
            actor: 3,
            kind: :build,
            cell: {0, 64, 1},
            material: 11,
            placed_by: nil
          }
        ],
        2,
        1000
      )

    obs = %{
      observation(state, {0.0, 64.0, 0.0}, {9.0, 64.0, 0.0})
      | entities: [%{entity_id: 3, position: {9.0, 64.0, 0.0}}]
    }

    {[%{verb: :move_to, id: id}], mind} = Social.handle_event({:observation, obs}, mind())
    {[], mind} = Social.handle_event({:outcome, %{id: id, status: :done, reason: nil}}, mind)
    {[%{verb: :skill}], _} = Social.handle_event({:observation, obs}, mind)
  end

  test "failed halt stop is explicit and prevents a new social move" do
    profile = %{
      tree: fn _ -> {{:act, "move_to", %{"x" => 10, "z" => 0, "y" => nil}}, %{}} end,
      tools: %{}
    }

    {[%{verb: :move_to, id: old}], mind} =
      Social.handle_event(
        {:observation, %{observation(State.new(1, "world", 0, 0)) | entities: []}},
        Social.init(profile)
      )

    {[%{verb: :stop, id: stop}], mind} =
      Social.handle_event({:observation, observation(angry())}, mind)

    {[], mind} =
      Social.handle_event({:outcome, %{id: old, status: :superseded, reason: :superseded}}, mind)

    {[], mind} =
      Social.handle_event({:outcome, %{id: stop, status: :rejected, reason: :session_lost}}, mind)

    assert mind.last_outcome.reason == :session_lost
    assert {[], _} = Social.handle_event({:observation, observation(angry())}, mind)
  end

  test "gratitude already within range is acknowledged before work later moves away" do
    {state, _} =
      State.advance(
        angry(),
        [
          %{
            seq: 2,
            at_ms: 1000,
            actor: 3,
            kind: :build,
            cell: {0, 64, 1},
            material: 11,
            placed_by: nil
          }
        ],
        2,
        1000
      )

    near = %{observation(state) | entities: [%{entity_id: 3, position: {1.0, 64.0, 0.0}}]}
    {[%{verb: :skill, id: id}], mind} = Social.handle_event({:observation, near}, mind())

    {_, mind} =
      Social.handle_event({:outcome, %{id: id, status: :done, data: %{}, reason: nil}}, mind)

    far = %{near | entities: [%{entity_id: 3, position: {12.0, 64.0, 0.0}}]}
    {commands, _} = Social.handle_event({:observation, far}, mind)
    refute Enum.any?(commands, &match?(%{id: {:social, _}}, &1))
  end

  test "social target leaves target standing layer to authoritative Body navigation on uneven ground" do
    {[%{verb: :move_to} = command], _} =
      Social.handle_event(
        {:observation, observation(angry(), {0.0, 66.0, 0.0}, {1.0, 64.0, 0.0})},
        mind()
      )

    refute Map.has_key?(command, :y)
  end

  test "restored completed gratitude stays acknowledged in a new Brain" do
    {state, _} =
      State.advance(
        angry(),
        [
          %{
            seq: 2,
            at_ms: 1000,
            actor: 3,
            kind: :build,
            cell: {0, 64, 1},
            material: 11,
            placed_by: nil
          }
        ],
        2,
        1000
      )

    obs = %{observation(state) | entities: [%{entity_id: 3, position: {12.0, 64.0, 0.0}}]}
    obs = put_in(obs, [:life, :thanks], 2)
    {commands, _} = Social.handle_event({:observation, obs}, mind())
    assert [%{verb: :skill}] = commands
  end

  test "rejected gratitude move remains an explicit failure and is not acknowledged as arrival" do
    {state, _} =
      State.advance(
        angry(),
        [
          %{
            seq: 2,
            at_ms: 1000,
            actor: 3,
            kind: :build,
            cell: {0, 64, 1},
            material: 11,
            placed_by: nil
          }
        ],
        2,
        1000
      )

    obs = %{observation(state) | entities: [%{entity_id: 3, position: {12.0, 64.0, 0.0}}]}
    {[%{verb: :move_to, id: id}], mind} = Social.handle_event({:observation, obs}, mind())

    {[], mind} =
      Social.handle_event({:outcome, %{id: id, status: :rejected, reason: :no_path}}, mind)

    assert mind.thanks == 0
    assert mind.last_outcome.reason == :no_path
    assert {[], _} = Social.handle_event({:observation, obs}, mind)
  end
end
