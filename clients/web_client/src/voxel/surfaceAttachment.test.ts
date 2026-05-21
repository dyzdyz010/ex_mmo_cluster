import { describe, expect, it } from "vitest";
import {
  createSurfaceAttachment,
  isSurfaceAttachmentVisible,
  surfaceAttachmentOccupancyMask,
} from "./surfaceAttachment";

describe("surface attachments", () => {
  it("keeps face-only prefab attachments out of voxel occupancy", () => {
    const attachment = createSurfaceAttachment({
      id: "wire-face-1",
      anchorMacro: { x: 4, y: 1, z: 4 },
      anchorMicro: { x: 32, y: 8, z: 32 },
      face: "x_pos",
      materialId: 5,
      faceMask: 0b1111n,
      ownerObjectId: 44n,
      ownerPartId: 1,
      visibilityPolicy: "hide_when_neighbor_occupied",
    });

    expect(surfaceAttachmentOccupancyMask(attachment)).toBe(0n);
  });

  it("hides a face-only attachment when a neighboring block covers that face without deleting truth", () => {
    const attachment = createSurfaceAttachment({
      id: "wire-face-2",
      anchorMacro: { x: 4, y: 1, z: 4 },
      anchorMicro: { x: 32, y: 8, z: 32 },
      face: "x_pos",
      materialId: 5,
      faceMask: 0b1111n,
      ownerObjectId: 45n,
      ownerPartId: 1,
      visibilityPolicy: "hide_when_neighbor_occupied",
    });

    expect(isSurfaceAttachmentVisible(attachment, { neighborOccupied: false })).toBe(true);
    expect(isSurfaceAttachmentVisible(attachment, { neighborOccupied: true })).toBe(false);
    expect(attachment.ownerObjectId).toBe(45n);
  });

  it("keeps always-visible attachments renderable even when a neighboring block covers the face", () => {
    const attachment = createSurfaceAttachment({
      id: "wire-face-3",
      anchorMacro: { x: 4, y: 1, z: 4 },
      anchorMicro: { x: 32, y: 8, z: 32 },
      face: "x_pos",
      materialId: 5,
      faceMask: 0b1111n,
      ownerObjectId: 46n,
      ownerPartId: 2,
      visibilityPolicy: "always_visible",
    });

    expect(isSurfaceAttachmentVisible(attachment, { neighborOccupied: true })).toBe(true);
  });
});
