defmodule VisualizeServerWeb.SceneLiveTest do
  use VisualizeServerWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:visualize_server, :scene_node)
    Application.put_env(:visualize_server, :scene_node, node())

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:visualize_server, :scene_node)
        value -> Application.put_env(:visualize_server, :scene_node, value)
      end
    end)

    :ok
  end

  test "mounts the scene visualizer shell", %{conn: conn} do
    {:ok, _live, html} = live(conn, Routes.scene_index_path(conn, :index))

    assert html =~ "Scene Visualizer"
    assert html =~ to_string(node())
    assert html =~ "scene-visualizer"
  end
end
