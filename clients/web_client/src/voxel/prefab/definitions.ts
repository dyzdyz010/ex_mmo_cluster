import { VoxelConstants } from "../core/constants";
import { EVoxelRotation, type FMacroCoord, type FMicroCoord } from "../core/types";
import { MicroGridSlotCount } from "../microgrid/governance";
import type {
  FPrefabBoundaryFaceMasks,
  FPrefabDefinitionData,
  FPrefabPartDefinition,
  FPrefabSocketDefinition,
} from "../storage/types";
import { VoxelMaterialId } from "../../material/catalog";
import type { LocalPrefab } from "./types";
import { microLinearIndex } from "./math";
import { buildBoundaryFaceMasks, buildBoundarySignature } from "./boundary";

export function buildBuiltinPrefabs(): LocalPrefab[] {
  return [
    buildBuiltinPrefab("builtin_cylinder", makeCylinderOccupancy(), VoxelMaterialId.Stone, [
      "builtin",
      "cylinder",
      "curved",
    ]),
    buildBuiltinPrefab("builtin_sphere", makeSphereOccupancy(), VoxelMaterialId.Ice, [
      "builtin",
      "sphere",
      "curved",
    ]),
    buildBuiltinPrefab("builtin_stairs", makeStairsOccupancy(), VoxelMaterialId.Wood, [
      "builtin",
      "stairs",
    ]),
  ];
}

function buildBuiltinPrefab(
  name: string,
  occupancyWord: bigint,
  materialId: number,
  tags: string[],
): LocalPrefab {
  const partDefinitions: FPrefabPartDefinition[] = [
    {
      partId: "body",
      partTags: tags,
      defaultAffordances: builtinAffordances(tags),
      defaultHealth: 100,
      materialPolicy: "fixed",
    },
  ];
  const microPartIds = partIdsFromOccupancy(occupancyWord, 0);
  const boundsInMacroCells = { x: 1, y: 1, z: 1 };
  const boundaryFaceMasks = buildBoundaryFaceMasks([occupancyWord], boundsInMacroCells);
  const definition: FPrefabDefinitionData = {
    prefabId: name,
    boundsInMacroCells,
    microResolution: VoxelConstants.MicroPerMacro,
    occupancyWords: [occupancyWord],
    materialChannels: [materialId],
    partDefinitions,
    microPartIds,
    allowedRotations: [
      EVoxelRotation.Rot0,
      EVoxelRotation.Rot90,
      EVoxelRotation.Rot180,
      EVoxelRotation.Rot270,
    ],
    boundarySignature: buildBoundarySignature([occupancyWord], boundsInMacroCells),
    boundaryFaceMasks,
    sockets: buildBuiltinSockets(name, boundsInMacroCells, boundaryFaceMasks),
    tags,
  };

  return {
    name,
    boundsMin: { x: 0, y: 0, z: 0 },
    boundsMax: { x: 0, y: 0, z: 0 },
    definition,
    blocks: [],
    cells: [
      { offset: { x: 0, y: 0, z: 0 }, occupancyWord, materialId, stateFlags: 0, microPartIds },
    ],
  };
}

function partIdsFromOccupancy(occupancyWord: bigint, partIndex: number): number[] {
  const ids = new Array(MicroGridSlotCount).fill(-1);
  for (let index = 0; index < MicroGridSlotCount; index += 1) {
    if ((occupancyWord & (1n << BigInt(index))) !== 0n) {
      ids[index] = partIndex;
    }
  }
  return ids;
}

function builtinAffordances(tags: string[]): string[] {
  if (tags.includes("sphere")) {
    return ["break", "freeze", "melt"];
  }
  if (tags.includes("stairs")) {
    return ["break", "climb"];
  }
  return ["break", "move"];
}

function buildBuiltinSockets(
  name: string,
  bounds: FMacroCoord,
  masks: FPrefabBoundaryFaceMasks,
): FPrefabSocketDefinition[] {
  if (name !== "builtin_stairs") {
    return [];
  }

  const mid = Math.floor(VoxelConstants.MicroPerMacro / 2);
  return [
    {
      socketId: "stairs_high_pos_x",
      localMicroCoord: {
        x: bounds.x * VoxelConstants.MicroPerMacro,
        y: VoxelConstants.MicroPerMacro - 1,
        z: mid,
      },
      normal: { x: 1, y: 0, z: 0 },
      tags: ["stairs", "rise", "high"],
      snapClass: "stairs-rise",
      allowedPeerClasses: ["stairs-rise"],
      faceMask: masks.posX,
      priority: 100,
    },
    {
      socketId: "stairs_low_neg_x",
      localMicroCoord: { x: 0, y: 0, z: mid },
      normal: { x: -1, y: 0, z: 0 },
      tags: ["stairs", "rise", "low"],
      snapClass: "stairs-rise",
      allowedPeerClasses: ["stairs-rise"],
      faceMask: masks.negX,
      priority: 100,
    },
  ];
}

