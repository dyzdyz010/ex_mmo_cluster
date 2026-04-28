import {
  countBits,
  type LocalPrefab,
  type PrefabBoundarySnapPreview,
  type PrefabSocketSnapPreview,
} from "../../voxel/prefab";

export function serializePrefabForCli(prefab: LocalPrefab): Record<string, unknown> {
  return {
    name: prefab.name,
    boundsMin: prefab.boundsMin,
    boundsMax: prefab.boundsMax,
    blockCount: prefab.blocks.length,
    definition: {
      ...prefab.definition,
      occupancyWords: prefab.definition.occupancyWords.map((word) => word.toString()),
      boundaryFaceMasks: serializeBoundaryFaceMasks(prefab),
      sockets: prefab.definition.sockets.map(serializeSocketForCli),
    },
  };
}

export function serializePrefabSocketData(prefab: LocalPrefab): Record<string, unknown> {
  return {
    prefabId: prefab.definition.prefabId,
    boundaryFaceMasks: serializeBoundaryFaceMasks(prefab),
    sockets: prefab.definition.sockets.map(serializeSocketForCli),
  };
}

export function serializeSnapPreview(preview: PrefabSocketSnapPreview): Record<string, unknown> {
  return {
    ...preview,
    cells: serializeRasterCells(preview.cells),
  };
}

export function serializeBoundarySnapPreview(
  preview: PrefabBoundarySnapPreview,
): Record<string, unknown> {
  return {
    ...preview,
    cells: serializeRasterCells(preview.cells),
  };
}

function serializeBoundaryFaceMasks(prefab: LocalPrefab): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(prefab.definition.boundaryFaceMasks).map(([face, mask]) => [
      face,
      {
        mask: mask.toString(),
        occupiedSlots: countBits(mask),
      },
    ]),
  );
}

function serializeSocketForCli(
  socket: LocalPrefab["definition"]["sockets"][number],
): Record<string, unknown> {
  return {
    ...socket,
    faceMask: socket.faceMask?.toString(),
    faceMaskOccupiedSlots: countBits(socket.faceMask ?? 0n),
  };
}

function serializeRasterCells(cells: PrefabSocketSnapPreview["cells"]): Record<string, unknown>[] {
  return cells.map((cell) => ({
    macro: cell.macro,
    microOccupancyMask: cell.microOccupancyMask.toString(),
    occupiedSlots: countBits(cell.microOccupancyMask),
  }));
}
