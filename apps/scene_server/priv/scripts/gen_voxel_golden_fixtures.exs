# Run from umbrella root with:
#   mix run apps/scene_server/priv/scripts/gen_voxel_golden_fixtures.exs
# (or from scene_server: cd apps/scene_server && mix run priv/scripts/gen_voxel_golden_fixtures.exs)
#
# Phase 1.6a: generates the server-side snapshot / delta / catalog_patch /
# chunk_invalidate / object_state_delta golden binary fixtures under:
#   apps/scene_server/priv/fixtures/voxel/
#
# Each `.golden` is a pure binary payload (no opcode prefix) — same shape as
# what `SceneServer.Voxel.Codec.encode_*_payload` / `CatalogPatch.encode_for_wire`
# produce. Each `.golden` has a sidecar `.yaml` with metadata
# (name / description / wire_size / chunk_hash where applicable).
#
# This script is deterministic; re-running it on a clean tree must produce
# byte-identical files. The fixture loader in test/scene_server/voxel/
# golden_fixture_test.exs asserts decode → re-encode byte-stable for every
# fixture, plus chunk_hash equivalence for snapshot fixtures.
#
# Phase 1.6b (web_client TS decoder consuming these fixtures) is a separate
# commit.

alias SceneServer.Voxel.CatalogPatch
alias SceneServer.Voxel.Codec
alias SceneServer.Voxel.PartState
alias SceneServer.Voxel.Storage

