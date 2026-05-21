defmodule SceneServer.Voxel.BlueprintCatalogTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.BlueprintCatalog

  @blueprint_version 2

  test "blueprint_version/0 returns the v2 wire constant" do
    assert BlueprintCatalog.blueprint_version() == @blueprint_version
  end

  test "all/0 lists the v2 hardcoded blueprints in id order" do
    blueprints = BlueprintCatalog.all()
    ids = Enum.map(blueprints, & &1.id)

    assert ids == [1, 2, 3, 4, 5, 6, 7]

    Enum.each(blueprints, fn blueprint ->
      assert blueprint.version == @blueprint_version
      assert is_binary(blueprint.name) and blueprint.name != ""
      assert is_integer(blueprint.material_id) and blueprint.material_id > 0
      assert is_list(blueprint.occupied_slots) and blueprint.occupied_slots != []

      Enum.each(blueprint.occupied_slots, fn slot ->
        assert is_integer(slot) and slot in 0..511
      end)
    end)
  end

  test "fetch/1 resolves blueprint 1 to the sphere shape (Ice material)" do
    assert {:ok, blueprint} = BlueprintCatalog.fetch(1)
    assert blueprint.name == "builtin_sphere"
    # VoxelMaterialId.Ice = 4 (跟 web_client material/catalog.ts 对齐)
    assert blueprint.material_id == 4
    # Sphere with center=4.0, radius=3.9 → ~248 occupied slots(distance check
    # excludes corners). Exact count is platform-stable since BlueprintCatalog
    # 用 compile-time module attribute 算 mask。
    assert length(blueprint.occupied_slots) > 200
    assert length(blueprint.occupied_slots) < 512
  end

  test "fetch/1 resolves blueprint 2 to the cylinder shape (Stone material)" do
    assert {:ok, blueprint} = BlueprintCatalog.fetch(2)
    assert blueprint.name == "builtin_cylinder"
    assert blueprint.material_id == 2
    # Cylinder is sphere-cross-section in xz × full y → > sphere count.
    assert length(blueprint.occupied_slots) > BlueprintCatalog.slot_count(1)
  end

  test "fetch/1 resolves blueprint 3 to the stairs shape (Wood material)" do
    assert {:ok, blueprint} = BlueprintCatalog.fetch(3)
    assert blueprint.name == "builtin_stairs"
    assert blueprint.material_id == 3
    # Stairs:y ≤ x rule → exactly count 1 + 2 + ... + 8 columns × 8 z = 288.
    assert length(blueprint.occupied_slots) == 288
  end

  test "fetch/1 resolves conductive prefab blueprints" do
    assert {:ok, wire} = BlueprintCatalog.fetch(4)
    assert wire.name == "builtin_conductor_wire_x"
    assert wire.material_id == 5
    assert length(wire.occupied_slots) == 32

    assert {:ok, junction} = BlueprintCatalog.fetch(5)
    assert junction.name == "builtin_conductor_junction_xz"
    assert junction.material_id == 5
    assert length(junction.occupied_slots) == 56

    assert {:ok, terminal} = BlueprintCatalog.fetch(6)
    assert terminal.name == "builtin_power_terminal_x"
    assert terminal.material_id == 6
    assert length(terminal.occupied_slots) == 32

    assert {:ok, load_terminal} = BlueprintCatalog.fetch(7)
    assert load_terminal.name == "builtin_load_terminal_x"
    assert load_terminal.material_id == 7
    assert length(load_terminal.occupied_slots) == 32
  end

  test "fetch/1 rejects unknown blueprint ids" do
    assert {:error, :unknown_blueprint} = BlueprintCatalog.fetch(0)
    assert {:error, :unknown_blueprint} = BlueprintCatalog.fetch(8)
    assert {:error, :unknown_blueprint} = BlueprintCatalog.fetch(9_999)
  end

  test "fetch/1 rejects non-integer or negative blueprint ids" do
    assert {:error, :invalid_blueprint_id} = BlueprintCatalog.fetch(-1)
    assert {:error, :invalid_blueprint_id} = BlueprintCatalog.fetch("1")
    assert {:error, :invalid_blueprint_id} = BlueprintCatalog.fetch(:pillar)
  end

  test "fetch/2 enforces blueprint version 2 and rejects v1 (legacy macro list)" do
    assert {:ok, blueprint} = BlueprintCatalog.fetch(1, @blueprint_version)
    assert blueprint.version == @blueprint_version

    assert {:error, :blueprint_version_mismatch} = BlueprintCatalog.fetch(1, 1)
    assert {:error, :blueprint_version_mismatch} = BlueprintCatalog.fetch(2, 0)
    assert {:error, :unknown_blueprint} = BlueprintCatalog.fetch(999, @blueprint_version)
  end

  test "fetch/2 rejects malformed blueprint versions" do
    assert {:error, :invalid_blueprint_version} = BlueprintCatalog.fetch(1, -1)
    assert {:error, :invalid_blueprint_version} = BlueprintCatalog.fetch(1, "1")
  end
end
