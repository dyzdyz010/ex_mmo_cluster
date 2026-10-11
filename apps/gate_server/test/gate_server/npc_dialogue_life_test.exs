defmodule GateServer.NpcDialogueLifeTest do
  @moduledoc "只测试：Life 回调的并发/写失败反例；合法持久行与事件作为纯输入，存储替身不声称真实冷恢复。"
  use ExUnit.Case, async: false
  alias GateServer.Npc.{Life, Memory}

  defmodule Store do
    use Agent
    def start_link(_), do: Agent.start_link(fn -> %{row: nil, fail: false} end, name: __MODULE__)
    def get(_, _, _), do: Agent.get(__MODULE__, & &1.row)
    def fail(value), do: Agent.update(__MODULE__, &%{&1 | fail: value})

    def put(_, _, _, row),
      do:
        Agent.get_and_update(__MODULE__, fn s ->
          if s.fail, do: {{:error, :write_denied}, s}, else: {:ok, %{s | row: row}}
        end)
  end

  setup do
    start_supervised!({Store, []})
    :ok
  end

  test "slow World poll merges only its new episodes, preserving concurrent and already pending speech" do
    s = state()
    {:noreply, s} = Life.handle_cast({:speech, speech(1)}, s)
    loaded = s.row
    {:noreply, s} = Life.handle_cast({:speech, speech(2)}, s)
    world = %{"id" => "world:7", "seq" => 7, "at_ms" => 9000, "text" => "World authority event"}
    loaded = put_in(loaded, ["state", "cursor"], 7)

    {:noreply, s} =
      Life.handle_info({:result, :poll, {:ok, %{row: loaded, episodes: [world]}}}, s)

    assert Enum.map(s.row["pending"], & &1["id"]) == ["speech:81:1", "speech:81:2", "world:7"]
    assert s.row["state"]["cursor"] == 7
    assert length(s.row["pending"]) == 3
  end

  test "speech before initial load is saved after the World identity arrives, without advancing its cursor" do
    initial = state()
    {:noreply, s} = Life.handle_cast({:speech, speech(1)}, %{initial | row: nil})
    assert s.row == nil and length(s.speech_pending) == 1

    {:noreply, s} =
      Life.handle_info({:result, :poll, {:ok, %{row: initial.row, episodes: []}}}, s)

    assert s.speech_pending == []
    assert s.row["state"] == initial.row["state"]
    assert [%{"id" => "speech:81:1"}] = s.row["pending"]
  end

  test "storage rejection keeps speech visibly unsaved and retries through the existing poll without false success" do
    s = state()
    :ok = Memory.life_save(Store, 7, s.row)
    Store.fail(true)
    {:noreply, failed} = Life.handle_cast({:speech, speech(1)}, s)
    assert failed.error == {:memory_unavailable, :write_denied}
    assert failed.row == s.row and length(failed.speech_pending) == 1
    assert {:ok, saved} = Memory.life_load(Store, 7)
    assert saved["pending"] == [] and saved["state"]["cursor"] == 6

    Store.fail(false)

    {:noreply, accepted} =
      Life.handle_info({:result, :poll, {:ok, %{row: s.row, episodes: []}}}, failed)

    assert accepted.error == nil and accepted.speech_pending == []
    assert accepted.row["state"] == s.row["state"]
    assert {:ok, stored} = Memory.life_load(Store, 7)
    assert [%{"id" => "speech:81:1"}] = stored["pending"]
  end

  defp state do
    %{
      context: %{cid: 7},
      owner: self(),
      memory: Store,
      now: fn -> 1000 end,
      poll: %{ref: make_ref()},
      poll_ms: 60_000,
      job: nil,
      job_error: nil,
      error: nil,
      speech_pending: [],
      row: %{
        "state" => Life.State.new(7, "world", 6, 0),
        "pending" => [],
        "fragments" => [],
        "cache" => %{"models" => %{}, "metadata" => %{}, "at_ms" => 0},
        "retained" => 0,
        "dirty" => false,
        "refresh_at_ms" => nil,
        "thanked_seq" => 0
      }
    }
  end

  defp speech(turn),
    do: %{
      conversation_id: 81,
      turn: turn,
      speaker_id: 9,
      speaker_epoch: 3,
      speaker_kind: 1,
      speaker_name: "邻居",
      target_id: 7,
      at_ms: 1000 + turn,
      text: "我声称已经修好"
    }
end
