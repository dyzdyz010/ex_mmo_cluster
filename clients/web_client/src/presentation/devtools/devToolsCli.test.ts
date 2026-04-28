import { describe, expect, it, vi } from "vitest";
import { DevToolsCli, type DevToolsDeps } from "./devToolsCli";
import { VoxelConstants } from "../../voxel/core/constants";
import { LocalVoxelWorldAdapter } from "../../voxel/worldAdapter";

describe("DevToolsCli microgrid boundary", () => {
  it("keeps microgrid writes out of the public CLI while allowing cell inspection", () => {
    const cli = new DevToolsCli({
      world: {
        store: {
          getMicroBlockWorld: vi.fn(() => null),
        },
      },
      edit: {
        placeMicroAt: vi.fn(),
        breakMicroAt: vi.fn(),
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("micro_cell", ["0", "1", "2", "1", "2", "3"])).toMatchObject({
      ok: true,
      command: "micro_cell",
      data: {
        macro: { x: 0, y: 1, z: 2 },
        micro: { x: 1, y: 2, z: 3 },
        block: null,
      },
    });
    expect(cli.executeCliCommand("micro_place", ["0", "1", "2", "1", "2", "3"])).toMatchObject({
      ok: false,
      command: "micro_place",
      text: "unknown command: micro_place",
    });
    expect(cli.executeCliCommand("micro_break", ["0", "1", "2", "1", "2", "3"])).toMatchObject({
      ok: false,
      command: "micro_break",
      text: "unknown command: micro_break",
    });
  });

  it("exposes prefab sockets and socket snap preview/commit through the CLI observe surface", () => {
    const world = new LocalVoxelWorldAdapter();
    world.placePrefab("builtin_stairs", { x: 0, y: 0, z: 0 });
    const logger = { emit: vi.fn() };
    const cli = new DevToolsCli({
      logger,
      world,
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("prefab_sockets", ["builtin_stairs"])).toMatchObject({
      ok: true,
      command: "prefab_sockets",
      data: {
        prefabId: "builtin_stairs",
        sockets: expect.arrayContaining([
          expect.objectContaining({ socketId: "stairs_high_pos_x" }),
          expect.objectContaining({ socketId: "stairs_low_neg_x" }),
        ]),
        boundaryFaceMasks: {
          posX: expect.objectContaining({ occupiedSlots: 64 }),
          negX: expect.objectContaining({ occupiedSlots: 8 }),
        },
      },
    });

    expect(
      cli.executeCliCommand("prefab_snap_preview", [
        "builtin_stairs",
        "1",
        "stairs_high_pos_x",
        "stairs_low_neg_x",
      ]),
    ).toMatchObject({
      ok: true,
      command: "prefab_snap_preview",
      data: {
        ok: true,
        anchorMicroCoord: {
          x: VoxelConstants.MicroPerMacro,
          y: VoxelConstants.MicroPerMacro - 1,
          z: 0,
        },
        affectedMacroCount: expect.any(Number),
        incomingOccupiedSlots: expect.any(Number),
        overlapSlots: 0,
      },
    });

    expect(
      cli.executeCliCommand("prefab_place_socket", [
        "builtin_stairs",
        "1",
        "stairs_high_pos_x",
        "stairs_low_neg_x",
      ]),
    ).toMatchObject({
      ok: true,
      command: "prefab_place_socket",
      data: {
        ok: true,
        instanceId: 2,
        preview: expect.objectContaining({
          socketId: "stairs_low_neg_x",
          targetSocketId: "stairs_high_pos_x",
        }),
      },
    });
    expect(logger.emit).toHaveBeenCalledWith(
      "prefab",
      "prefab_snap_previewed",
      expect.objectContaining({
        prefabId: "builtin_stairs",
        instanceId: 1,
        socketId: "stairs_low_neg_x",
        targetSocketId: "stairs_high_pos_x",
      }),
    );
    expect(logger.emit).toHaveBeenCalledWith(
      "prefab",
      "prefab_snap_committed",
      expect.objectContaining({
        prefabId: "builtin_stairs",
        instanceId: 2,
        socketId: "stairs_low_neg_x",
        targetSocketId: "stairs_high_pos_x",
      }),
    );
  });

  it("exposes socket-free prefab boundary snap preview and commit through the CLI observe surface", () => {
    const world = new LocalVoxelWorldAdapter();
    world.placePrefab("builtin_sphere", { x: 0, y: 0, z: 0 });
    const logger = { emit: vi.fn() };
    const cli = new DevToolsCli({
      logger,
      world,
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("prefab_boundary", ["builtin_sphere"])).toMatchObject({
      ok: true,
      command: "prefab_boundary",
      data: {
        prefabId: "builtin_sphere",
        sockets: [],
        boundaryFaceMasks: {
          posX: expect.objectContaining({ occupiedSlots: expect.any(Number) }),
          negX: expect.objectContaining({ occupiedSlots: expect.any(Number) }),
        },
      },
    });

    expect(
      cli.executeCliCommand("prefab_snap_preview", [
        "builtin_sphere",
        "0",
        "0",
        "0",
        "1",
        "0",
        "0",
      ]),
    ).toMatchObject({
      ok: true,
      command: "prefab_snap_preview",
      data: {
        ok: true,
        anchorMicroCoord: expect.objectContaining({
          x: expect.any(Number),
          y: expect.any(Number),
          z: expect.any(Number),
        }),
        affectedMacroCount: expect.any(Number),
        incomingOccupiedSlots: expect.any(Number),
        overlapSlots: 0,
        contactSlots: expect.any(Number),
      },
    });

    expect(
      cli.executeCliCommand("prefab_place_snap", ["builtin_sphere", "0", "0", "0", "1", "0", "0"]),
    ).toMatchObject({
      ok: true,
      command: "prefab_place_snap",
      data: {
        ok: true,
        instanceId: 2,
        preview: expect.objectContaining({
          prefabId: "builtin_sphere",
          contactSlots: expect.any(Number),
        }),
      },
    });
    expect(logger.emit).toHaveBeenCalledWith(
      "prefab",
      "prefab_boundary_snap_previewed",
      expect.objectContaining({
        prefabId: "builtin_sphere",
        instanceId: 0,
        socketId: "",
        targetSocketId: "",
      }),
    );
    expect(logger.emit).toHaveBeenCalledWith(
      "prefab",
      "prefab_boundary_snap_committed",
      expect.objectContaining({
        prefabId: "builtin_sphere",
        instanceId: 2,
        socketId: "",
        targetSocketId: "",
      }),
    );
  });

  it("accepts an optional world-micro anchor for boundary snap preview diagnostics", () => {
    const world = new LocalVoxelWorldAdapter();
    world.placePrefab("builtin_stairs", { x: 20, y: 10, z: 20 });
    const cli = new DevToolsCli({
      logger: { emit: vi.fn() },
      world,
    } as unknown as DevToolsDeps);

    expect(
      cli.executeCliCommand("prefab_snap_preview", [
        "builtin_stairs",
        "20",
        "10",
        "20",
        "0",
        "1",
        "0",
        "rot0",
        String(20 * VoxelConstants.MicroPerMacro + 3),
        "84",
        "164",
      ]),
    ).toMatchObject({
      ok: true,
      command: "prefab_snap_preview",
      data: {
        ok: true,
        anchorMicroCoord: { x: 156, y: 84, z: 160 },
        overlapSlots: 0,
        debug: expect.objectContaining({
          mode: "anchored",
          incomingBoundaryCount: 64,
          targetBoundaryCount: 1,
        }),
      },
    });
  });
});