defmodule FixtureGen do
  alias SceneServer.Voxel.AttributeEntry
  alias SceneServer.Voxel.AttributeSet
  alias SceneServer.Voxel.CatalogPatch
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.MacroEnvironmentSummary
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.ObjectCoverRef
  alias SceneServer.Voxel.RefinedCellData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.SurfaceCatalog
  alias SceneServer.Voxel.TagSet
  alias SceneServer.Voxel.Types

  # ---- snapshot fixtures -----------------------------------------------------

  @doc "snapshot_empty: minimal empty chunk, no payload sections populated."
  def snapshot_empty do
    Storage.empty(1, {0, 0, 0}, chunk_version: 1)
  end

  @doc "snapshot_macro_only: 9 solid blocks (3x3 platform at y=0) via Storage.put_solid_block."
  def snapshot_macro_only do
    base = Storage.empty(2, {1, 0, 1}, chunk_version: 5)
    block = NormalBlockData.new(11, health: 100)

    Enum.reduce(0..8, base, fn i, acc ->
      mx = rem(i, 3)
      mz = div(i, 3)

      Storage.put_solid_block(acc, {mx, 0, mz}, block,
        cell_version: 1,
        cell_hash: 0xB000_0000 + i
      )
    end)
  end

  @doc """
  snapshot_refined: one macro upgraded to refined mode with multi-layer
  RefinedCellData carrying owner_object_id / owner_part_id provenance.
  """
  def snapshot_refined do
    base = Storage.empty(3, {-2, 0, 5}, chunk_version: 11)

    # Layer A: terrain rocks at "top half" of the macro (slots 256..511 within
    # the upper four mask words). owner_object_id = 0 => terrain.
    base
    |> Storage.put_micro_block({4, 4, 4}, 0, %{material_id: 7, health: 50},
      cell_version: 1,
      cell_hash: 0xC000_0001
    )
    |> Storage.put_micro_block({4, 4, 4}, 1, %{material_id: 7, health: 50})
    |> Storage.put_micro_block({4, 4, 4}, 2, %{material_id: 7, health: 50})
    # Different signature => second layer (object-owned).
    |> Storage.put_micro_block({4, 4, 4}, 256, %{
      material_id: 42,
      state_flags: 0x01,
      health: 200,
      owner_object_id: 0x0000_0000_DEAD_BEEF,
      owner_part_id: 3
    })
    |> Storage.put_micro_block({4, 4, 4}, 257, %{
      material_id: 42,
      state_flags: 0x01,
      health: 200,
      owner_object_id: 0x0000_0000_DEAD_BEEF,
      owner_part_id: 3
    })
  end

  @doc """
  snapshot_environment: chunk carrying a macro_environment_summaries entry with
  non-default temperature / moisture / field_mask. Validates section 0x06.
  """
  def snapshot_environment do
    base = Storage.empty(4, {0, 1, 0}, chunk_version: 3)

    env =
      MacroEnvironmentSummary.new(
        default_temperature: 20,
        default_moisture: 40,
        current_temperature: 32,
        current_moisture: 55,
        field_mask: 0x000F,
        source_hash: 0xDEAD_F00D
      )

    %{base | environment_summaries: [env]} |> Storage.normalize!()
  end

  @doc """
  snapshot_attribute_pool: chunk carrying a populated AttributeSet pool, one
  entry per value_type tag (0x01..0x05), to validate section 0x04 wire layout.
  """
  def snapshot_attribute_pool do
    base = Storage.empty(5, {0, 0, 0}, chunk_version: 13)

    set =
      AttributeSet.new(%{
        entries: [
          %{key_id: 10, value_type: AttributeEntry.value_type_i16(), value: -1234},
          %{key_id: 20, value_type: AttributeEntry.value_type_u16(), value: 0xABCD},
          %{
            key_id: 30,
            value_type: AttributeEntry.value_type_fixed32(),
            value: 0x0001_0000
          },
          %{key_id: 40, value_type: AttributeEntry.value_type_enum8(), value: 7},
          %{
            key_id: 50,
            value_type: AttributeEntry.value_type_bitset32(),
            value: 0xDEAD_BEEF
          }
        ]
      })

    %{base | attribute_sets: [set]} |> Storage.normalize!()
  end

  @doc """
  snapshot_tag_pool: chunk carrying a populated TagSet pool, validating section
  0x05 wire layout.
  """
  def snapshot_tag_pool do
    base = Storage.empty(6, {3, 3, 3}, chunk_version: 21)

    set_a = TagSet.new(%{tag_ids: [1, 100, 0x0000_FFFF, 0xDEAD_BEEF]})
    set_b = TagSet.new(%{tag_ids: [7, 8, 9]})

    %{base | tag_sets: [set_a, set_b]} |> Storage.normalize!()
  end

  @doc """
  snapshot_object_refs: chunk carrying a chunk-level ChunkObjectRef pool entry
  (section 0x07). Built via Storage.refresh_chunk_object_refs/1 after writing
  an object-owned refined cell so the AABB + cover_hash stay canonical.
  """
  def snapshot_object_refs do
    base = Storage.empty(7, {5, 0, -5}, chunk_version: 17)

    storage =
      base
      |> Storage.put_micro_block({2, 0, 2}, 64, %{
        material_id: 99,
        health: 100,
        owner_object_id: 0x0000_0000_BEEF_F00D,
        owner_part_id: 1
      })
      |> Storage.put_micro_block({2, 0, 2}, 65, %{
        material_id: 99,
        health: 100,
        owner_object_id: 0x0000_0000_BEEF_F00D,
        owner_part_id: 1
      })

    if function_exported?(Storage, :refresh_chunk_object_refs, 1) do
      Storage.refresh_chunk_object_refs(storage)
    else
      # fallback: object_refs stay empty; the refined-cell-level provenance
      # is still carried in section 0x03 via MicroLayer owner_object_id.
      storage
    end
  end

  @doc """
  snapshot_full: a combined chunk exercising every payload section at once —
  macro solid blocks, refined cells with multi-layer + object provenance,
  environment summary, attribute pool, tag pool, and chunk-level object_refs.
  """
  def snapshot_full do
    block = NormalBlockData.new(8, health: 200)

    base = Storage.empty(8, {1, 2, 3}, chunk_version: 42)

    attr_set =
      AttributeSet.new(%{
        entries: [
          %{key_id: 1, value_type: AttributeEntry.value_type_i16(), value: -1},
          %{key_id: 2, value_type: AttributeEntry.value_type_u16(), value: 65535}
        ]
      })

    tag_set = TagSet.new(%{tag_ids: [10, 20, 30]})

    env =
      MacroEnvironmentSummary.new(
        default_temperature: 18,
        default_moisture: 35,
        current_temperature: 24,
        current_moisture: 50,
        field_mask: 0x0003,
        source_hash: 0x9ABC_DEF0
      )

    storage =
      base
      |> Storage.put_solid_block({0, 0, 0}, block, cell_version: 1, cell_hash: 0xD000_0001)
      |> Storage.put_solid_block({1, 0, 0}, block, cell_version: 1, cell_hash: 0xD000_0002)
      |> Storage.put_micro_block({5, 5, 5}, 100, %{
        material_id: 77,
        health: 100,
        owner_object_id: 0xCAFE_F00D,
        owner_part_id: 2
      })
      |> Storage.put_micro_block({5, 5, 5}, 101, %{
        material_id: 77,
        health: 100,
        owner_object_id: 0xCAFE_F00D,
        owner_part_id: 2
      })

    storage =
      %{
        storage
        | environment_summaries: [env],
          attribute_sets: [attr_set],
          tag_sets: [tag_set]
      }
      |> Storage.normalize!()

    if function_exported?(Storage, :refresh_chunk_object_refs, 1) do
      Storage.refresh_chunk_object_refs(storage)
    else
      storage
    end
  end

  @doc """
  snapshot_surface_elements: chunk carrying surface elements (section 0x08,
  形态轨) on several macro faces — torch / rust_decal / frost, including one with
  non-zero attribute_set_ref / tag_set_ref / owner_actor_id. Validates the
  append-only surface-element wire layout for cross-language (bevy) decode parity.
  """
  def snapshot_surface_elements do
    base = Storage.empty(9, {2, 0, -3}, chunk_version: 23)
    wall = Types.macro_index!({1, 0, 0})
    other = Types.macro_index!({2, 0, 0})

    base
    |> Storage.put_solid_block({1, 0, 0}, NormalBlockData.new(5, health: 100))
    |> Storage.put_surface_element(%{
      macro_index: wall,
      face: :x_pos,
      surface_type_id: SurfaceCatalog.surface_type_id(:torch)
    })
    |> Storage.put_surface_element(%{
      macro_index: wall,
      face: :y_neg,
      surface_type_id: SurfaceCatalog.surface_type_id(:rust_decal)
    })
    |> Storage.put_surface_element(%{
      macro_index: other,
      face: :z_pos,
      surface_type_id: SurfaceCatalog.surface_type_id(:frost),
      attribute_set_ref: 3,
      tag_set_ref: 5,
      owner_actor_id: 12_345
    })
  end

  # ---- delta fixtures --------------------------------------------------------

  @doc """
  delta_cell_solid: ChunkDelta payload with one op delta_kind=1 (CellSolid),
  payload = 20-byte NormalBlockData. Mirrors the on-the-wire op a Scene emits
  when a macro cell flips empty → solid.
  """
  def delta_cell_solid do
    block = NormalBlockData.new(11, health: 100)
    block_payload = Codec.encode_normal_block_data(block)

    %{
      logical_scene_id: 10,
      chunk_coord: {0, 0, 0},
      base_chunk_version: 1,
      new_chunk_version: 2,
      ops: [
        %{
          delta_kind: 1,
          macro_index: 1234,
          cell_version: 2,
          cell_hash: 0xCAFE_BABE,
          payload: block_payload
        }
      ]
    }
  end

  @doc """
  delta_cell_empty: ChunkDelta payload with one op delta_kind=0 (CellEmpty),
  no payload (a macro cell flipped solid → empty / refined → empty).
  """
  def delta_cell_empty do
    %{
      logical_scene_id: 10,
      chunk_coord: {0, 0, 0},
      base_chunk_version: 2,
      new_chunk_version: 3,
      ops: [
        %{
          delta_kind: 0,
          macro_index: 1234,
          cell_version: 3,
          cell_hash: 0,
          payload: <<>>
        }
      ]
    }
  end

  @doc """
  delta_cell_refined: ChunkDelta payload with one op delta_kind=2 (CellRefined),
  payload = a full RefinedCellData binary (multi-layer + object cover ref).
  """
  def delta_cell_refined do
    layer_a =
      MicroLayer.new(
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0xF0],
        material_id: 42,
        state_flags: 0,
        health: 100,
        attribute_set_ref: 0,
        tag_set_ref: 0,
        owner_object_id: 0xDEAD_BEEF,
        owner_part_id: 7
      )

    layer_b =
      MicroLayer.new(
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0x0F],
        material_id: 99,
        state_flags: 0x01,
        health: 50,
        attribute_set_ref: 0,
        tag_set_ref: 0,
        owner_object_id: 0,
        owner_part_id: 0
      )

    object_ref =
      ObjectCoverRef.new(
        owner_object_id: 0xDEAD_BEEF,
        owner_part_id: 7,
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0xF0]
      )

    cell =
      RefinedCellData.new(
        occupancy_words: [0, 0, 0, 0, 0, 0, 0, 0xFF],
        boundary_cache: 0xCAFE_BABE_DEAD_BEEF,
        layers: [layer_a, layer_b],
        object_refs: [object_ref]
      )

    refined_payload = Codec.encode_refined_cell_payload(cell)

    %{
      logical_scene_id: 11,
      chunk_coord: {2, 0, -1},
      base_chunk_version: 5,
      new_chunk_version: 6,
      ops: [
        %{
          delta_kind: 2,
          macro_index: 2048,
          cell_version: 6,
          cell_hash: 0xFEED_F00D,
          payload: refined_payload
        }
      ]
    }
  end

  @doc """
  delta_multi_op: ChunkDelta with three ops (CellEmpty + CellSolid + CellSolid)
  to validate op stream framing (op_count u16 + payload_len skip).
  """
  def delta_multi_op do
    block_a = NormalBlockData.new(7, health: 80)
    block_b = NormalBlockData.new(8, health: 90)

    %{
      logical_scene_id: 12,
      chunk_coord: {-3, 4, -5},
      base_chunk_version: 100,
      new_chunk_version: 101,
      ops: [
        %{
          delta_kind: 0,
          macro_index: 10,
          cell_version: 101,
          cell_hash: 0,
          payload: <<>>
        },
        %{
          delta_kind: 1,
          macro_index: 20,
          cell_version: 101,
          cell_hash: 0xAAAA,
          payload: Codec.encode_normal_block_data(block_a)
        },
        %{
          delta_kind: 1,
          macro_index: 30,
          cell_version: 101,
          cell_hash: 0xBBBB,
          payload: Codec.encode_normal_block_data(block_b)
        }
      ]
    }
  end

  # ---- chunk_invalidate fixtures --------------------------------------------

  @doc """
  chunk_invalidate: ChunkInvalidate payload with reason byte. Generates one
  fixture variant per defined reason (0x00 unspecified, 0x01 migration_cutover,
  0x02 region_removed, 0x03 catalog_changed).
  """
  def chunk_invalidate_variants do
    [
      {0x00, "unspecified"},
      {0x01, "migration_cutover"},
      {0x02, "region_removed"},
      {0x03, "catalog_changed"}
    ]
  end

  def chunk_invalidate_payload(reason) do
    %{
      logical_scene_id: 50,
      chunk_coord: {1, 2, 3},
      reason: reason
    }
  end

  # ---- object_state_delta fixtures ------------------------------------------

  @doc """
  object_state_delta: 0x6C payload variants — three fixtures for each of the
  three D5 single-event state_flags (damaged / part_destroyed / destroyed).
  """
  def object_state_delta_variants do
    [
      {PartState.flag_damaged(), "damaged"},
      {PartState.flag_part_destroyed(), "part_destroyed"},
      {PartState.flag_destroyed(), "destroyed"}
    ]
  end

  def object_state_delta_payload(state_flags) do
    %{
      logical_scene_id: 7,
      object_id: 0x0000_0000_BEEF_F00D,
      object_version: 42,
      state_flags: state_flags,
      affected_chunks: [{0, 0, 0}, {1, 0, 0}]
    }
  end

  # ---- catalog_patch fixtures -----------------------------------------------

  @doc """
  catalog_patch_attribute_add: 0x71 CatalogPatch envelope, schema_kind=0x01
  (attribute), one op_kind=0x01 (add) with raw payload.
  """
  def catalog_patch_attribute_add do
    %CatalogPatch{
      schema_kind: CatalogPatch.schema_attribute(),
      base_version: 0,
      new_version: 1,
      ops: [
        %{
          op_kind: CatalogPatch.op_add(),
          entry_id: 0x1000,
          payload: <<0x01, 0x02, 0x03, 0x04>>
        }
      ]
    }
  end

  @doc """
  catalog_patch_tag_remove: 0x71 CatalogPatch envelope, schema_kind=0x02 (tag),
  one op_kind=0x02 (remove) with empty payload.
  """
  def catalog_patch_tag_remove do
    %CatalogPatch{
      schema_kind: CatalogPatch.schema_tag(),
      base_version: 5,
      new_version: 6,
      ops: [
        %{
          op_kind: CatalogPatch.op_remove(),
          entry_id: 0xCAFE,
          payload: <<>>
        }
      ]
    }
  end

  @doc """
  catalog_patch_forward_compat_skip: 0x71 envelope with an op carrying an
  unknown op_kind (0xFE). Decoders preserve the raw payload + op_kind for
  byte-identical re-encode (forward-compat).
  """
  def catalog_patch_forward_compat_skip do
    # Bypass normalize!/1 (which rejects unknown op_kinds) by constructing the
    # struct directly. encode_for_wire/1 accepts the raw struct path.
    %CatalogPatch{
      schema_kind: CatalogPatch.schema_attribute(),
      base_version: 9,
      new_version: 10,
      ops: [
        %{op_kind: 0x01, entry_id: 1, payload: <<0xAA>>},
        %{op_kind: 0xFE, entry_id: 999, payload: <<0xDE, 0xAD, 0xBE, 0xEF>>},
        %{op_kind: 0x03, entry_id: 2, payload: <<0xBB, 0xCC>>}
      ]
    }
  end
