import { describe, expect, it } from "vitest";
import { VoxelMaterialId } from "../material/catalog";
import { VoxelConstants } from "./core/constants";
import { EVoxelCellMode } from "./core/types";
import { FullMicroOccupancyMask, MicroGridSlotCount } from "./microgrid/governance";
import { LocalPrefabRegistry } from "./prefab";
import { ChunkStorage } from "./storage/chunkStorage";
import { createSurfaceAttachment } from "./surfaceAttachment";
import { WorldStore } from "./worldStore";

function block(materialId: number) {
  return {
    materialId,
    stateFlags: 0,
    health: 100,
    temperatureDelta: 0,
    moistureDelta: 0,
  };
}

describe("WorldStore snapshots", () => {
  it("exports and imports normal and refined prefab cells without losing occupancy", () => {
    const source = new WorldStore();
    source.setNormalBlockWorld({ x: 1, y: 2, z: 3 }, block(VoxelMaterialId.Stone));
    const prefabs = new LocalPrefabRegistry();
    prefabs.place("builtin_sphere", { x: 4, y: 5, z: 6 }, source);

    const snapshot = source.exportSnapshot();
    const imported = new WorldStore();
    imported.importSnapshot(snapshot);

    expect(imported.getNormalBlockWorld({ x: 1, y: 2, z: 3 })?.materialId).toBe(
      VoxelMaterialId.Stone,
    );
    expect(imported.getNormalBlockWorld({ x: 4, y: 5, z: 6 })?.materialId).toBe(
      VoxelMaterialId.Ice,
    );

    const refinedChunk = imported.getChunk({ x: 0, y: 0, z: 0 });
    const header = refinedChunk?.getHeaderAt({ x: 4, y: 5, z: 6 });
    expect(header?.mode).toBe(EVoxelCellMode.Refined);
    expect(
      refinedChunk?.data.refinedCells[header?.payloadIndex ?? -1]?.microOccupancyMask,
    ).not.toBe(0n);
  });

  it("roundtrips surface attachments as first-class snapshot truth without turning them into occupancy", () => {
    const source = new WorldStore();
    const attachment = createSurfaceAttachment({
      id: "surface-wire-1",
      anchorMacro: { x: 3, y: 4, z: 5 },
      anchorMicro: {
        x: 3 * VoxelConstants.MicroPerMacro,
        y: 4 * VoxelConstants.MicroPerMacro + 2,
        z: 5 * VoxelConstants.MicroPerMacro + 1,
      },
      face: "x_pos",
      materialId: VoxelMaterialId.Iron,
      faceMask: 0b1011n,
      ownerObjectId: 77n,
      ownerPartId: 4,
      visibilityPolicy: "hide_when_neighbor_occupied",
    });

    source.upsertSurfaceAttachment(attachment);

    const snapshot = source.exportSnapshot();
    expect(snapshot.chunks[0]?.surfaceAttachments).toEqual([
      expect.objectContaining({
        id: "surface-wire-1",
        faceMask: "11",
        ownerObjectId: "77",
        visibilityPolicy: "hide_when_neighbor_occupied",
      }),
    ]);

    const imported = new WorldStore();
    imported.importSnapshot(snapshot);

    expect(imported.listSurfaceAttachments()).toEqual([attachment]);
    expect(imported.getMicroOccupancyMaskWorld(attachment.anchorMacro)).toBe(0n);
    expect(imported.getVisibleSurfaceAttachmentsAtWorldMacro(attachment.anchorMacro)).toEqual([
      attachment,
    ]);
  });
});

