import { VoxelConstants } from "../core/constants";
import { EVoxelRotation, type FMacroCoord, type FMicroCoord } from "../core/types";
import type { FPrefabInstanceData, FPrefabSocketDefinition } from "../storage/types";
import type { WorldStore } from "../worldStore";
import type {
  LocalPrefab,
  PrefabBoundarySnapPreview,
  PrefabBoundarySnapRequest,
  PrefabSocketSnapPreview,
  PrefabSocketSnapRequest,
} from "./types";
import {
  MICRO_SLOT_BITS,
  MICRO_SLOT_COORDS,
  addMicroCoord,
  coordKey,
  countBits,
  getOrCreateWeakCachedMap,
  localMicroCoordFromWorldMicro,
  macroCoordFromMicro,
  macroToMicroCoord,
  microLinearIndex,
  subtractMicroCoord,
} from "./math";
import {
  countOverlapSlots,
  listPrefabOccupiedLocalPoints,
  rasterizePrefabDetailed,
  type LocalMicroPoint,
} from "./rasterize";

interface WorldBoundaryPoint {
  worldMicro: FMicroCoord;
  localMicro: FMicroCoord;
  hitDistance: number;
}

interface BoundaryCandidate {
  preview: PrefabBoundarySnapPreview;
  hitDistance: number;
  anchorDistance: number;
}

interface AnchorCandidate {
  anchorMicroCoord: FMicroCoord;
  hitDistance: number;
  anchorDistance: number;
}

const boundaryPointCache = new WeakMap<LocalPrefab, Map<string, LocalMicroPoint[]>>();

export function previewBoundarySnap(
  prefabs: Map<string, LocalPrefab>,
  request: PrefabBoundarySnapRequest,
  world: WorldStore,
): PrefabBoundarySnapPreview {
  const incoming = prefabs.get(request.prefabName);
  if (!incoming) {
    return rejectedBoundaryPreview(request, "unknown_prefab");
  }
  if (!isUnitAxisNormal(request.faceNormal)) {
    return rejectedBoundaryPreview(request, "invalid_face_normal", incoming.definition.prefabId);
  }

  const rotation = request.rotation ?? EVoxelRotation.Rot0;
  const incomingBoundary = listPrefabBoundaryPoints(incoming, rotation, request.faceNormal);
  if (incomingBoundary.length === 0) {
    return rejectedBoundaryPreview(request, "empty_prefab", incoming.definition.prefabId);
  }

  const searchRadius = Math.max(0, request.searchRadius ?? VoxelConstants.MicroPerMacro - 1);
  const targetBoundary = listWorldBoundaryPoints(world, request, searchRadius);
  if (targetBoundary.length === 0) {
    return rejectedBoundaryPreview(request, "no_target_boundary", incoming.definition.prefabId);
  }

  const anchorCandidates = new Map<string, AnchorCandidate>();
  const anchorBaseline = macroToMicroCoord({
    x: request.hitMacro.x + request.faceNormal.x,
    y: request.hitMacro.y + request.faceNormal.y,
    z: request.hitMacro.z + request.faceNormal.z,
  });

  for (const target of targetBoundary) {
    for (const incomingPoint of incomingBoundary) {
      if (
        request.hitMicro &&
        tangentDistance(target.localMicro, incomingPoint.localMicro, request.faceNormal) >
          searchRadius
      ) {
        continue;
      }

      const anchorMicroCoord = subtractMicroCoord(
        addMicroCoord(target.worldMicro, request.faceNormal),
        incomingPoint.localMicro,
      );
      const candidate: AnchorCandidate = {
        anchorMicroCoord,
        hitDistance: target.hitDistance,
        anchorDistance: manhattanDistance(anchorMicroCoord, anchorBaseline),
      };
      const key = coordKey(anchorMicroCoord);
      const existing = anchorCandidates.get(key);
      if (!existing || compareAnchorCandidates(candidate, existing) < 0) {
        anchorCandidates.set(key, candidate);
      }
    }
  }

  const candidates: BoundaryCandidate[] = [];
  for (const anchor of anchorCandidates.values()) {
    const rasterized = rasterizePrefabDetailed(incoming, rotation, anchor.anchorMicroCoord);
    const { cells, incomingOccupiedSlots } = rasterized;
    if (incomingOccupiedSlots === 0) {
      continue;
    }

    const overlapSlots = countOverlapSlots(cells, world);
    const contactSlots = countBoundaryContactSlots(
      rasterized.occupiedWorldMicro,
      world,
      request.faceNormal,
    );
    candidates.push({
      preview: {
        ok: overlapSlots === 0 && contactSlots > 0,
        prefabId: incoming.definition.prefabId,
        hitMacro: { ...request.hitMacro },
        faceNormal: { ...request.faceNormal },
        anchorMicroCoord: anchor.anchorMicroCoord,
        affectedMacroCount: cells.length,
        incomingOccupiedSlots,
        overlapSlots,
        contactSlots,
        cells,
        ...(overlapSlots > 0 ? { rejectReason: "micro_overlap" } : {}),
      },
      hitDistance: anchor.hitDistance,
      anchorDistance: anchor.anchorDistance,
    });
  }

  const sorted = [...candidates.values()].sort(compareBoundaryCandidates);
  const valid = sorted.find(
    (candidate) =>
      candidate.preview.ok &&
      candidate.preview.overlapSlots === 0 &&
      candidate.preview.contactSlots > 0,
  );
  if (valid) {
    return valid.preview;
  }

  const overlapping = sorted.find(
    (candidate) => candidate.preview.overlapSlots > 0 && candidate.preview.contactSlots > 0,
  );
  if (overlapping) {
    return {
      ...overlapping.preview,
      ok: false,
      rejectReason: "micro_overlap",
    };
  }

  return rejectedBoundaryPreview(request, "no_contact", incoming.definition.prefabId);
}

