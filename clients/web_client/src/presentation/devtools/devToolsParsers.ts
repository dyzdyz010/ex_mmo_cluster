import { EVoxelRotation, type FMacroCoord, type FMicroCoord } from "../../voxel/core/types";
import { isMicroCoordInBounds } from "../../voxel/microgrid/governance";

export function parseMacroCoord(args: string[]): FMacroCoord | null {
  const [xRaw, yRaw, zRaw] = args;
  const x = Number.parseInt(xRaw ?? "", 10);
  const y = Number.parseInt(yRaw ?? "", 10);
  const z = Number.parseInt(zRaw ?? "", 10);
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(z)) return null;
  return { x, y, z };
}

export function parseMicroTarget(
  args: string[],
): { macro: FMacroCoord; micro: FMicroCoord } | null {
  const macro = parseMacroCoord(args.slice(0, 3));
  const micro = parseMicroCoord(args.slice(3, 6));
  if (!macro || !micro) {
    return null;
  }
  return { macro, micro };
}

export function parseRotation(value: string | undefined): EVoxelRotation | null {
  if (value === undefined) {
    return EVoxelRotation.Rot0;
  }

  switch (value.toLowerCase()) {
    case "0":
    case "rot0":
      return EVoxelRotation.Rot0;
    case "90":
    case "rot90":
      return EVoxelRotation.Rot90;
    case "180":
    case "rot180":
      return EVoxelRotation.Rot180;
    case "270":
    case "rot270":
      return EVoxelRotation.Rot270;
    default:
      return null;
  }
}

export function parseSocketSnapRequest(args: string[]): {
  prefabName: string;
  targetInstanceId: number;
  targetSocketId: string;
  incomingSocketId?: string;
  rotation?: EVoxelRotation;
} | null {
  const prefabName = args[0];
  const targetInstanceId = Number.parseInt(args[1] ?? "", 10);
  const targetSocketId = args[2];
  if (!prefabName || !Number.isFinite(targetInstanceId) || !targetSocketId) {
    return null;
  }

  const fourth = args[3];
  const fifth = args[4];
  let incomingSocketId: string | undefined;
  let rotation = EVoxelRotation.Rot0;
  if (fourth !== undefined) {
    const fourthAsRotation = parseRotation(fourth);
    if (fourthAsRotation === null) {
      incomingSocketId = fourth;
      if (fifth !== undefined) {
        const parsed = parseRotation(fifth);
        if (parsed === null) {
          return null;
        }
        rotation = parsed;
      }
    } else {
      if (fifth !== undefined) {
        return null;
      }
      rotation = fourthAsRotation;
    }
  }

  return {
    prefabName,
    targetInstanceId,
    targetSocketId,
    ...(incomingSocketId ? { incomingSocketId } : {}),
    rotation,
  };
}

export function parseBoundarySnapRequest(args: string[]): {
  prefabName: string;
  hitMacro: FMacroCoord;
  faceNormal: FMacroCoord;
  anchorMicroCoord?: FMicroCoord;
  rotation?: EVoxelRotation;
} | null {
  const prefabName = args[0];
  const hitMacro = parseMacroCoord(args.slice(1, 4));
  const faceNormal = parseMacroCoord(args.slice(4, 7));
  if (!prefabName || !hitMacro || !faceNormal) {
    return null;
  }
  let rotation = EVoxelRotation.Rot0;
  let anchorStart = 7;
  if (args[7] !== undefined) {
    const parsedRotation = parseRotation(args[7]);
    if (parsedRotation !== null) {
      rotation = parsedRotation;
      anchorStart = 8;
    }
  }

  let anchorMicroCoord: FMicroCoord | null = null;
  if (args.length > anchorStart) {
    anchorMicroCoord = parseMacroCoord(args.slice(anchorStart, anchorStart + 3));
    if (!anchorMicroCoord || args.length > anchorStart + 3) {
      return null;
    }
  }

  return {
    prefabName,
    hitMacro,
    faceNormal,
    ...(anchorMicroCoord ? { anchorMicroCoord } : {}),
    rotation,
  };
}

export function worldStorageKey(slot: string): string {
  return `ex_mmo_web_client.world.${slot}`;
}

function parseMicroCoord(args: string[]): FMicroCoord | null {
  const coord = parseMacroCoord(args);
  if (!coord || !isMicroCoordInBounds(coord)) {
    return null;
  }
  return coord;
}