end

# ---- fixture catalog ---------------------------------------------------------

script_dir = Path.dirname(__ENV__.file)
scene_server_root = Path.expand("../..", script_dir)
fixtures_dir = Path.join(scene_server_root, "priv/fixtures/voxel")
File.mkdir_p!(fixtures_dir)

snapshot_fixtures = [
  {"snapshot_empty", FixtureGen.snapshot_empty(),
   "Empty chunk: 4096 empty macro headers, all payload sections empty."},
  {"snapshot_macro_only", FixtureGen.snapshot_macro_only(),
   "3x3 platform of solid blocks (material 11) at y=0."},
  {"snapshot_refined", FixtureGen.snapshot_refined(),
   "One refined macro with multi-layer cell + owner_object_id provenance."},
  {"snapshot_environment", FixtureGen.snapshot_environment(),
   "Chunk carrying one macro_environment_summaries entry (non-default temp/moisture)."},
  {"snapshot_attribute_pool", FixtureGen.snapshot_attribute_pool(),
   "AttributeSet pool with one set covering all 5 value_type tags (0x01..0x05)."},
  {"snapshot_tag_pool", FixtureGen.snapshot_tag_pool(),
   "TagSet pool with two sets (4-tag and 3-tag) to exercise section 0x05."},
  {"snapshot_object_refs", FixtureGen.snapshot_object_refs(),
   "Chunk-level object_refs section populated via refresh_chunk_object_refs after object-owned refined writes."},
  {"snapshot_full", FixtureGen.snapshot_full(),
   "All sections populated together: macro + refined + environment + attribute + tag + object_refs."},
  {"snapshot_surface_elements", FixtureGen.snapshot_surface_elements(),
   "Surface elements (section 0x08): torch / rust_decal / frost on macro faces, one with attr/tag/owner refs."}
]