function rejectedBoundaryPreview(
  request: PrefabBoundarySnapRequest,
  rejectReason: string,
  prefabId: string = request.prefabName,
): PrefabBoundarySnapPreview {
  return {
    ok: false,
    prefabId,
    hitMacro: { ...request.hitMacro },
    faceNormal: { ...request.faceNormal },
    anchorMicroCoord: null,
    affectedMacroCount: 0,
    incomingOccupiedSlots: 0,
    overlapSlots: 0,
    contactSlots: 0,
    cells: [],
    rejectReason,
  };
}

function listPrefabBoundaryPoints(
  prefab: LocalPrefab,
  rotation: EVoxelRotation,
  faceNormal: FMacroCoord,
): LocalMicroPoint[] {
  const cacheKey = `${rotation}:${coordKey(faceNormal)}`;
  const cachedByFace = getOrCreateWeakCachedMap(boundaryPointCache, prefab);
  const cached = cachedByFace.get(cacheKey);
  if (cached) {
    return cached;
  }

  const occupied = listPrefabOccupiedLocalPoints(prefab, rotation);
  const occupiedKeys = new Set(occupied.map((point) => coordKey(point.localMicro)));
  const points = occupied
    .filter((point) => {
      const neighbor = subtractMicroCoord(point.localMicro, faceNormal);
      return !occupiedKeys.has(coordKey(neighbor));
    })
    .sort((a, b) => coordKey(a.localMicro).localeCompare(coordKey(b.localMicro)));
  cachedByFace.set(cacheKey, points);
  return points;
}

function listWorldBoundaryPoints(
  world: WorldStore,
  request: PrefabBoundarySnapRequest,
  searchRadius: number,
): WorldBoundaryPoint[] {
  const mask = world.getMicroOccupancyMaskWorld(request.hitMacro);
  if (mask === 0n) {
    return [];
  }

  const points: WorldBoundaryPoint[] = [];
  const macroOrigin = macroToMicroCoord(request.hitMacro);
  for (const [index, localMicro] of MICRO_SLOT_COORDS.entries()) {
    if ((mask & (MICRO_SLOT_BITS[index] ?? 0n)) === 0n) {
      continue;
    }
    if (request.hitMicro && chebyshevDistance(localMicro, request.hitMicro) > searchRadius) {
      continue;
    }

    const worldMicro = addMicroCoord(macroOrigin, localMicro);
    if (isWorldMicroOccupied(world, addMicroCoord(worldMicro, request.faceNormal))) {
      continue;
    }

    points.push({
      worldMicro,
      localMicro,
      hitDistance: request.hitMicro ? chebyshevDistance(localMicro, request.hitMicro) : 0,
    });
  }

  return points.sort(
    (a, b) =>
      a.hitDistance - b.hitDistance || coordKey(a.localMicro).localeCompare(coordKey(b.localMicro)),
  );
}

function countBoundaryContactSlots(
  occupiedWorldMicro: readonly FMicroCoord[],
  world: WorldStore,
  faceNormal: FMacroCoord,
): number {
  let count = 0;
  for (const worldMicro of occupiedWorldMicro) {
    if (isWorldMicroOccupied(world, subtractMicroCoord(worldMicro, faceNormal))) {
      count += 1;
    }
  }
  return count;
}

function isWorldMicroOccupied(world: WorldStore, worldMicro: FMicroCoord): boolean {
  const macro = macroCoordFromMicro(worldMicro);
  const micro = localMicroCoordFromWorldMicro(worldMicro);
  return isMaskMicroOccupied(world.getMicroOccupancyMaskWorld(macro), micro);
}

