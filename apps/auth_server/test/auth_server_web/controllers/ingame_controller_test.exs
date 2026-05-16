defmodule AuthServerWeb.IngameControllerTest do
  use AuthServerWeb.ConnCase

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Types

  setup do
    previous_auto_login = Application.get_env(:auth_server, :dev_auto_login, false)
    Application.put_env(:auth_server, :dev_auto_login, true)

    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn ->
      Application.put_env(:auth_server, :dev_auto_login, previous_auto_login)
    end)

    :ok
  end

  test "POST /ingame/voxel/set_temperature returns JSON-safe source and cleanup summaries",
       %{conn: conn} do
    logical_scene_id = 81_000 + System.unique_integer([:positive])
    world_macro = {0, 0, 0}
    macro_index = Types.macro_index!(world_macro)

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: logical_scene_id,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk_pid, world_macro, NormalBlockData.new(1))

    hot_conn =
      post(conn, ~p"/ingame/voxel/set_temperature", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0,
        "target_temperature_celsius" => 800,
        "max_ticks" => 100
      })

    hot = json_response(hot_conn, 200)
    assert hot["target_temperature"] == 800.0
    assert hot["source"]["source_kind"] == "temperature"
    assert hot["source"]["source_mode"] == "impulse"
    assert hot["source"]["source_key"] == ["temperature", macro_index]

    assert [%{"module" => kernel_module}] = hot["source"]["kernel_specs"]
    assert is_binary(kernel_module)

    ambient_conn =
      hot_conn
      |> recycle()
      |> post(~p"/ingame/voxel/set_temperature", %{
        "logical_scene_id" => logical_scene_id,
        "x" => 0,
        "y" => 0,
        "z" => 0,
        "restore_ambient" => true,
        "max_ticks" => 100
      })

    ambient = json_response(ambient_conn, 200)
    assert ambient["target_temperature"] == 20.0
    assert ambient["field_region_created"] == false

    assert ambient["field_region_cleanup"] == %{
             "destroy_reason" => "temperature_within_environment_threshold",
             "region_action" => "destroyed",
             "region_id" => hot["region_id"],
             "source_action" => "released",
             "source_key" => ["temperature", macro_index]
           }
  end
end
