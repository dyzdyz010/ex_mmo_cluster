defmodule VisualizeServerWeb.SceneLiveTest do
  use VisualizeServerWeb.ConnCase

  import Phoenix.LiveViewTest
  import VisualizeServer.WorldFixtures

  @create_attrs %{}
  @update_attrs %{}
  @invalid_attrs %{}

  defp create_scene(_) do
    scene = scene_fixture()
    %{scene: scene}
  end

  describe "Index" do
    setup [:create_scene]

    test "lists all scenes", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, Routes.scene_index_path(conn, :index))

      assert html =~ "Listing Scenes"
    end

    test "saves new scene", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, Routes.scene_index_path(conn, :index))

      assert index_live |> element("a", "New Scene") |> render_click() =~
               "New Scene"

      assert_patch(index_live, Routes.scene_index_path(conn, :new))

      assert index_live
             |> form("#scene-form", scene: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        index_live
        |> form("#scene-form", scene: @create_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.scene_index_path(conn, :index))

      assert html =~ "Scene created successfully"
    end

    test "updates scene in listing", %{conn: conn, scene: scene} do
      {:ok, index_live, _html} = live(conn, Routes.scene_index_path(conn, :index))

      assert index_live |> element("#scene-#{scene.id} a", "Edit") |> render_click() =~
               "Edit Scene"

      assert_patch(index_live, Routes.scene_index_path(conn, :edit, scene))

      assert index_live
             |> form("#scene-form", scene: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        index_live
        |> form("#scene-form", scene: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.scene_index_path(conn, :index))

      assert html =~ "Scene updated successfully"
    end

    test "deletes scene in listing", %{conn: conn, scene: scene} do
      {:ok, index_live, _html} = live(conn, Routes.scene_index_path(conn, :index))

      assert index_live |> element("#scene-#{scene.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#scene-#{scene.id}")
    end
  end

  describe "Show" do
    setup [:create_scene]

    test "displays scene", %{conn: conn, scene: scene} do
      {:ok, _show_live, html} = live(conn, Routes.scene_show_path(conn, :show, scene))

      assert html =~ "Show Scene"
    end

    test "updates scene within modal", %{conn: conn, scene: scene} do
      {:ok, show_live, _html} = live(conn, Routes.scene_show_path(conn, :show, scene))

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Scene"

      assert_patch(show_live, Routes.scene_show_path(conn, :edit, scene))

      assert show_live
             |> form("#scene-form", scene: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        show_live
        |> form("#scene-form", scene: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.scene_show_path(conn, :show, scene))

      assert html =~ "Scene updated successfully"
    end
  end
end