delta_fixtures = [
  {"delta_cell_solid", FixtureGen.delta_cell_solid(), "ChunkDelta op delta_kind=1 (CellSolid)."},
  {"delta_cell_empty", FixtureGen.delta_cell_empty(), "ChunkDelta op delta_kind=0 (CellEmpty)."},
  {"delta_cell_refined", FixtureGen.delta_cell_refined(),
   "ChunkDelta op delta_kind=2 (CellRefined) carrying a RefinedCellData payload."},
  {"delta_multi_op", FixtureGen.delta_multi_op(),
   "ChunkDelta with three ops (CellEmpty + CellSolid + CellSolid) to test op stream framing."}
]

catalog_patch_fixtures = [
  {"catalog_patch_attribute_add", FixtureGen.catalog_patch_attribute_add(),
   "0x71 CatalogPatch: schema_kind=0x01 (attribute), op_kind=0x01 (add) with 4-byte payload."},
  {"catalog_patch_tag_remove", FixtureGen.catalog_patch_tag_remove(),
   "0x71 CatalogPatch: schema_kind=0x02 (tag), op_kind=0x02 (remove) with empty payload."},
  {"catalog_patch_forward_compat_skip", FixtureGen.catalog_patch_forward_compat_skip(),
   "0x71 CatalogPatch: 3 ops including one with unknown op_kind=0xFE (forward-compat skip)."}
]

