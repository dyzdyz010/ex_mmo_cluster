defmodule NpcServer.NpcDialogueLifeTest do
  @moduledoc """
  只测试：Life 回调的并发/写失败反例，以及写入侧的形状（经历条目、人名写法、tags、活动的期间事实、retain 每条经历一份文档）；
  合法持久行与事件作为纯输入，直接调 Life 的回调，存储替身不声称真实冷恢复。Hindsight 只替适配器模块（`Retainer`）。
  """
  use ExUnit.Case, async: false
  alias NpcServer.{Life, Memory}

  # 只测试：Hindsight 适配器替身，retain 收到的文档原样交给测试进程。
  defmodule Retainer do
    def ensure(_, _), do: {:ok, %{}}
    def status(_), do: {:ok, %{}}
    def refresh(_), do: {:ok, %{models: %{}, metadata: %{}}}

    def retain(config, documents) do
      send(config.owner, {:retain, documents})
      {:ok, %{retained: length(documents)}}
    end
  end

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

    world = %{
      seq: 7,
      at_ms: 9000,
      kind: :damage,
      actor: 9,
      placed_by: 7,
      cell: {1, 2, 3},
      material: 11
    }

    {:noreply, s} =
      Life.handle_info(
        {:result, :poll,
         {:ok, %{row: loaded, events: %{world_id: "world", cursor: 7, events: [world]}}}},
        s
      )

    assert Enum.map(s.row["pending"], & &1["id"]) == ["speech:81:1", "speech:81:2", "world:7"]
    assert s.row["state"]["cursor"] == 7
    assert length(s.row["pending"]) == 3
  end

  test "speech before initial load is saved after the World identity arrives, without advancing its cursor" do
    initial = state()
    {:noreply, s} = Life.handle_cast({:speech, speech(1)}, %{initial | row: nil})
    assert s.row == nil and length(s.speech_pending) == 1

    {:noreply, s} =
      Life.handle_info(
        {:result, :poll,
         {:ok, %{row: initial.row, events: %{world_id: "world", cursor: 6, events: []}}}},
        s
      )

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
      Life.handle_info(
        {:result, :poll,
         {:ok, %{row: s.row, events: %{world_id: "world", cursor: 6, events: []}}}},
        failed
      )

    assert accepted.error == nil and accepted.speech_pending == []
    assert accepted.row["state"] == s.row["state"]
    assert {:ok, stored} = Memory.life_load(Store, 7)
    assert [%{"id" => "speech:81:1"}] = stored["pending"]
  end

  test "模型情绪持久化失败不消费来源，World旧快照不会覆盖已提交情绪" do
    s = %{state() | appraise: true}
    s = put_in(s.row["state"], Life.Appraisal.enable(s.row["state"]))
    {:noreply, s} = Life.handle_cast({:speech, speech(1)}, s)
    loaded = s.row

    feeling = %{
      "emotion" => "gratitude",
      "intensity" => 0.7,
      "source_seq" => 1,
      "target_id" => 9,
      "reason" => "邻居表达帮助意愿"
    }

    Store.fail(true)

    assert {:reply, {:error, {:memory_unavailable, :write_denied}}, failed} =
             Life.handle_call({:appraise, 1, [feeling]}, nil, s)

    assert failed.row == s.row
    Store.fail(false)
    assert {:reply, :ok, committed} = Life.handle_call({:appraise, 1, [feeling]}, nil, failed)

    {:noreply, next} =
      Life.handle_info(
        {:result, :poll,
         {:ok, %{row: loaded, events: %{world_id: "world", cursor: 7, events: []}}}},
        committed
      )

    assert hd(next.row["state"]["feelings"])["intensity"] == 0.7
    assert next.row["state"]["affect"]["cursor"] == 1
    assert next.row["state"]["affect"]["pending"] == []
    assert next.row["state"]["cursor"] == 7
  end

  test "初始情境存储失败期间的连续观察只排入一次，恢复后只生成一个来源" do
    s = %{state() | appraise: true, context: %{cid: 7, scene_id: 1}}
    s = put_in(s.row["state"], Life.Appraisal.enable(s.row["state"]))
    observation = %{self: %{entity_id: 7, position: {0, 0, 0}}, entities: []}
    Store.fail(true)
    {:noreply, failed} = Life.handle_cast({:observation, observation}, s)
    {:noreply, failed} = Life.handle_cast({:observation, observation}, failed)
    assert length(failed.experience_pending) == 1
    Store.fail(false)

    {:noreply, next} =
      Life.handle_info(
        {:result, :poll,
         {:ok, %{row: s.row, events: %{world_id: "world", cursor: 6, events: []}}}},
        failed
      )

    assert next.experience_pending == []
    assert [%{"kind" => "situation", "seq" => 1}] = next.row["state"]["affect"]["pending"]
  end

  test "首次加载尚未完成时接收观察不崩溃，也不发明世界身份" do
    s = %{state() | appraise: true, row: nil, context: %{cid: 7, scene_id: 1}}
    observation = %{self: %{entity_id: 7, position: {0, 0, 0}}, entities: []}
    assert {:noreply, next} = Life.handle_cast({:observation, observation}, s)
    assert next.row == nil
    assert next.observation == observation
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
      appraise: false,
      observation: nil,
      experience_pending: [],
      activity: nil,
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

  # 自己（cid 7）在原点的一帧观察。
  defp seen(entities), do: %{self: %{entity_id: 7, position: {0.0, 0.0, 0.0}}, entities: entities}
  defp person(id, name, x), do: %{entity_id: id, name: name, position: {x, 0.0, 0.0}}

  # 期间事实只在“收到过开始信号、且期间收到过观察”时写；每项活动的经历时刻取 Life 的时钟（这里每读一次走 1 秒）。
  test "activity facts: none without a start signal or without observations; nearest approach and tags otherwise" do
    clock = start_supervised!({Agent, fn -> 1000 end})

    s = %{
      state()
      | now: fn -> Agent.get_and_update(clock, &{&1, &1 + 1000}) end,
        context: %{cid: 7, scene_id: 1}
    }

    # 心智快照的读入口还要适配器与配置（这里不发召回，只读视图）。
    s = Map.merge(s, %{adapter: Retainer, config: %{owner: self()}})

    done = ~s|I did "guard_hut" (Guard the hut.). Result: completed.|

    # 1. 没有开始信号：观察照常收到，不记账，不写期间事实。地名照样进 tags。
    {:noreply, s} = Life.handle_cast({:observation, seen([person(21, "Brann", 2.0)])}, s)
    {:noreply, s} = Life.handle_cast({:activity, %{text: done, place: "the hut"}}, s)
    # 2. 开始了，但期间一帧观察都没有。
    {:noreply, s} = Life.handle_cast(:activity_started, s)
    {:noreply, s} = Life.handle_cast({:activity, %{text: done, place: nil}}, s)

    # 3. 开始之后 Brann 从 9 米走到 2.5 米又退到 7 米。开始之前那一帧（2 米）不算。
    {:noreply, s} = Life.handle_cast(:activity_started, s)

    s =
      Enum.reduce([9.0, 2.5, 7.0], s, fn x, s ->
        {:noreply, s} = Life.handle_cast({:observation, seen([person(21, "Brann", x)])}, s)
        s
      end)

    {:noreply, s} = Life.handle_cast({:activity, %{text: done, place: "the hut"}}, s)
    # 4. 开始了，期间只有 6 米外的人。
    {:noreply, s} = Life.handle_cast(:activity_started, s)
    {:noreply, s} = Life.handle_cast({:observation, seen([person(21, "Brann", 6.5)])}, s)
    {:noreply, s} = Life.handle_cast({:activity, %{text: done, place: nil}}, s)
    assert s.activity == nil

    assert [
             %{
               "id" => "activity:1000",
               "at_ms" => 1000,
               "text" => done,
               "tags" => ["kind:activity", "place:the hut"]
             },
             %{
               "id" => "activity:2000",
               "at_ms" => 2000,
               "text" => done,
               "tags" => ["kind:activity"]
             },
             %{
               "id" => "activity:3000",
               "at_ms" => 3000,
               "text" =>
                 done <> " During it: Brann (actor 21) came within 3 m and then moved away.",
               "tags" => ["kind:activity", "actor:21", "place:the hut"]
             },
             %{
               "id" => "activity:4000",
               "at_ms" => 4000,
               "text" => done <> " During it: nobody came near.",
               "tags" => ["kind:activity"]
             }
           ] == s.row["pending"]

    # 心智快照读到的正文带时刻前缀（UTC 取条目的 at_ms），条目本身不带。
    {:reply, {:ok, snapshot}, _} = Life.handle_call(:context, nil, s)

    assert hd(snapshot.recent) == "At 1970-01-01T00:00:01.000Z (UTC), " <> done

    assert List.last(snapshot.recent) ==
             "At 1970-01-01T00:00:04.000Z (UTC), " <> done <> " During it: nobody came near."
  end

  # 说话人的名字取自消息（9 叫“邻居”）；World 事件里的人和 Speech 对象取自 Life 此刻持有的观察（9 在观察里叫 Mara）；
  # 自己（7）不在观察里，只写 actor 7。
  test "speech episodes name the speaker from the message, World episodes name people from the observation; retain sends one document each" do
    s = %{state() | observation: seen([person(9, "Mara", 1.0)])}
    s = Map.merge(s, %{adapter: Retainer, config: %{owner: self()}, status: nil})
    {:noreply, s} = Life.handle_cast({:speech, speech(1)}, s)

    world = %{
      seq: 7,
      at_ms: 9000,
      kind: :damage,
      actor: 9,
      placed_by: 7,
      cell: {1, 2, 3},
      material: 11
    }

    {:noreply, s} =
      Life.handle_info(
        {:result, :poll,
         {:ok, %{row: s.row, events: %{world_id: "world", cursor: 7, events: [world]}}}},
        s
      )

    heard =
      ~s|I heard: 邻居 (actor 9) said to actor 7 in conversation 81, turn 1: "我声称已经修好". | <>
        "This is a character's statement, not verified world facts."

    damaged =
      "Mara (actor 9) damaged construction I care about at (1, 2, 3), material 11, in world world (transaction 7). " <>
        "I feel angry toward this actor; my trust changed."

    assert [
             %{
               "id" => "speech:81:1",
               "at_ms" => 1001,
               "text" => ^heard,
               "tags" => ["kind:conversation", "actor:9"]
             },
             %{
               "id" => "world:7",
               "at_ms" => 9000,
               "text" => ^damaged,
               "tags" => ["kind:event", "actor:9"]
             }
           ] = s.row["pending"]

    # 封存成一个片段（运输批次），retain 时每条经历一份文档：id、时刻、tags 取自条目，正文加时刻前缀。
    {:reply, {:ok, %{status: :started}}, s} = Life.handle_call(:flush, nil, s)

    assert [%{"id" => "speech:81:1:fragment:world:7", "at_ms" => 1001, "episodes" => [_, _]}] =
             s.row["fragments"]

    assert_receive {:retain, documents}, 5000

    assert [
             %{
               "id" => "speech:81:1",
               "at_ms" => 1001,
               "text" => "At 1970-01-01T00:00:01.001Z (UTC), " <> heard,
               "tags" => ["kind:conversation", "actor:9"]
             },
             %{
               "id" => "world:7",
               "at_ms" => 9000,
               "text" => "At 1970-01-01T00:00:09.000Z (UTC), " <> damaged,
               "tags" => ["kind:event", "actor:9"]
             }
           ] == documents

    # 写成功后清理照旧：只删发出去的片段，retained 计片段数，缓存变 dirty。
    assert_receive {:result, :job, result}, 5000
    {:noreply, s} = Life.handle_info({:result, :job, result}, s)
    assert s.row["fragments"] == [] and s.row["retained"] == 1 and s.row["dirty"]
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
