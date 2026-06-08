import { describe, expect, it, vi } from "vitest";
import { DevToolsCli, type DevToolsDeps } from "./devToolsCli";
import { VoxelConstants } from "../../voxel/core/constants";
import { LocalVoxelWorldAdapter } from "../../voxel/worldAdapter";

describe("DevToolsCli microgrid boundary", () => {
  it("allows long frame traces for 60-second movement displacement checks", () => {
    const startFrameTrace = vi.fn();
    const cli = new DevToolsCli({
      localPlayer: {
        startFrameTrace,
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("frame_trace_start", ["4000"])).toMatchObject({
      ok: true,
      data: { frames: 4000 },
    });
    expect(startFrameTrace).toHaveBeenLastCalledWith(4000);

    expect(cli.executeCliCommand("frame_trace_start", ["9000"])).toMatchObject({
      ok: true,
      data: { frames: 5000 },
    });
    expect(startFrameTrace).toHaveBeenLastCalledWith(5000);
  });

  it("routes chat commands through the server transport without client partition authority", () => {
    const sendChat = vi.fn(() => 77);
    const cli = new DevToolsCli({
      transport: {
        sendChat,
        debugSnapshot: vi.fn(() => ({ chat: { sentChatMessageCount: 1 } })),
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("chat", ["region", "hello", "there"])).toMatchObject({
      ok: true,
      command: "chat",
      text: "chat region sent request=77",
      data: {
        requestId: 77,
        scope: "region",
        textLength: 11,
      },
    });
    expect(sendChat).toHaveBeenCalledWith("region", "hello there");

    expect(cli.executeCliCommand("chat", ["shard-1", "hello"])).toMatchObject({
      ok: false,
      command: "chat",
      text: "usage: chat <world|region|local> <text...>",
    });
  });

  it("drives movement through the CLI virtual movement vector", () => {
    const setVirtualMovement = vi.fn(() => ({ x: 0.6, y: 0.8 }));
    const cli = new DevToolsCli({
      localPlayer: {
        setVirtualMovement,
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("move", ["3", "4"])).toMatchObject({
      ok: true,
      command: "move",
      text: "move strafe=0.600 forward=0.800",
      data: {
        strafe: 0.6,
        forward: 0.8,
      },
    });
    expect(setVirtualMovement).toHaveBeenCalledWith({ x: 3, y: 4 });

    expect(cli.executeCliCommand("move", ["bad", "1"])).toMatchObject({
      ok: false,
      command: "move",
      text: "usage: move <strafe:-1..1> <forward:-1..1>",
    });
  });

  it("reports rejected chat sends as failed commands so the HUD keeps the draft", () => {
    const sendChat = vi.fn(() => null);
    const cli = new DevToolsCli({
      transport: {
        sendChat,
        debugSnapshot: vi.fn(() => ({ chat: { blockedSendCount: 1 } })),
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("chat", ["local", "still", "typing"])).toMatchObject({
      ok: false,
      command: "chat",
      text: "chat local rejected",
      data: {
        requestId: null,
        scope: "local",
        textLength: 12,
      },
    });
    expect(sendChat).toHaveBeenCalledWith("local", "still typing");
  });

  it("exposes scene region overlay diagnostics and visibility control", () => {
    const setSceneRegionOverlayVisible = vi.fn();
    const cli = new DevToolsCli({
      render: {
        getSceneRegionOverlaySnapshot: vi.fn(() => ({
          visible: true,
          boundary: { chunkX: 1, worldX: 1600 },
          regions: [
            { label: "scene1", ownerSceneInstanceRef: 1 },
            { label: "scene2", ownerSceneInstanceRef: 2 },
          ],
        })),
        setSceneRegionOverlayVisible,
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("scene_regions", [])).toMatchObject({
      ok: true,
      command: "scene_regions",
      text: expect.stringContaining("scene1"),
      data: expect.objectContaining({
        visible: true,
        boundary: expect.objectContaining({ chunkX: 1 }),
      }),
    });

    expect(cli.executeCliCommand("scene_regions", ["off"])).toMatchObject({
      ok: true,
      command: "scene_regions",
    });
    expect(setSceneRegionOverlayVisible).toHaveBeenCalledWith(false);

    expect(cli.executeCliCommand("scene_regions", ["on"])).toMatchObject({
      ok: true,
      command: "scene_regions",
    });
    expect(setSceneRegionOverlayVisible).toHaveBeenCalledWith(true);
  });

  it("exposes field overlay diagnostics and visibility control", () => {
    const setFieldDebugOverlayVisible = vi.fn();
    const cli = new DevToolsCli({
      render: {
        getFieldDebugOverlaySnapshot: vi.fn(() => ({
          visible: true,
          regionCount: 2,
          regions: [
            {
              regionId: 7,
              chunkCoord: { cx: 0, cy: 0, cz: 0 },
              temperatureCells: 5,
              electricCells: 0,
              currentCells: 11,
              currentMicroCells: 11,
              currentMicroGroups: 3,
              electricMicroCells: 7,
              electricMicroGroups: 2,
              smokeParticles: 12,
              maxTemperatureCelsius: 800,
              maxAbsTemperatureDeltaCelsius: 780,
              averageAbsTemperatureDeltaCelsius: 265.678,
            },
          ],
        })),
        setFieldDebugOverlayVisible,
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("field_overlay", [])).toMatchObject({
      ok: true,
      command: "field_overlay",
      text: expect.stringContaining("visible"),
      data: expect.objectContaining({ visible: true, regionCount: 2 }),
    });
    expect(cli.executeCliCommand("field_overlay", [])).toMatchObject({
      text: expect.stringContaining("heat=maxT=800.0C maxDelta=780.0C avgDelta=265.7C"),
    });
    expect(cli.executeCliCommand("field_overlay", [])).toMatchObject({
      text: expect.stringContaining("smoke=12"),
    });
    expect(cli.executeCliCommand("field_overlay", [])).toMatchObject({
      text: expect.stringContaining("micro=temp:0/0 electric:7/2 current:11/3"),
    });

    expect(cli.executeCliCommand("field_overlay", ["off"])).toMatchObject({
      ok: true,
      command: "field_overlay",
    });
    expect(setFieldDebugOverlayVisible).toHaveBeenCalledWith(false);

    expect(cli.executeCliCommand("field_overlay", ["on"])).toMatchObject({
      ok: true,
      command: "field_overlay",
    });
    expect(setFieldDebugOverlayVisible).toHaveBeenCalledWith(true);
  });

  it("exposes target overlay projection diagnostics", () => {
    const cli = new DevToolsCli({
      render: {
        getTargetOverlaySnapshot: vi.fn(() => ({
          selection: null,
          highlight: {
            visible: true,
            kind: "prefab",
            position: { x: 0, y: 0, z: 0 },
            faceNormal: { x: 1, y: 0, z: 0 },
            occupiedMacro: { x: 1, y: 2, z: 3 },
            occupiedMicro: {
              macro: { x: 1, y: 2, z: 3 },
              micro: { x: 2, y: 3, z: 4 },
            },
          },
          projection: {
            granularity: "prefab",
            key: "prefab:7",
            label: "prefab 7",
            macro: { x: 1, y: 2, z: 3 },
            selectedMicro: { x: 2, y: 3, z: 4 },
            prefabInstanceId: 7,
            cellCount: 1,
            occupiedSlots: 32,
            coveredMacroMin: { x: 1, y: 2, z: 3 },
            coveredMacroMax: { x: 1, y: 2, z: 3 },
          },
          fallbackEntityTarget: {
            entityId: -1,
            macroCoord: { x: 4, y: 5, z: 6 },
            renderedPosition: { x: 450, y: 550, z: 650 },
          },
        })),
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("target_probe", [])).toMatchObject({
      ok: true,
      command: "target_probe",
      text: expect.stringContaining("action_entity#-1 macro=4,5,6"),
      data: expect.objectContaining({
        projection: expect.objectContaining({ granularity: "prefab", occupiedSlots: 32 }),
      }),
    });
  });

  it("reports the current entity target through target_probe", () => {
    const cli = new DevToolsCli({
      render: {
        getTargetOverlaySnapshot: vi.fn(() => ({
          selection: null,
          highlight: { visible: false, kind: "none" },
          projection: null,
          entityTarget: {
            entityId: 42,
            macroCoord: { x: 2, y: 3, z: 4 },
            renderedPosition: { x: 250, y: 350, z: 450 },
          },
          fallbackEntityTarget: null,
        })),
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("target_probe", [])).toMatchObject({
      ok: true,
      command: "target_probe",
      text: "target entity#42 macro=2,3,4",
      data: expect.objectContaining({
        entityTarget: expect.objectContaining({ entityId: 42 }),
      }),
    });
  });

  it("inspects micro cells via micro_cell and routes micro_place/micro_break to the edit controller", () => {
    const placeMicroAt = vi.fn(() => true);
    const breakMicroAt = vi.fn(() => true);
    const cli = new DevToolsCli({
      world: {
        store: {
          getMicroBlockWorld: vi.fn(() => null),
        },
      },
      edit: {
        placeMicroAt,
        breakMicroAt,
        getSelectedMaterialId: vi.fn(() => 5),
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

    const placeResult = cli.executeCliCommand("micro_place", ["0", "1", "2", "1", "2", "3"]);
    expect(placeResult.ok).toBe(true);
    expect(placeResult.command).toBe("micro_place");
    expect(placeMicroAt).toHaveBeenCalledWith({ x: 0, y: 1, z: 2 }, { x: 1, y: 2, z: 3 }, 5, "cli");

    const breakResult = cli.executeCliCommand("micro_break", ["0", "1", "2", "1", "2", "3"]);
    expect(breakResult.ok).toBe(true);
    expect(breakResult.command).toBe("micro_break");
    expect(breakMicroAt).toHaveBeenCalledWith({ x: 0, y: 1, z: 2 }, { x: 1, y: 2, z: 3 }, "cli");
  });

  it("flushes server voxel messages before reading cells from the CLI", () => {
    let flushed = false;
    const flushServerMessagesForCli = vi.fn(() => {
      flushed = true;
    });
    const cli = new DevToolsCli({
      world: {
        flushServerMessagesForCli,
        store: {
          getNormalBlockWorld: vi.fn(() => (flushed ? { materialId: 2 } : null)),
          getEnvironmentSummaryWorld: vi.fn(() => null),
        },
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("cell", ["0", "1", "0"])).toMatchObject({
      ok: true,
      command: "cell",
      data: {
        block: { materialId: 2 },
      },
    });
    expect(flushServerMessagesForCli).toHaveBeenCalledTimes(1);
  });

  it("routes voxel_temp to the edit controller with macro coordinates and target temperature", () => {
    const setTemperatureAt = vi.fn(() => true);
    const cli = new DevToolsCli({
      edit: { setTemperatureAt },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("voxel_temp", ["3", "4", "5", "-20", "120"])).toMatchObject({
      ok: true,
      command: "voxel_temp",
      text: "temperature request sent for (3,4,5) to -20C",
    });

    expect(setTemperatureAt).toHaveBeenCalledWith({ x: 3, y: 4, z: 5 }, -20, "cli", 120);
  });

  it("preserves the edit controller receiver when routing voxel_temp", () => {
    const edit = {
      calls: [] as unknown[],
      setTemperatureAt(
        coord: unknown,
        targetTemperatureCelsius: number,
        source: string,
        maxTicks?: number,
      ) {
        this.calls.push({ coord, targetTemperatureCelsius, source, maxTicks });
        return true;
      },
    };
    const cli = new DevToolsCli({
      edit,
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("voxel_temp", ["3", "4", "5", "800", "120"])).toMatchObject({
      ok: true,
      command: "voxel_temp",
    });

    expect(edit.calls).toEqual([
      {
        coord: { x: 3, y: 4, z: 5 },
        targetTemperatureCelsius: 800,
        source: "cli",
        maxTicks: 120,
      },
    ]);
  });

  it("keeps voxel_heat and voxel_cool as temperature aliases", () => {
    const setTemperatureAt = vi.fn(() => true);
    const setTemperatureAtSelection = vi.fn(() => true);
    const cli = new DevToolsCli({
      edit: { setTemperatureAt, setTemperatureAtSelection },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("voxel_heat", ["3", "4", "5", "800", "120"])).toMatchObject({
      ok: true,
      command: "voxel_heat",
      text: "heat request sent for (3,4,5) to 800C",
    });
    expect(cli.executeCliCommand("voxel_cool", ["3", "4", "5", "0", "60"])).toMatchObject({
      ok: true,
      command: "voxel_cool",
      text: "cool request sent for (3,4,5) to 0C",
    });
    expect(cli.executeCliCommand("voxel_cool", [])).toMatchObject({
      ok: true,
      command: "voxel_cool",
      text: "cool request sent for selected voxel to 0C",
    });

    expect(setTemperatureAt).toHaveBeenNthCalledWith(1, { x: 3, y: 4, z: 5 }, 800, "cli", 120);
    expect(setTemperatureAt).toHaveBeenNthCalledWith(2, { x: 3, y: 4, z: 5 }, 0, "cli", 60);
    expect(setTemperatureAtSelection).toHaveBeenCalledWith("cli", 0, 600);
  });

  it("routes voxel_conduct to the edit controller with source, target, potential, max ticks, and power source", () => {
    const conductBetween = vi.fn(() => true);
    const cli = new DevToolsCli({
      edit: { conductBetween },
    } as unknown as DevToolsDeps);

    expect(
      cli.executeCliCommand("voxel_conduct", [
        "0",
        "1",
        "0",
        "3",
        "1",
        "0",
        "120",
        "90",
        "ac",
        "240",
        "12.5",
        "60",
        "6.25",
        "5000",
      ]),
    ).toMatchObject({
      ok: true,
      command: "voxel_conduct",
      text: "conduction request submitted from (0,1,0) to (3,1,0) at 120V; waiting for server acceptance",
    });

    expect(conductBetween).toHaveBeenCalledWith(
      { x: 0, y: 1, z: 0 },
      { x: 3, y: 1, z: 0 },
      120,
      "cli",
      90,
      {
        outputMode: "ac",
        voltage: 240,
        currentLimitAmps: 12.5,
        frequencyHz: 60,
        loadCurrentAmps: 6.25,
        energyBudgetJoules: 5000,
      },
    );
  });

  it("routes voxel_discharge through the same conduction port with dielectric-breakdown mode", () => {
    const conductBetween = vi.fn(() => true);
    const cli = new DevToolsCli({
      edit: { conductBetween },
    } as unknown as DevToolsDeps);

    expect(
      cli.executeCliCommand("voxel_discharge", ["0", "1", "0", "3", "1", "0", "120", "90"]),
    ).toMatchObject({
      ok: true,
      command: "voxel_discharge",
      text: "discharge request submitted from (0,1,0) to (3,1,0) at 120V; waiting for server acceptance",
    });

    expect(conductBetween).toHaveBeenCalledWith(
      { x: 0, y: 1, z: 0 },
      { x: 3, y: 1, z: 0 },
      120,
      "cli",
      90,
      { conductionMode: "discharge" },
    );
  });

  it("exposes a manual auto-circuit refresh command for browser verification", () => {
    const requestVoxelAutoCircuit = vi.fn(() => true);
    const cli = new DevToolsCli({
      world: {
        requestVoxelAutoCircuit,
        debugSnapshot: vi.fn(() => ({ mode: "server-authoritative" })),
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("voxel_auto_circuit", ["4", "12", "12", "90"])).toMatchObject({
      ok: true,
      command: "voxel_auto_circuit",
      text: "auto circuit request submitted for (4,12,12)",
      data: expect.objectContaining({
        coord: { x: 4, y: 12, z: 12 },
        maxTicks: 90,
      }),
    });
    expect(requestVoxelAutoCircuit).toHaveBeenCalledWith({ x: 4, y: 12, z: 12 }, 90);

    expect(cli.executeCliCommand("voxel_auto_circuit", ["4", "12"])).toMatchObject({
      ok: false,
      command: "voxel_auto_circuit",
      text: "usage: voxel_auto_circuit <x> <y> <z> [max_ticks]",
    });
  });

  it("routes voxel_combustion to a read-only world probe", () => {
    const requestVoxelCombustionProbe = vi.fn(() => true);
    const cli = new DevToolsCli({
      world: {
        requestVoxelCombustionProbe,
        debugSnapshot: vi.fn(() => ({
          mode: "server-authoritative",
          lastCombustionProbe: { stage: "burning" },
        })),
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("voxel_combustion", ["4", "12", "12"])).toMatchObject({
      ok: true,
      command: "voxel_combustion",
      text: "combustion probe submitted for (4,12,12)",
      data: expect.objectContaining({
        coord: { x: 4, y: 12, z: 12 },
        voxel: expect.objectContaining({
          lastCombustionProbe: { stage: "burning" },
        }),
      }),
    });
    expect(requestVoxelCombustionProbe).toHaveBeenCalledWith({ x: 4, y: 12, z: 12 });

    expect(cli.executeCliCommand("voxel_combustion", ["4", "12"])).toMatchObject({
      ok: false,
      command: "voxel_combustion",
      text: "usage: voxel_combustion <x> <y> <z>",
    });
  });

  it("routes voxel_phase to a read-only world phase-change probe", () => {
    const requestVoxelPhaseChangeProbe = vi.fn(() => true);
    const cli = new DevToolsCli({
      world: {
        requestVoxelPhaseChangeProbe,
        debugSnapshot: vi.fn(() => ({
          mode: "server-authoritative",
          lastPhaseChangeProbe: { phaseState: "frozen" },
        })),
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("voxel_phase", ["4", "12", "12"])).toMatchObject({
      ok: true,
      command: "voxel_phase",
      text: "phase change probe submitted for (4,12,12)",
      data: expect.objectContaining({
        coord: { x: 4, y: 12, z: 12 },
        voxel: expect.objectContaining({
          lastPhaseChangeProbe: { phaseState: "frozen" },
        }),
      }),
    });
    expect(requestVoxelPhaseChangeProbe).toHaveBeenCalledWith({ x: 4, y: 12, z: 12 });

    expect(cli.executeCliCommand("voxel_phase", ["4", "12"])).toMatchObject({
      ok: false,
      command: "voxel_phase",
      text: "usage: voxel_phase <x> <y> <z>",
    });
  });

  it("routes voxel_object to a read-only object physical-state probe", () => {
    const requestVoxelObjectProbe = vi.fn(() => true);
    const cli = new DevToolsCli({
      world: {
        requestVoxelObjectProbe,
        debugSnapshot: vi.fn(() => ({
          mode: "server-authoritative",
          lastObjectProbe: { objectId: 42, damagedPartCount: 1 },
        })),
      },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("voxel_object", ["42", "4", "12", "12"])).toMatchObject({
      ok: true,
      command: "voxel_object",
      text: "object probe submitted for object 42 at (4,12,12)",
      data: expect.objectContaining({
        objectId: 42,
        coord: { x: 4, y: 12, z: 12 },
        voxel: expect.objectContaining({
          lastObjectProbe: { objectId: 42, damagedPartCount: 1 },
        }),
      }),
    });
    expect(requestVoxelObjectProbe).toHaveBeenCalledWith(42, { x: 4, y: 12, z: 12 });

    expect(cli.executeCliCommand("voxel_object", ["42", "4", "12"])).toMatchObject({
      ok: false,
      command: "voxel_object",
      text: "usage: voxel_object <object_id> <x> <y> <z>",
    });
  });

  it("preserves a non-CLI source when routing voxel_conduct", () => {
    const conductBetween = vi.fn(() => true);
    const cli = new DevToolsCli({
      edit: { conductBetween },
    } as unknown as DevToolsDeps);

    expect(
      cli.executeCliCommand(
        "voxel_conduct",
        ["0", "1", "0", "3", "1", "0", "120", "90"],
        "keyboard",
      ),
    ).toMatchObject({
      ok: true,
      command: "voxel_conduct",
      data: expect.objectContaining({ source: "keyboard" }),
    });

    expect(conductBetween).toHaveBeenCalledWith(
      { x: 0, y: 1, z: 0 },
      { x: 3, y: 1, z: 0 },
      120,
      "keyboard",
      90,
    );
  });

  it("rejects malformed voxel_conduct commands before touching the edit controller", () => {
    const conductBetween = vi.fn(() => true);
    const cli = new DevToolsCli({
      edit: { conductBetween },
    } as unknown as DevToolsDeps);

    expect(cli.executeCliCommand("voxel_conduct", ["0", "1", "0"])).toMatchObject({
      ok: false,
      command: "voxel_conduct",
      text: "usage: voxel_conduct <sx> <sy> <sz> <tx> <ty> <tz> [source_potential] [max_ticks] [dc|ac|pulse] [voltage] [current_limit_amps] [frequency_hz] [load_current_amps] [energy_budget_joules]",
    });
    expect(conductBetween).not.toHaveBeenCalled();
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
