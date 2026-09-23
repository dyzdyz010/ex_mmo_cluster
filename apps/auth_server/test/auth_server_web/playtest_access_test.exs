defmodule AuthServerWeb.PlaytestAccessTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias AuthServerWeb.Plugs.PlaytestAccess

  setup do
    previous = Application.get_env(:auth_server, :playtest_access_file)
    path = Path.join(System.tmp_dir!(), "invites-#{System.unique_integer([:positive])}.json")
    digest = :crypto.hash(:sha256, "test-invite") |> Base.encode16(case: :lower)
    File.write!(path, Jason.encode!(%{digest => "invited_player"}))
    Application.put_env(:auth_server, :playtest_access_file, path)

    on_exit(fn ->
      Application.put_env(:auth_server, :playtest_access_file, previous)
      File.rm!(path)
    end)

    %{path: path}
  end

  test "登录和地形请求都需要邀请码" do
    for route <- ["/playtest/login", "/playtest/regions", "/playtest/prefabs"], code <- [nil, "wrong"] do
      request = conn(:post, route)

      request =
        if code, do: put_req_header(request, "authorization", "Bearer " <> code), else: request

      response = PlaytestAccess.call(request, [])
      assert response.status == 401
      assert response.halted
    end
  end

  test "身份来自服务器，停用后下一次请求立即拒绝", %{path: path} do
    request =
      conn(:post, "/playtest/login", %{"username" => "someone_else"})
      |> put_req_header("authorization", "Bearer test-invite")

    assert PlaytestAccess.call(request, []).assigns.playtest_username == "invited_player"
    File.write!(path, "{}")
    assert PlaytestAccess.call(request, []).status == 401
  end

  test "有效邀请码也不能旁路旧登录、写入接口与静态路径" do
    for route <- [
          "/ingame/auto_login",
          "/ingame/login",
          "/ingame/voxel/set_temperature",
          "/",
          "/assets/app.js"
        ] do
      response =
        conn(:post, route)
        |> put_req_header("authorization", "Bearer test-invite")
        |> PlaytestAccess.call([])

      assert response.status == 404
      assert response.halted
    end
  end

  test "未配置的内测入口关闭，开发入口保留原契约" do
    Application.delete_env(:auth_server, :playtest_access_file)
    assert PlaytestAccess.call(conn(:post, "/playtest/login"), []).status == 404
    refute PlaytestAccess.call(conn(:post, "/ingame/auto_login"), []).halted
  end
end