write_fixture = fn relative_name, bytes, metadata ->
  golden_path = Path.join(fixtures_dir, "#{relative_name}.golden")
  yaml_path = Path.join(fixtures_dir, "#{relative_name}.yaml")

  File.write!(golden_path, bytes)

  yaml_lines =
    [
      "name: #{metadata.name}",
      "kind: #{metadata.kind}",
      "wire_size: #{byte_size(bytes)}",
      (metadata[:chunk_hash] &&
         "chunk_hash: 0x#{Integer.to_string(metadata.chunk_hash, 16) |> String.pad_leading(16, "0")}") ||
        nil,
      "description: |",
      "  #{metadata.description}"
    ]
    |> Enum.reject(&is_nil/1)

  File.write!(yaml_path, Enum.join(yaml_lines, "\n") <> "\n")

  IO.puts("  #{relative_name}.golden (#{byte_size(bytes)} bytes)")
end

IO.puts("Writing snapshot fixtures:")

Enum.each(snapshot_fixtures, fn {name, storage, description} ->
  storage = Storage.normalize!(storage)
  bytes = Codec.encode_chunk_snapshot_payload(%{request_id: 0, storage: storage})
  chunk_hash = Codec.chunk_hash(storage)

  write_fixture.(name, bytes, %{
    name: name,
    kind: "chunk_snapshot",
    description: description,
    chunk_hash: chunk_hash
  })
end)