function isMaskMicroOccupied(mask: bigint, micro: FMicroCoord): boolean {
  return (mask & (1n << BigInt(microLinearIndex(micro)))) !== 0n;
}

function isUnitAxisNormal(normal: FMacroCoord): boolean {
  const magnitude = Math.abs(normal.x) + Math.abs(normal.y) + Math.abs(normal.z);
  return (
    magnitude === 1 &&
    Number.isInteger(normal.x) &&
    Number.isInteger(normal.y) &&
    Number.isInteger(normal.z)
  );
}

function compareBoundaryCandidates(a: BoundaryCandidate, b: BoundaryCandidate): number {
  return (
    b.preview.contactSlots - a.preview.contactSlots ||
    a.preview.overlapSlots - b.preview.overlapSlots ||
    a.hitDistance - b.hitDistance ||
    a.anchorDistance - b.anchorDistance ||
    coordKey(a.preview.anchorMicroCoord ?? { x: 0, y: 0, z: 0 }).localeCompare(
      coordKey(b.preview.anchorMicroCoord ?? { x: 0, y: 0, z: 0 }),
    )
  );
}

function compareAnchorCandidates(a: AnchorCandidate, b: AnchorCandidate): number {
  return (
    a.hitDistance - b.hitDistance ||
    a.anchorDistance - b.anchorDistance ||
    coordKey(a.anchorMicroCoord).localeCompare(coordKey(b.anchorMicroCoord))
  );
}

function tangentDistance(a: FMicroCoord, b: FMicroCoord, faceNormal: FMacroCoord): number {
  const dx = faceNormal.x === 0 ? Math.abs(a.x - b.x) : 0;
  const dy = faceNormal.y === 0 ? Math.abs(a.y - b.y) : 0;
  const dz = faceNormal.z === 0 ? Math.abs(a.z - b.z) : 0;
  return Math.max(dx, dy, dz);
}

function chebyshevDistance(a: FMicroCoord, b: FMicroCoord): number {
  return Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y), Math.abs(a.z - b.z));
}

function manhattanDistance(a: FMicroCoord, b: FMicroCoord): number {
  return Math.abs(a.x - b.x) + Math.abs(a.y - b.y) + Math.abs(a.z - b.z);
}

export function previewSocketSnap(
  prefabs: Map<string, LocalPrefab>,
  request: PrefabSocketSnapRequest,
  world: WorldStore,
): PrefabSocketSnapPreview {
  const incoming = prefabs.get(request.prefabName);
  if (!incoming) {
    return rejectedPreview(request, "unknown_prefab");
  }

  const targetInstance = world.findPrefabInstance(request.targetInstanceId);
  if (!targetInstance) {
    return rejectedPreview(request, "unknown_target_instance", incoming.definition.prefabId);
  }

  const targetPrefab = prefabs.get(targetInstance.prefabId);
  if (!targetPrefab) {
    return rejectedPreview(request, "unknown_target_prefab", incoming.definition.prefabId);
  }

  const targetSocket = targetPrefab.definition.sockets.find(
    (socket) => socket.socketId === request.targetSocketId,
  );
  if (!targetSocket) {
    return rejectedPreview(request, "unknown_target_socket", incoming.definition.prefabId);
  }

  const target = transformSocket(
    targetSocket,
    targetPrefab.definition.boundsInMacroCells,
    targetInstance.rotation,
  );
  const rotation = request.rotation ?? EVoxelRotation.Rot0;
  const candidates = incoming.definition.sockets
    .filter((socket) => !request.incomingSocketId || socket.socketId === request.incomingSocketId)
    .map((socket) => transformSocket(socket, incoming.definition.boundsInMacroCells, rotation))
    .filter((socket) => socketsCompatible(target, socket))
    .filter((socket) => normalsOppose(target.normal, socket.normal))
    .map((socket) =>
      buildPreviewCandidate(incoming, targetInstance, target, socket, rotation, world),
    )
    .filter((preview) => preview.contactSlots > 0)
    .sort(
      (a, b) =>
        b.contactSlots - a.contactSlots ||
        (b.socketId ? getSocketPriority(incoming, b.socketId) : 0) -
          (a.socketId ? getSocketPriority(incoming, a.socketId) : 0) ||
        (a.socketId ?? "").localeCompare(b.socketId ?? ""),
    );

  const selected = candidates[0];
  if (!selected) {
    return rejectedPreview(request, "no_compatible_socket", incoming.definition.prefabId);
  }

  if (selected.overlapSlots > 0) {
    return { ...selected, ok: false, rejectReason: "micro_overlap" };
  }

  return selected;
}

