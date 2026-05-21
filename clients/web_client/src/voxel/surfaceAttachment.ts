import type { FMacroCoord, FMicroCoord } from "./core/types";

export type SurfaceAttachmentFace = "x_pos" | "x_neg" | "y_pos" | "y_neg" | "z_pos" | "z_neg";
export type SurfaceAttachmentVisibilityPolicy =
  | "hide_when_neighbor_occupied"
  | "always_visible";

export interface SurfaceAttachment {
  id: string;
  anchorMacro: FMacroCoord;
  anchorMicro: FMicroCoord;
  face: SurfaceAttachmentFace;
  materialId: number;
  faceMask: bigint;
  ownerObjectId: bigint;
  ownerPartId: number;
  visibilityPolicy: SurfaceAttachmentVisibilityPolicy;
}

export type CreateSurfaceAttachmentInput = SurfaceAttachment;

export interface SurfaceAttachmentVisibilityContext {
  neighborOccupied: boolean;
}

export function createSurfaceAttachment(
  input: CreateSurfaceAttachmentInput,
): SurfaceAttachment {
  return {
    id: input.id,
    anchorMacro: { ...input.anchorMacro },
    anchorMicro: { ...input.anchorMicro },
    face: input.face,
    materialId: input.materialId,
    faceMask: BigInt(input.faceMask),
    ownerObjectId: BigInt(input.ownerObjectId),
    ownerPartId: input.ownerPartId,
    visibilityPolicy: input.visibilityPolicy,
  };
}

export function cloneSurfaceAttachment(attachment: SurfaceAttachment): SurfaceAttachment {
  return createSurfaceAttachment(attachment);
}

export function surfaceAttachmentOccupancyMask(_attachment: SurfaceAttachment): bigint {
  return 0n;
}

export function isSurfaceAttachmentVisible(
  attachment: SurfaceAttachment,
  context: SurfaceAttachmentVisibilityContext,
): boolean {
  if (attachment.visibilityPolicy === "always_visible") {
    return true;
  }
  return !context.neighborOccupied;
}

export function adjacentMacroForSurfaceAttachment(attachment: SurfaceAttachment): FMacroCoord {
  const step = surfaceAttachmentFaceStep(attachment.face);
  return {
    x: attachment.anchorMacro.x + step.x,
    y: attachment.anchorMacro.y + step.y,
    z: attachment.anchorMacro.z + step.z,
  };
}

function surfaceAttachmentFaceStep(face: SurfaceAttachmentFace): FMacroCoord {
  switch (face) {
    case "x_pos":
      return { x: 1, y: 0, z: 0 };
    case "x_neg":
      return { x: -1, y: 0, z: 0 };
    case "y_pos":
      return { x: 0, y: 1, z: 0 };
    case "y_neg":
      return { x: 0, y: -1, z: 0 };
    case "z_pos":
      return { x: 0, y: 0, z: 1 };
    case "z_neg":
      return { x: 0, y: 0, z: -1 };
  }
}