IO.puts("Writing delta fixtures:")

Enum.each(delta_fixtures, fn {name, delta, description} ->
  bytes = Codec.encode_chunk_delta_payload(delta)

  write_fixture.(name, bytes, %{
    name: name,
    kind: "chunk_delta",
    description: description
  })
end)

IO.puts("Writing chunk_invalidate fixtures:")

Enum.each(FixtureGen.chunk_invalidate_variants(), fn {reason, reason_name} ->
  name = "chunk_invalidate_#{reason_name}"
  bytes = Codec.encode_chunk_invalidate_payload(FixtureGen.chunk_invalidate_payload(reason))

  write_fixture.(name, bytes, %{
    name: name,
    kind: "chunk_invalidate",
    description:
      "ChunkInvalidate payload with reason=0x#{Integer.to_string(reason, 16) |> String.pad_leading(2, "0")} (#{reason_name})."
  })
end)

IO.puts("Writing object_state_delta fixtures:")

Enum.each(FixtureGen.object_state_delta_variants(), fn {state_flags, flag_name} ->
  name = "object_state_delta_#{flag_name}"

  bytes =
    Codec.encode_voxel_object_state_delta_payload(
      FixtureGen.object_state_delta_payload(state_flags)
    )

  write_fixture.(name, bytes, %{
    name: name,
    kind: "object_state_delta",
    description:
      "0x6C ObjectStateDelta payload with state_flags=0x#{Integer.to_string(state_flags, 16) |> String.pad_leading(2, "0")} (#{flag_name})."
  })
end)

IO.puts("Writing catalog_patch fixtures:")

Enum.each(catalog_patch_fixtures, fn {name, patch, description} ->
  bytes = CatalogPatch.encode_for_wire(patch)

  write_fixture.(name, bytes, %{
    name: name,
    kind: "catalog_patch",
    description: description
  })
end)

IO.puts("\nfixtures dir: #{Path.expand(fixtures_dir)}")
