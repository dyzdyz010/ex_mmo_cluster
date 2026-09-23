defmodule AuthServerWeb.VoxelPrefabsControllerTest do
  @moduledoc "只测试：D3-2 prefab 列表经真实 World 启动加载 .pub/.vxpd 后由 HTTP 入口原样返回冻结字节。"
  use AuthServerWeb.ConnCase, async: false

  @content_version 0x5F84_4009_CA44_A605

  # 与 MmoContracts.R7PrefabTest 及 Voxim.R7.Prefab.PublishedList 同一冻结样本。
  @a "VXPD" <> <<3::32-little, 0::32, 0::32, 0::32, 1::32-little, 0::96, 11::16-little>>
  @b "VXPD" <>
       <<3::32-little, 0::32, 0::32, 0::32, 1::32-little, 255, 255, 255, 255, 0::32, 2, 0, 0, 0,
         19, 0>>

  setup do
    {:ok, _auth_started} = Application.ensure_all_started(:auth_server)

    previous_auto_login = Application.get_env(:auth_server, :dev_auto_login, false)
    previous_routes = Application.fetch_env(:world_server, :movement_routes)
    previous_scene = Application.fetch_env(:auth_server, :voxel_scene_id)
    previous_access = Application.get_env(:auth_server, :playtest_access_file)

    root =
      Path.join(System.tmp_dir!(), "voxim_prefabs_test_#{System.unique_integer([:positive])}")

    prefabs = Path.join([root, Base.encode16(<<@content_version::64>>, case: :lower), "prefabs"])
    File.mkdir_p!(prefabs)

    # 发布序与文件名序相反，证明按 .pub 序号而非目录顺序排列。
    for {ordinal, cid, bytes} <- [{2, 9, @b}, {1, 0x0102030405060708, @a}] do
      stem = Path.join(prefabs, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower))
      File.write!(stem <> ".vxpd", bytes)
      File.write!(stem <> ".pub", <<ordinal::32, cid::64>>)
    end

    Application.put_env(:auth_server, :dev_auto_login, true)
    start_supervised!({VoxelRegion.World, root: root, name: :voxim_http_prefabs_test})
    Application.put_env(:auth_server, :voxel_scene_id, 7)

    Application.put_env(:world_server, :movement_routes, %{
      7 => %{
        scene_ref: {:voxim_http_scene, node()},
        world_ref: {:voxim_http_prefabs_test, node()},
        scene_epoch: 1
      }
    })

    on_exit(fn ->
      Application.put_env(:auth_server, :dev_auto_login, previous_auto_login)
      Application.put_env(:auth_server, :playtest_access_file, previous_access)

      for {app, key, value} <- [
            {:world_server, :movement_routes, previous_routes},
            {:auth_server, :voxel_scene_id, previous_scene}
          ] do
        case value do
          {:ok, old} -> Application.put_env(app, key, old)
          :error -> Application.delete_env(app, key)
        end
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  defp post_prefabs(conn, route),
    do: conn |> put_req_header("content-type", "application/octet-stream") |> post(route, "")

  test "POST /ingame/voxel/prefabs returns the frozen list bytes; gated by dev_auto_login", %{
    conn: conn
  } do
    frozen =
      <<2, 0, 0, 0, 8, 7, 6, 5, 4, 3, 2, 1, 38, 0, 0, 0>> <>
        @a <> <<9, 0, 0, 0, 0, 0, 0, 0, 38, 0, 0, 0>> <> @b

    response = post_prefabs(conn, ~p"/ingame/voxel/prefabs")
    assert response.status == 200
    assert response.resp_body == frozen
    assert ["application/octet-stream" <> _] = get_resp_header(response, "content-type")

    Application.put_env(:auth_server, :dev_auto_login, false)
    assert post_prefabs(build_conn(), ~p"/ingame/voxel/prefabs").status == 403
  end

  test "POST /playtest/prefabs needs the invite bearer" do
    path = Path.join(System.tmp_dir!(), "invites-#{System.unique_integer([:positive])}.json")
    digest = :crypto.hash(:sha256, "test-invite") |> Base.encode16(case: :lower)
    File.write!(path, Jason.encode!(%{digest => "invited_player"}))
    Application.put_env(:auth_server, :playtest_access_file, path)
    on_exit(fn -> File.rm(path) end)

    assert post_prefabs(build_conn(), "/playtest/prefabs").status == 401

    invited =
      build_conn()
      |> put_req_header("authorization", "Bearer test-invite")
      |> post_prefabs("/playtest/prefabs")

    assert invited.status == 200
    assert <<2::32-little, _::binary>> = invited.resp_body
  end
end
