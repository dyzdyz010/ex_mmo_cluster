defmodule DataService.NpcSpecsTest do
  @moduledoc """
  只测试：NPC 注册表的存储层（`npc_specs` 表，放置阶段决策稿 docs/10-active/cross-cutting/2026-10-08-npc-placement-phase.md §2）。
  DB-backed；期望值是手写字面量。参数的解析与校验不在这一层（`NpcServer.Registry`）。
  """
  use ExUnit.Case, async: false
  alias DataService.{CharacterStore, NpcSpecs, Repo}
  alias DataService.Schema.Character

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    Repo.delete_all("npc_specs")
    Repo.delete_all(Character)
    on_exit(fn -> Repo.delete_all("npc_specs") end)
    :ok
  end

  @params %{"goal" => "守着西门", "tools" => %{"1" => "镐"}, "genesis" => true}

  test "upsert writes one enabled row per NPC; a second upsert overwrites it and re-enables it" do
    {:ok, %{id: cid}} = CharacterStore.ensure_npc("创世者")
    {:ok, %{id: other}} = CharacterStore.ensure_npc("巡逻者")

    :ok =
      NpcSpecs.upsert(cid, %{scene_id: 1, spawn: {4.0, 66.0, 10.0}, brain: "llm", params: @params})

    :ok =
      NpcSpecs.upsert(other, %{
        scene_id: 2,
        spawn: {-3.5, 70.0, 8},
        brain: "patrol",
        params: %{"route" => [[4.0, 10.0], [8.0, 10.0]]}
      })

    # 按名字排序（巡 < 创 的 UTF-8 字节序：巡 E5 B7 A1，创 E5 88 9B → 创在前）。
    assert [
             %{
               cid: ^cid,
               name: "创世者",
               scene_id: 1,
               spawn: {4.0, 66.0, 10.0},
               brain: "llm",
               params: @params,
               enabled: true
             },
             %{
               cid: ^other,
               name: "巡逻者",
               scene_id: 2,
               spawn: {-3.5, 70.0, 8},
               brain: "patrol",
               enabled: true
             }
           ] = NpcSpecs.list()

    assert {:ok, ^cid} = NpcSpecs.disable("创世者")
    assert [%{cid: ^cid, enabled: false}, %{cid: ^other, enabled: true}] = NpcSpecs.list()

    :ok =
      NpcSpecs.upsert(cid, %{
        scene_id: 3,
        spawn: {1.5, 64.0, 2.5},
        brain: "settler",
        params: %{"definition" => "AB"}
      })

    assert [
             %{
               cid: ^cid,
               scene_id: 3,
               spawn: {1.5, 64.0, 2.5},
               brain: "settler",
               params: %{"definition" => "AB"},
               enabled: true
             },
             %{cid: ^other}
           ] = NpcSpecs.list()

    assert 2 == Repo.aggregate("npc_specs", :count)
  end

  test "disable keeps the row and the character; an unknown name is not_found" do
    {:ok, %{id: cid}} = CharacterStore.ensure_npc("建设者")
    :ok = NpcSpecs.upsert(cid, %{scene_id: 1, spawn: {1, 2, 3}, brain: "llm", params: @params})

    assert {:ok, ^cid} = NpcSpecs.disable("建设者")
    assert [%{cid: ^cid, enabled: false, params: @params}] = NpcSpecs.list()
    assert %Character{kind: "npc"} = Repo.get(Character, cid)
    assert {:error, :not_found} = NpcSpecs.disable("没有这个人")
  end

  test "a row must belong to an existing character (foreign key)" do
    assert_raise Postgrex.Error, ~r/foreign key/, fn ->
      NpcSpecs.upsert(424_242, %{scene_id: 1, spawn: {0, 0, 0}, brain: "llm", params: %{}})
    end
  end
end
