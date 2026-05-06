defmodule SceneServer.Voxel.BlueprintCatalogTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.BlueprintCatalog

  test "all/0 lists the v1 hardcoded blueprints in id order" do
    blueprints = BlueprintCatalog.all()
    ids = Enum.map(blueprints, & &1.id)

    assert ids == [1, 2, 3]

    Enum.each(blueprints, fn blueprint ->
      assert blueprint.version == 1
      assert is_binary(blueprint.name) and blueprint.name != ""
      assert is_integer(blueprint.material_id) and blueprint.material_id > 0
      assert is_list(blueprint.cells) and blueprint.cells != []

      Enum.each(blueprint.cells, fn {x, y, z} ->
        assert is_integer(x) and is_integer(y) and is_integer(z)
      end)
    end)
  end

  test "fetch/1 resolves blueprint 1 to a 3-block vertical pillar" do
    assert {:ok, blueprint} = BlueprintCatalog.fetch(1)
    assert blueprint.name == "builtin_pillar_3"
    assert blueprint.material_id == 1
    assert blueprint.cells == [{0, 0, 0}, {0, 1, 0}, {0, 2, 0}]
  end

  test "fetch/1 resolves blueprint 2 to a 3x3 floor at y=0" do
    assert {:ok, blueprint} = BlueprintCatalog.fetch(2)
    assert blueprint.name == "builtin_floor_3x3"
    assert blueprint.material_id == 2

    expected = for x <- 0..2, z <- 0..2, do: {x, 0, z}
    assert Enum.sort(blueprint.cells) == Enum.sort(expected)
    assert length(blueprint.cells) == 9
  end

  test "fetch/1 resolves blueprint 3 to a 2x2x2 cube" do
    assert {:ok, blueprint} = BlueprintCatalog.fetch(3)
    assert blueprint.name == "builtin_cube_2x2x2"
    assert blueprint.material_id == 3

    expected = for x <- 0..1, y <- 0..1, z <- 0..1, do: {x, y, z}
    assert Enum.sort(blueprint.cells) == Enum.sort(expected)
    assert length(blueprint.cells) == 8
  end

  test "fetch/1 rejects unknown blueprint ids" do
    assert {:error, :unknown_blueprint} = BlueprintCatalog.fetch(0)
    assert {:error, :unknown_blueprint} = BlueprintCatalog.fetch(4)
    assert {:error, :unknown_blueprint} = BlueprintCatalog.fetch(9_999)
  end

  test "fetch/1 rejects non-integer or negative blueprint ids" do
    assert {:error, :invalid_blueprint_id} = BlueprintCatalog.fetch(-1)
    assert {:error, :invalid_blueprint_id} = BlueprintCatalog.fetch("1")
    assert {:error, :invalid_blueprint_id} = BlueprintCatalog.fetch(:pillar)
  end

  test "fetch/2 enforces blueprint version 1" do
    assert {:ok, blueprint} = BlueprintCatalog.fetch(1, 1)
    assert blueprint.version == 1

    assert {:error, :blueprint_version_mismatch} = BlueprintCatalog.fetch(1, 2)
    assert {:error, :blueprint_version_mismatch} = BlueprintCatalog.fetch(2, 0)
    assert {:error, :unknown_blueprint} = BlueprintCatalog.fetch(999, 1)
  end

  test "fetch/2 rejects malformed blueprint versions" do
    assert {:error, :invalid_blueprint_version} = BlueprintCatalog.fetch(1, -1)
    assert {:error, :invalid_blueprint_version} = BlueprintCatalog.fetch(1, "1")
  end
end