function buildPreviewCandidate(
  incoming: LocalPrefab,
  targetInstance: FPrefabInstanceData,
  targetSocket: FPrefabSocketDefinition,
  incomingSocket: FPrefabSocketDefinition,
  rotation: EVoxelRotation,
  world: WorldStore,
): PrefabSocketSnapPreview {
  const targetWorldMicro = addMicroCoord(
    targetInstance.anchorMicroCoord,
    targetSocket.localMicroCoord,
  );
  const anchorMicroCoord = subtractMicroCoord(targetWorldMicro, incomingSocket.localMicroCoord);
  const rasterized = rasterizePrefabDetailed(incoming, rotation, anchorMicroCoord);
  const cells = rasterized.cells;
  const overlapSlots = countOverlapSlots(cells, world);
  return {
    ok: overlapSlots === 0,
    prefabId: incoming.definition.prefabId,
    targetInstanceId: targetInstance.instanceId,
    targetSocketId: targetSocket.socketId,
    socketId: incomingSocket.socketId,
    anchorMicroCoord,
    affectedMacroCount: cells.length,
    incomingOccupiedSlots: rasterized.incomingOccupiedSlots,
    overlapSlots,
    contactSlots: countSocketContactSlots(targetSocket, incomingSocket),
    cells,
    ...(overlapSlots > 0 ? { rejectReason: "micro_overlap" } : {}),
  };
}

function rejectedPreview(
  request: PrefabSocketSnapRequest,
  rejectReason: string,
  prefabId: string = request.prefabName,
): PrefabSocketSnapPreview {
  return {
    ok: false,
    prefabId,
    targetInstanceId: request.targetInstanceId,
    targetSocketId: request.targetSocketId,
    socketId: request.incomingSocketId ?? null,
    anchorMicroCoord: null,
    affectedMacroCount: 0,
    incomingOccupiedSlots: 0,
    overlapSlots: 0,
    contactSlots: 0,
    cells: [],
    rejectReason,
  };
}

export function transformSocket(
  socket: FPrefabSocketDefinition,
  bounds: FMacroCoord,
  rotation: EVoxelRotation,
): FPrefabSocketDefinition {
  return {
    ...socket,
    localMicroCoord: rotateLocalMicroCoord(socket.localMicroCoord, bounds, rotation),
    normal: rotateNormal(socket.normal, rotation),
  };
}

function rotateLocalMicroCoord(
  coord: FMicroCoord,
  bounds: FMacroCoord,
  rotation: EVoxelRotation,
): FMicroCoord {
  const maxX = bounds.x * VoxelConstants.MicroPerMacro;
  const maxZ = bounds.z * VoxelConstants.MicroPerMacro;
  switch (rotation) {
    case EVoxelRotation.Rot90:
      return { x: maxZ - coord.z, y: coord.y, z: coord.x };
    case EVoxelRotation.Rot180:
      return { x: maxX - coord.x, y: coord.y, z: maxZ - coord.z };
    case EVoxelRotation.Rot270:
      return { x: coord.z, y: coord.y, z: maxX - coord.x };
    case EVoxelRotation.Rot0:
    default:
      return { ...coord };
  }
}

function rotateNormal(normal: FMacroCoord, rotation: EVoxelRotation): FMacroCoord {
  switch (rotation) {
    case EVoxelRotation.Rot90:
      return { x: -normal.z, y: normal.y, z: normal.x };
    case EVoxelRotation.Rot180:
      return { x: -normal.x, y: normal.y, z: -normal.z };
    case EVoxelRotation.Rot270:
      return { x: normal.z, y: normal.y, z: -normal.x };
    case EVoxelRotation.Rot0:
    default:
      return { ...normal };
  }
}

function socketsCompatible(
  target: FPrefabSocketDefinition,
  incoming: FPrefabSocketDefinition,
): boolean {
  return (
    target.allowedPeerClasses.includes(incoming.snapClass) &&
    incoming.allowedPeerClasses.includes(target.snapClass)
  );
}

function normalsOppose(a: FMacroCoord, b: FMacroCoord): boolean {
  return a.x + b.x === 0 && a.y + b.y === 0 && a.z + b.z === 0;
}

function countSocketContactSlots(
  target: FPrefabSocketDefinition,
  incoming: FPrefabSocketDefinition,
): number {
  return countBits((target.faceMask ?? 0n) & (incoming.faceMask ?? 0n));
}

function getSocketPriority(prefab: LocalPrefab, socketId: string): number {
  return prefab.definition.sockets.find((socket) => socket.socketId === socketId)?.priority ?? 0;
}
