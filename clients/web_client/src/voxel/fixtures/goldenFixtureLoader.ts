// Phase 1.6b: load Phase 1.6a server-side golden fixtures into the
// web_client test harness for cross-language wire roundtrip.
//
// Server-side fixtures live under
//   apps/scene_server/priv/fixtures/voxel/<name>.golden       (binary payload)
//   apps/scene_server/priv/fixtures/voxel/<name>.yaml         (sidecar meta)
//
// The `.yaml` sidecar is a tiny `key: value` (one per line) file — the
// Phase 1.6a generator does not write nested mappings or lists, so we parse
// it with a hand-rolled splitter instead of pulling in a yaml dependency
// (web_client package has no js-yaml today and the task forbids new
// dependencies).
//
// vitest runs in a Node environment (see vitest config under
// `clients/web_client/vite.config.ts`), so we can read the ex_mmo_cluster
// repo filesystem directly. Path resolution walks up four levels from this
// file:
//
//   clients/web_client/src/voxel/fixtures/goldenFixtureLoader.ts
//                          ↑ src/  ↑ fixtures/  (back to web_client)
//   clients/web_client/src/voxel/fixtures/   (this file's directory)
//   …/../../../../   →  ex_mmo_cluster repo root
//   apps/scene_server/priv/fixtures/voxel/<name>.{golden,yaml}

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

const FIXTURE_DIR = resolve(
  HERE,
  "../../../../../apps/scene_server/priv/fixtures/voxel",
);

export function fixturePath(name: string, ext: "golden" | "yaml"): string {
  return resolve(FIXTURE_DIR, `${name}.${ext}`);
}

export function loadGoldenBytes(name: string): Uint8Array {
  const buf = readFileSync(fixturePath(name, "golden"));
  // Buffer extends Uint8Array; return a fresh Uint8Array view for callers
  // that want to construct DataViews without worrying about Node Buffer
  // quirks (e.g. shared underlying pool).
  return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength).slice();
}

export interface GoldenSidecar {
  name: string;
  kind: string;
  wireSize: number;
  /** Hex-decoded numeric form for snapshot fixtures. Absent on delta /
   *  catalog_patch / chunk_invalidate / object_state_delta fixtures. */
  chunkHash?: bigint;
  description?: string;
}

const HEX_PREFIX_RE = /^0x([0-9a-fA-F]+)$/;

export function loadSidecar(name: string): GoldenSidecar {
  const raw = readFileSync(fixturePath(name, "yaml"), "utf8");
  const lines = raw.split(/\r?\n/);

  let fixtureName: string | undefined;
  let kind: string | undefined;
  let wireSize: number | undefined;
  let chunkHash: bigint | undefined;
  let description: string | undefined;

  for (const line of lines) {
    if (!line.includes(":")) continue;
    const sepIdx = line.indexOf(":");
    const key = line.slice(0, sepIdx).trim();
    let value = line.slice(sepIdx + 1).trim();

    // Skip yaml block scalar markers ("description: |"). The follow-on
    // indented body lines have no `:`, so they're naturally dropped.
    if (value === "|") {
      value = "";
    }

    switch (key) {
      case "name":
        fixtureName = value;
        break;
      case "kind":
        kind = value;
        break;
      case "wire_size":
        wireSize = Number.parseInt(value, 10);
        break;
      case "chunk_hash": {
        const m = HEX_PREFIX_RE.exec(value);
        if (m && m[1] !== undefined) chunkHash = BigInt(`0x${m[1]}`);
        break;
      }
      case "description":
        description = value;
        break;
    }
  }

  if (fixtureName === undefined || kind === undefined || wireSize === undefined) {
    throw new Error(
      `goldenFixtureLoader: sidecar ${name}.yaml missing required keys (name/kind/wire_size)`,
    );
  }
  return {
    name: fixtureName,
    kind,
    wireSize,
    ...(chunkHash !== undefined ? { chunkHash } : {}),
    ...(description !== undefined ? { description } : {}),
  };
}

export function loadGolden(name: string): { bytes: Uint8Array; meta: GoldenSidecar } {
  const bytes = loadGoldenBytes(name);
  const meta = loadSidecar(name);
  if (bytes.byteLength !== meta.wireSize) {
    throw new Error(
      `goldenFixtureLoader: ${name}.golden byte length ${bytes.byteLength} != sidecar wire_size ${meta.wireSize}`,
    );
  }
  return { bytes, meta };
}

// Phase 1.6a server-side fixture roster, pinned here so the cross-codec
// roundtrip tests stay byte-stable. Mirrors
// `apps/scene_server/test/scene_server/voxel/golden_fixture_test.exs`.

export const SNAPSHOT_FIXTURES = [
  "snapshot_empty",
  "snapshot_macro_only",
  "snapshot_refined",
  "snapshot_environment",
  "snapshot_attribute_pool",
  "snapshot_tag_pool",
  "snapshot_object_refs",
  "snapshot_full",
] as const;

export const DELTA_FIXTURES = [
  "delta_cell_solid",
  "delta_cell_empty",
  "delta_cell_refined",
  "delta_multi_op",
] as const;

export const CHUNK_INVALIDATE_FIXTURES = [
  "chunk_invalidate_unspecified",
  "chunk_invalidate_migration_cutover",
  "chunk_invalidate_region_removed",
  "chunk_invalidate_catalog_changed",
] as const;

export const OBJECT_STATE_DELTA_FIXTURES = [
  "object_state_delta_damaged",
  "object_state_delta_part_destroyed",
  "object_state_delta_destroyed",
] as const;

export const CATALOG_PATCH_FIXTURES = [
  "catalog_patch_attribute_add",
  "catalog_patch_tag_remove",
  "catalog_patch_forward_compat_skip",
] as const;
