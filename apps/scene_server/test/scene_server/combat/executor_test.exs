defmodule SceneServer.Combat.ExecutorTest do
  use ExUnit.Case, async: false

  alias SceneServer.AoiManager
  alias SceneServer.Combat.{CastRequest, Executor, Skill}

  defmodule FakeCombatActor do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         cid: Keyword.fetch!(opts, :cid),
         position: Keyword.fetch!(opts, :position),
         notify: Keyword.fetch!(opts, :notify),
         kind: Keyword.get(opts, :kind, :player),
         hp: 100,
         max_hp: 100,
         alive: true
       }}
    end

    @impl true
    def handle_call(:get_state_summary, _from, state) do
      {:reply,
       {:ok,
        %{
          kind: state.kind,
          cid: state.cid,
          position: state.position,
          hp: state.hp,
          max_hp: state.max_hp,
          alive: state.alive,
          deaths: 0
        }}, state}
    end

    @impl true
    def handle_call({:apply_damage_effect, source_cid, skill_id, amount, impact_location}, _from, state) do
      send(state.notify, {:damage_applied, state.cid, source_cid, skill_id, amount, impact_location})
      hp = max(state.hp - amount, 0)
      {:reply, {:ok, hp}, %{state | hp: hp, alive: hp > 0}}
    end
  end

  setup do
    ensure_started(SceneServer.AoiManager, {SceneServer.AoiManager, name: SceneServer.AoiManager})
    ensure_started(SceneServer.AoiItemSup, {SceneServer.AoiItemSup, name: SceneServer.AoiItemSup})
    :ok
  end

  test "projectile cast resolves target and emits projectile cue" do
    actor = add_actor(20_001, {100.0, 0.0, 0.0}, self())
    on_exit(fn -> exit_aoi_item(actor.aoi_pid) end)

    {:ok, skill} = Skill.fetch(2)

    assert {:ok, execution} =
             Executor.prepare_cast(
               %{cid: 10_000, position: {0.0, 0.0, 0.0}},
               CastRequest.actor(2, 20_001),
               skill
             )

    assert [%{cue_kind: :projectile, target_cid: 20_001}] = execution.initial_cues
    assert execution.delayed_cast.travel_ms > 0
  end

  test "trigger skill emits chained cues and damages follow-up targets" do
    primary = add_actor(20_101, {80.0, 0.0, 0.0}, self())
    chain = add_actor(20_102, {110.0, 15.0, 0.0}, self())

    on_exit(fn ->
      exit_aoi_item(primary.aoi_pid)
      exit_aoi_item(chain.aoi_pid)
    end)

    {:ok, skill} = Skill.fetch(4)

    {:ok, execution} =
      Executor.prepare_cast(
        %{cid: 10_000, position: {0.0, 0.0, 0.0}},
        CastRequest.actor(4, 20_101),
        skill
      )

    resolution = Executor.resolve_cast(execution.delayed_cast)

    assert Enum.any?(resolution.cues, &(&1.cue_kind == :aoe_ring))
    assert Enum.any?(resolution.cues, &(&1.cue_kind == :chain_arc))

    assert_receive {:damage_applied, 20_101, 10_000, 4, 12, _}
    assert_receive {:damage_applied, 20_101, 10_000, 4, 10, _}
    assert_receive {:damage_applied, 20_102, 10_000, 4, 8, _}
  end

  defp add_actor(cid, position, notify) do
    {:ok, actor_pid} =
      start_supervised(
        Supervisor.child_spec(
          {FakeCombatActor, [cid: cid, position: position, notify: notify]},
          id: {:fake_combat_actor, cid}
        )
      )

    {:ok, aoi_pid} =
      AoiManager.add_aoi_item(
        cid,
        0,
        position,
        self(),
        actor_pid,
        %{kind: :player, name: "actor-#{cid}"}
      )

    %{actor_pid: actor_pid, aoi_pid: aoi_pid}
  end

  defp ensure_started(name, spec) do
    case Process.whereis(name) do
      nil -> start_supervised!(spec)
      pid -> pid
    end
  end

  defp exit_aoi_item(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :exit)
    end
  end
end
