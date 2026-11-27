defmodule AuthServerWeb.AutoLoginControllerTest do
  @moduledoc """
  只测试：dev 登录 `POST /ingame/auto_login` 的 JSON 身份与正式票据同一契约。

  角色 id 是雪花 id（约 7.8e17，超过 double 可精确表示的 2^53），JSON 里必须以十进制字符串
  发给客户端；发数字会被客户端读成 double 舍入，入场时 Gate 报 `cid_mismatch`。
  """
  use AuthServerWeb.ConnCase, async: false

  Code.require_file("../../../../data_service/test/support/database.exs", __DIR__)

  setup_all do
    MmoTest.Database.start!()
    {:ok, _} = Application.ensure_all_started(:auth_server)
    :ok
  end

  setup do
    previous = Application.get_env(:auth_server, :dev_auto_login, false)
    Application.put_env(:auth_server, :dev_auto_login, true)
    on_exit(fn -> Application.put_env(:auth_server, :dev_auto_login, previous) end)
  end

  test "cid 以十进制字符串返回，与库中角色及令牌绑定的角色一致" do
    username = "auto_login_#{System.unique_integer([:positive])}"

    body =
      build_conn()
      |> post(~p"/ingame/auto_login", %{username: username})
      |> json_response(200)

    # 同名再次 upsert 复用已有行，读回的就是本次登录建出的角色。
    {:ok, %{character: character}} = AuthServer.Accounts.upsert_dev(username)

    assert body["cid"] == Integer.to_string(character.id)
    assert body["username"] == username
    assert {:ok, claims} = AuthServer.AuthWorker.verify_token(body["token"])
    assert AuthServer.AuthWorker.validate_cid(claims, character.id) == :ok
  end
end