export function buildCapturedSockets(
  name: string,
  bounds: FMacroCoord,
  masks: FPrefabBoundaryFaceMasks,
): FPrefabSocketDefinition[] {
  const center = {
    x: Math.floor((bounds.x * VoxelConstants.MicroPerMacro) / 2),
    y: Math.floor((bounds.y * VoxelConstants.MicroPerMacro) / 2),
    z: Math.floor((bounds.z * VoxelConstants.MicroPerMacro) / 2),
  };
  return [
    makeCapturedSocket(
      name,
      "neg_x",
      { x: 0, y: center.y, z: center.z },
      { x: -1, y: 0, z: 0 },
      masks.negX,
    ),
    makeCapturedSocket(
      name,
      "pos_x",
      { x: bounds.x * VoxelConstants.MicroPerMacro, y: center.y, z: center.z },
      { x: 1, y: 0, z: 0 },
      masks.posX,
    ),
    makeCapturedSocket(
      name,
      "neg_y",
      { x: center.x, y: 0, z: center.z },
      { x: 0, y: -1, z: 0 },
      masks.negY,
    ),
    makeCapturedSocket(
      name,
      "pos_y",
      { x: center.x, y: bounds.y * VoxelConstants.MicroPerMacro, z: center.z },
      { x: 0, y: 1, z: 0 },
      masks.posY,
    ),
    makeCapturedSocket(
      name,
      "neg_z",
      { x: center.x, y: center.y, z: 0 },
      { x: 0, y: 0, z: -1 },
      masks.negZ,
    ),
    makeCapturedSocket(
      name,
      "pos_z",
      { x: center.x, y: center.y, z: bounds.z * VoxelConstants.MicroPerMacro },
      { x: 0, y: 0, z: 1 },
      masks.posZ,
    ),
  ].filter((socket) => socket.faceMask !== 0n);
}

function makeCapturedSocket(
  prefabName: string,
  suffix: string,
  localMicroCoord: FMicroCoord,
  normal: FMacroCoord,
  faceMask: bigint,
): FPrefabSocketDefinition {
  return {
    socketId: `${prefabName}_${suffix}`,
    localMicroCoord,
    normal,
    tags: ["captured", "macro_face"],
    snapClass: "macro-face",
    allowedPeerClasses: ["macro-face"],
    faceMask,
    priority: 10,
  };
}

function makeSphereOccupancy(): bigint {
  let mask = 0n;
  const center = VoxelConstants.MicroPerMacro / 2;
  const radius = center - 0.1;
  const radiusSq = radius * radius;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const dx = x + 0.5 - center;
        const dy = y + 0.5 - center;
        const dz = z + 0.5 - center;
        if (dx * dx + dy * dy + dz * dz <= radiusSq) {
          mask |= 1n << BigInt(microLinearIndex({ x, y, z }));
        }
      }
    }
  }
  return mask;
}

function makeCylinderOccupancy(): bigint {
  let mask = 0n;
  const center = VoxelConstants.MicroPerMacro / 2;
  const radius = center - 0.1;
  const radiusSq = radius * radius;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        const dx = x + 0.5 - center;
        const dz = z + 0.5 - center;
        if (dx * dx + dz * dz <= radiusSq) {
          mask |= 1n << BigInt(microLinearIndex({ x, y, z }));
        }
      }
    }
  }
  return mask;
}

function makeStairsOccupancy(): bigint {
  let mask = 0n;
  for (let x = 0; x < VoxelConstants.MicroPerMacro; x += 1) {
    for (let y = 0; y < VoxelConstants.MicroPerMacro; y += 1) {
      for (let z = 0; z < VoxelConstants.MicroPerMacro; z += 1) {
        if (y <= x) {
          mask |= 1n << BigInt(microLinearIndex({ x, y, z }));
        }
      }
    }
  }
  return mask;
}

export function normalizeBoundsMin(a: FMacroCoord, b: FMacroCoord): FMacroCoord {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    z: Math.min(a.z, b.z),
  };
}

export function normalizeBoundsMax(a: FMacroCoord, b: FMacroCoord): FMacroCoord {
  return {
    x: Math.max(a.x, b.x),
    y: Math.max(a.y, b.y),
    z: Math.max(a.z, b.z),
  };
}