describe("WorldStore microgrid governance", () => {
  it("stores a single occupied micro cell as a high-resolution refined payload", () => {
    const world = new WorldStore();
    const macro = { x: 1, y: 2, z: 3 };
    const micro = { x: 0, y: 1, z: 2 };

    expect(world.setMicroBlockWorld(macro, micro, block(VoxelMaterialId.Wood))).toBe(true);
    expect(world.getMicroBlockWorld(macro, micro)?.materialId).toBe(VoxelMaterialId.Wood);
    expect(
      world.setMicroBlockWorld(
        macro,
        { x: VoxelConstants.MicroPerMacro, y: 0, z: 0 },
        block(VoxelMaterialId.Wood),
      ),
    ).toBe(false);

    const chunk = world.getChunk({ x: 0, y: 0, z: 0 });
    const header = chunk?.getHeaderAt(macro);
    const refined = chunk?.data.refinedCells[header?.payloadIndex ?? -1];

    expect(header?.mode).toBe(EVoxelCellMode.Refined);
    expect(VoxelConstants.MicroPerMacro).toBeGreaterThanOrEqual(8);
    expect(refined?.microOccupancyMask).toBe(
      1n <<
        BigInt(
          micro.x +
            micro.y * VoxelConstants.MicroPerMacro +
            micro.z * VoxelConstants.MicroPerMacro * VoxelConstants.MicroPerMacro,
        ),
    );
    expect(refined?.microMaterialIds).toHaveLength(MicroGridSlotCount);
    expect(refined?.microStateFlags).toHaveLength(MicroGridSlotCount);
    expect(refined?.microPartIds).toHaveLength(MicroGridSlotCount);
    expect(world.editStats.rejected).toBe(1);
  });

  it("chisels one micro cell out of a solid macro without dropping the rest of the block", () => {
    const world = new WorldStore();
    const macro = { x: 0, y: 0, z: 0 };

    world.setNormalBlockWorld(macro, block(VoxelMaterialId.Stone));

    expect(world.clearMicroBlockWorld(macro, { x: 0, y: 0, z: 0 })).toBe(true);
    expect(world.getMicroBlockWorld(macro, { x: 0, y: 0, z: 0 })).toBeNull();
    expect(world.getMicroBlockWorld(macro, { x: 1, y: 0, z: 0 })?.materialId).toBe(
      VoxelMaterialId.Stone,
    );

    const chunk = world.getChunk({ x: 0, y: 0, z: 0 });
    const header = chunk?.getHeaderAt(macro);
    const refined = chunk?.data.refinedCells[header?.payloadIndex ?? -1];

    expect(header?.mode).toBe(EVoxelCellMode.Refined);
    expect(refined?.microOccupancyMask).toBe(FullMicroOccupancyMask & ~1n);
  });
});

describe("WorldStore showcase seed", () => {
  it("builds the regional demo terrain and resets edit counters", () => {
    const world = new WorldStore();
    world.setNormalBlockWorld({ x: 0, y: 0, z: 0 }, block(VoxelMaterialId.Stone));
    world.markConflict();

    world.seedRegionalShowcase(1);

    expect(world.totalSolidBlocks()).toBeGreaterThan(0);
    expect(world.getNormalBlockWorld({ x: 0, y: 3, z: 0 })?.materialId).toBe(VoxelMaterialId.Ice);
    expect(world.getEnvironmentSummaryWorld({ x: 0, y: 3, z: 0 })?.currentTemperature).toBe(-42);
    expect(world.editStats).toEqual({ placed: 0, broken: 0, rejected: 0, conflicts: 0 });
  });
});

