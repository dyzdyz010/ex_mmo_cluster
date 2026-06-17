defmodule SceneServer.Voxel.TagCatalogTest do
  # Phase 5.C: TagCatalog GenServer + private ETS。结构对称 AttributeCatalog
  # 但更简单（TagDefinition 仅 id + name）。
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.TagCatalog
  alias SceneServer.Voxel.TagCatalogSnapshot
  alias SceneServer.Voxel.TagDefinition

  setup do
    name = :"tag_catalog_#{System.unique_integer([:positive])}"
    pid = start_supervised!({TagCatalog, name: name})
    %{server: name, pid: pid}
  end

  describe "seed loading" do
    test "loads all 11 tags from priv/catalogs/tag_catalog_v1.exs", %{server: server} do
      snapshot = TagCatalog.current_snapshot(server)
      assert %TagCatalogSnapshot{} = snapshot
      assert snapshot.catalog_version == 4
      assert length(snapshot.definitions) == 11
    end

    test "catalog_version returns 4", %{server: server} do
      assert TagCatalog.catalog_version(server) == 4
    end

    test "definitions are sorted by id ascending and cover 1..11", %{server: server} do
      snapshot = TagCatalog.current_snapshot(server)
      ids = Enum.map(snapshot.definitions, & &1.id)
      assert ids == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    end

    test "definitions carry expected names", %{server: server} do
      snapshot = TagCatalog.current_snapshot(server)
      names = Enum.map(snapshot.definitions, & &1.name)

      assert names == [
               "flammable",
               "conductive",
               "wet",
               "frozen",
               "burning",
               "magical",
               "structural",
               "transparent",
               "powered",
               "open",
               "rusting"
             ]
    end
  end

  describe "lookup_by_id" do
    test "returns {:ok, defn} for id 1 (flammable)", %{server: server} do
      assert {:ok, defn} = TagCatalog.lookup_by_id(server, 1)
      assert %TagDefinition{} = defn
      assert defn.id == 1
      assert defn.name == "flammable"
    end

    test "returns {:ok, defn} for id 8 (transparent)", %{server: server} do
      assert {:ok, defn} = TagCatalog.lookup_by_id(server, 8)
      assert defn.name == "transparent"
    end

    test "returns {:error, :not_found} for id 999", %{server: server} do
      assert {:error, :not_found} = TagCatalog.lookup_by_id(server, 999)
    end

    test "returns {:error, :not_found} for id 0", %{server: server} do
      assert {:error, :not_found} = TagCatalog.lookup_by_id(server, 0)
    end
  end

  describe "lookup_by_name" do
    test "returns {:ok, 2, defn} for conductive", %{server: server} do
      assert {:ok, 2, defn} = TagCatalog.lookup_by_name(server, "conductive")
      assert defn.name == "conductive"
    end

    test "returns {:ok, 6, defn} for magical", %{server: server} do
      assert {:ok, 6, defn} = TagCatalog.lookup_by_name(server, "magical")
      assert defn.id == 6
      assert defn.name == "magical"
    end

    test "returns {:error, :not_found} for unknown name", %{server: server} do
      assert {:error, :not_found} = TagCatalog.lookup_by_name(server, "nonexistent")
    end

    test "is case-sensitive", %{server: server} do
      assert {:error, :not_found} = TagCatalog.lookup_by_name(server, "Flammable")
      assert {:ok, 1, _} = TagCatalog.lookup_by_name(server, "flammable")
    end
  end

  describe "current_snapshot byte-stable encoding" do
    test "matches TagCatalogSnapshot.normalize! invariants", %{server: server} do
      snapshot = TagCatalog.current_snapshot(server)

      wire = TagCatalogSnapshot.encode_for_wire(snapshot)
      decoded = TagCatalogSnapshot.decode_for_wire(wire)

      assert decoded.catalog_version == 4
      assert length(decoded.definitions) == 11
      assert wire == TagCatalogSnapshot.encode_for_wire(decoded)
    end
  end

  describe "reload!" do
    test "reloading default seed yields identical snapshot", %{server: server} do
      before = TagCatalog.current_snapshot(server)
      assert :ok = TagCatalog.reload!(server)
      after_reload = TagCatalog.current_snapshot(server)
      assert before == after_reload
    end
  end
end
