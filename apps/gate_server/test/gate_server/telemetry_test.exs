defmodule GateServer.TelemetryTest do
  @moduledoc "只测试：Gate 遥测经一次性 Task 写库；等待实际落库条件，不靠固定 sleep。"
  use ExUnit.Case, async: false
  alias DataService.Repo

  Code.require_file("../../../data_service/test/support/database.exs", __DIR__)

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    Repo.query!("DELETE FROM auth_audit")
    Repo.query!("DELETE FROM characters WHERE id = 9101")
    Repo.query!("DELETE FROM accounts WHERE id = 8101")

    Repo.query!(
      "INSERT INTO accounts(id,username,inserted_at,updated_at) VALUES(8101,'tg',now(),now())"
    )

    Repo.query!(
      "INSERT INTO characters(id,account,name,inserted_at,updated_at) VALUES(9101,8101,'tgc',now(),now())"
    )

    :ok
  end

  defp count(action),
    do:
      Repo.query!("SELECT count(*) FROM auth_audit WHERE action=$1", [action]).rows
      |> hd()
      |> hd()

  defp await(action, expected, tries \\ 100) do
    cond do
      count(action) == expected -> :ok
      tries == 0 -> flunk("#{action} count never reached #{expected}, now #{count(action)}")
      true -> Process.sleep(20) && await(action, expected, tries - 1)
    end
  end

  test "session_start / session_end 落库，时长为整秒" do
    GateServer.Telemetry.session_start(9101)
    await("session_start", 1)

    # 手算：起点在 3 秒多之前，整除 1000 得 3。
    GateServer.Telemetry.session_end(
      9101,
      System.monotonic_time(:millisecond) - 3_500,
      "client_leave"
    )

    await("session_end", 1)

    [[%{"duration_s" => duration, "reason" => "client_leave"}]] =
      Repo.query!("SELECT details FROM auth_audit WHERE action='session_end'").rows

    assert duration == 3
  end

  test "同一进程里 first_edit 只发一次；终身一行" do
    for _ <- 1..5, do: GateServer.Telemetry.first_edit(9101)
    await("first_edit", 1)
    Process.sleep(100)
    assert count("first_edit") == 1
  end

  test "写库失败只记警告，不抛给调用方" do
    Repo.query!("ALTER TABLE auth_audit RENAME TO auth_audit_x")
    on_exit(fn -> Repo.query!("ALTER TABLE auth_audit_x RENAME TO auth_audit") end)

    # 写库在 Task 里异步失败，调用方拿到的仍是 :ok；警告由 Task 进程发出，等它落到日志里再断言。
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = GateServer.Telemetry.session_start(9101)
        Process.sleep(200)
      end)

    assert log =~ "telemetry_failed event=session_start cid=9101"
  end
end