describe("WorldStore surface attachments", () => {
  it("stores face-only surface prefab truth without occupying the anchor macro cell", () => {
    const world = new WorldStore();
    const attachment = createSurfaceAttachment({
      id: "surface-wire-2",
      anchorMacro: { x: 8, y: 2, z: 3 },
      anchorMicro: {
        x: 8 * VoxelConstants.MicroPerMacro,
        y: 2 * VoxelConstants.MicroPerMacro,
        z: 3 * VoxelConstants.MicroPerMacro,
      },
      face: "x_pos",
      materialId: VoxelMaterialId.Iron,
      faceMask: 0b1n,
      ownerObjectId: 88n,
      ownerPartId: 5,
      visibilityPolicy: "hide_when_neighbor_occupied",
    });

    world.upsertSurfaceAttachment(attachment);

    expect(world.listSurfaceAttachments()).toEqual([attachment]);
    expect(world.listSurfaceAttachmentsAtWorldMacro(attachment.anchorMacro)).toEqual([attachment]);
    expect(world.getVisibleSurfaceAttachmentsAtWorldMacro(attachment.anchorMacro)).toEqual([
      attachment,
    ]);
    expect(world.isSurfaceAttachmentVisible(attachment.id)).toBe(true);
    expect(world.isSolidWorldMacroCoord(attachment.anchorMacro)).toBe(false);
    expect(world.getMicroOccupancyMaskWorld(attachment.anchorMacro)).toBe(0n);

    world.setNormalBlockWorld({ x: 9, y: 2, z: 3 }, block(VoxelMaterialId.Stone));

    expect(world.listSurfaceAttachmentsAtWorldMacro(attachment.anchorMacro)).toEqual([attachment]);
    expect(world.getVisibleSurfaceAttachmentsAtWorldMacro(attachment.anchorMacro)).toEqual([]);
    expect(world.isSurfaceAttachmentVisible(attachment.id)).toBe(false);
  });

  it("keeps always-visible surface attachments listed even when the neighboring macro becomes occupied", () => {
    const world = new WorldStore();
    const attachment = createSurfaceAttachment({
      id: "surface-wire-3",
      anchorMacro: { x: 10, y: 2, z: 3 },
      anchorMicro: {
        x: 10 * VoxelConstants.MicroPerMacro,
        y: 2 * VoxelConstants.MicroPerMacro,
        z: 3 * VoxelConstants.MicroPerMacro,
      },
      face: "x_neg",
      materialId: VoxelMaterialId.Iron,
      faceMask: 0b1n,
      ownerObjectId: 89n,
      ownerPartId: 6,
      visibilityPolicy: "always_visible",
    });

    world.upsertSurfaceAttachment(attachment);
    world.setNormalBlockWorld({ x: 9, y: 2, z: 3 }, block(VoxelMaterialId.Stone));

    expect(world.isSurfaceAttachmentVisible(attachment.id)).toBe(true);
    expect(world.getVisibleSurfaceAttachmentsAtWorldMacro(attachment.anchorMacro)).toEqual([
      attachment,
    ]);
  });

  it("hides surface attachments only when refined neighbor occupancy overlaps the covered face", () => {
    const world = new WorldStore();
    const attachment = createSurfaceAttachment({
      id: "surface-wire-3b",
      anchorMacro: { x: 8, y: 2, z: 3 },
      anchorMicro: {
        x: 8 * VoxelConstants.MicroPerMacro,
        y: 2 * VoxelConstants.MicroPerMacro,
        z: 3 * VoxelConstants.MicroPerMacro,
      },
      face: "x_pos",
      materialId: VoxelMaterialId.Iron,
      faceMask: 0b1n,
      ownerObjectId: 91n,
      ownerPartId: 8,
      visibilityPolicy: "hide_when_neighbor_occupied",
    });

    world.upsertSurfaceAttachment(attachment);

    expect(
      world.setMicroBlockWorld(
        { x: 9, y: 2, z: 3 },
        { x: 0, y: 1, z: 0 },
        block(VoxelMaterialId.Stone),
      ),
    ).toBe(true);
    expect(world.isSurfaceAttachmentVisible(attachment.id)).toBe(true);

    expect(
      world.setMicroBlockWorld(
        { x: 9, y: 2, z: 3 },
        { x: 0, y: 0, z: 0 },
        block(VoxelMaterialId.Stone),
      ),
    ).toBe(true);
    expect(world.isSurfaceAttachmentVisible(attachment.id)).toBe(false);
  });

  it("clones surface attachment arrays when authoritative chunk storage is replaced", () => {
    const source = ChunkStorage.createEmpty({ x: 0, y: 0, z: 0 }).data;
    source.surfaceAttachments = [
      createSurfaceAttachment({
        id: "surface-wire-4",
        anchorMacro: { x: 0, y: 0, z: 0 },
        anchorMicro: { x: 0, y: 0, z: 0 },
        face: "z_pos",
        materialId: VoxelMaterialId.Iron,
        faceMask: 0b1111n,
        ownerObjectId: 90n,
        ownerPartId: 7,
        visibilityPolicy: "hide_when_neighbor_occupied",
      }),
    ];

    const world = new WorldStore();
    world.replaceChunkStorage(source);
    source.surfaceAttachments[0]!.materialId = VoxelMaterialId.Stone;

    expect(world.listSurfaceAttachments()).toEqual([
      expect.objectContaining({
        id: "surface-wire-4",
        materialId: VoxelMaterialId.Iron,
      }),
    ]);
  });
});
