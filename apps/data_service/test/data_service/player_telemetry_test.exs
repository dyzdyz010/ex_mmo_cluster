defmodule DataService.PlayerTelemetryTest do
  @moduledoc "只测试：玩家遥测写入 auth_audit 的契约（真实 PostgreSQL，本 VM 独占库）。期望值手算。"
  use ExUnit.Case, async: false
  alias DataService.{AccountStore, Repo}

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    Repo.query!("DELETE FROM auth_audit")
    Repo.query!("DELETE FROM characters WHERE id IN (9001, 9002, 9003)")
    Repo.query!("DELETE FROM accounts WHERE id IN (8001, 8002)")
    for id <- [8001, 8002], do: account(id)
    character(9001, 8001)
    character(9002, 8002)
    character(9003, nil, "npc")
    :ok
  end

  defp account(id),
    do:
      Repo.query!(
        "INSERT INTO accounts(id,username,inserted_at,updated_at) VALUES($1,$2,now(),now())",
        [id, "t#{id}"]
      )

  defp character(id, account, kind \\ "player"),
    do:
      Repo.query!(
        "INSERT INTO characters(id,account,name,kind,inserted_at,updated_at) VALUES($1,$2,$3,$4,now(),now())",
        [id, account, "c#{id}", kind]
      )

  defp rows,
    do: Repo.query!("SELECT actor,action,object_id,details,at FROM auth_audit ORDER BY id").rows

  test "session_start 记在角色所属账号上，带 Unix 秒" do
    :ok = AccountStore.record_session_event(9001, "session_start", %{}, 1_800_000_000)
    assert [["gate", "session_start", "8001", %{}, 1_800_000_000]] = rows()
  end

  test "session_end 的时长与原因原样落库" do
    :ok =
      AccountStore.record_session_event(
        9001,
        "session_end",
        %{duration_s: 125, reason: "client_leave"},
        1_800_000_200
      )

    assert [
             [
               "gate",
               "session_end",
               "8001",
               %{"duration_s" => 125, "reason" => "client_leave"},
               1_800_000_200
             ]
           ] = rows()
  end

  test "没有账号的角色（NPC）不产生任何行" do
    :ok = AccountStore.record_session_event(9003, "session_start", %{}, 1)
    :ok = AccountStore.record_first_edit(9003, 1)
    assert rows() == []
  end

  test "first_edit 每个账号终身一行：重复调用不增行，另一个账号各记一行" do
    :ok = AccountStore.record_first_edit(9001, 10)
    :ok = AccountStore.record_first_edit(9001, 20)
    :ok = AccountStore.record_first_edit(9002, 30)
    assert [["gate", "first_edit", "8001", _, 10], ["gate", "first_edit", "8002", _, 30]] = rows()
  end

  test "不认识的事件名被拒绝，不写入" do
    assert_raise FunctionClauseError, fn ->
      AccountStore.record_session_event(9001, "login_ok", %{}, 1)
    end

    assert rows() == []
  end
end
