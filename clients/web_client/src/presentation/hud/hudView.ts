import { getMaterialDefinition } from "../../material/catalog";
import { formatCoord, formatVector } from "../../shared/runtimeFormat";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";
import type { LocalPlayerController } from "../../app/controllers/localPlayerController";
import type { RemotePlayerController } from "../../app/controllers/remotePlayerController";
import type { RenderOrchestrator } from "../../app/controllers/renderOrchestrator";
import type { TransportPump } from "../../app/controllers/transportPump";
import type { WorldEditController } from "../../app/controllers/worldEditController";
import type { FrameSubscriber } from "../../app/gameLoop";
import type { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";

/**
 * Pulls display data from every controller once per frame and writes the HUD
 * overlay. Read-only — never mutates controller state.
 */
const HUD_REFRESH_INTERVAL_MS = 125;
const FLASH_DEFAULT_DURATION_MS = 1_000;
const FAILURE_FLASH_DURATION_MS = 3_500;
const MAX_RUNTIME_ALERTS = 6;

interface FlashMessage {
  text: string;
  expiresAtMs: number;
}

export class HudView implements FrameSubscriber {
  private frameCount = 0;
  private refreshAccumulatorMs = HUD_REFRESH_INTERVAL_MS;
  private flash: FlashMessage | null = null;

  constructor(
    private readonly hud: HTMLDivElement,
    private readonly world: VoxelWorldAdapter,
    private readonly transport: TransportPump,
    private readonly localPlayer: LocalPlayerController,
    private readonly remotePlayer: RemotePlayerController,
    private readonly edit: WorldEditController,
    private readonly render: RenderOrchestrator,
    bus?: EventBus<AppEvents>,
  ) {
    this.hud.textContent = "ex_mmo voxel web-client (booting...)";
    if (bus) {
      bus.on("world:edit-rejected", ({ reason, source }) => {
        if (reason === "no_selection") {
          this.showFlash("no target", FLASH_DEFAULT_DURATION_MS);
        } else {
          this.showFlash(`edit rejected: ${reason} (${source})`, FAILURE_FLASH_DURATION_MS);
        }
      });
      bus.on("world:voxel-sync-error", ({ reason, source }) => {
        this.showFlash(`voxel error: ${source}: ${reason}`, FAILURE_FLASH_DURATION_MS);
      });
      bus.on("world:voxel-temperature-set", ({ coord, targetTemperatureCelsius }) => {
        this.showFlash(
          `set ${formatCoord(coord)} to ${targetTemperatureCelsius}C; field overlay on`,
        );
      });
      bus.on("movement:input-blocked", ({ reason }) => {
        this.showFlash(`movement blocked: ${reason}`, FAILURE_FLASH_DURATION_MS);
      });
      bus.on("transport:mode-changed", ({ mode }) => {
        this.showFlash(`transport: ${mode}`, FLASH_DEFAULT_DURATION_MS);
      });
      // Phase 4-bis Step 4-bis-12:destroyed object 路演反馈。damaged /
      // part_destroyed 不上 HUD(避免高频破坏刷屏)。
      bus.on("world:object-state-delta", ({ flagName, objectId, debrisSpawned }) => {
        if (flagName === "destroyed") {
          this.showFlash(
            `object #${objectId} destroyed (${debrisSpawned} debris)`,
            FAILURE_FLASH_DURATION_MS,
          );
        }
      });
      // Phase A1-2:prefab 防覆盖。服务端 prepare 阶段拒绝时 wire reason 是
      // 原子级 atom(:micro_slot_already_occupied / :cannot_micro_edit_solid_macro
      // / :stale_chunk_version etc),客户端 HUD flash 提示用户。
      bus.on("world:voxel-prefab-result", ({ blueprintName, accepted, reason }) => {
        if (!accepted) {
          this.showFlash(`prefab ${blueprintName} rejected: ${reason}`, FAILURE_FLASH_DURATION_MS);
        }
      });
    }
  }

  /**
   * Shows a short overlay message at the top of the HUD. The flash auto-clears
   * after `durationMs`. Used to surface user-facing rejections (no target on
   * click, transport mode changes) without building a full notification UI.
   */
  showFlash(text: string, durationMs: number = FLASH_DEFAULT_DURATION_MS): void {
    this.flash = { text, expiresAtMs: performance.now() + durationMs };
  }

  onFrame(nowMs: number, dtMs: number): void {
    this.frameCount += 1;
    this.refreshAccumulatorMs += dtMs;
    if (this.flash !== null && nowMs >= this.flash.expiresAtMs) {
      this.flash = null;
    }
    if (this.refreshAccumulatorMs < HUD_REFRESH_INTERVAL_MS) {
      return;
    }
    this.refreshAccumulatorMs = 0;

    const currentState = this.localPlayer.getCurrentState();
    const stats = this.localPlayer.getGovernanceStats();
    const selection = this.render.getCurrentSelection();
    const renderer = this.render.getRendererDebugSnapshot();
    const selectedMaterialId = this.edit.getSelectedMaterialId();
    const hotbar = this.edit.getHotbarState();
    const voxelSnapshot = this.world.debugSnapshot();
    const movementSnapshot = this.transport.debugSnapshot();
    const runtimeAlerts = buildRuntimeAlerts(
      voxelSnapshot,
      movementSnapshot,
      this.transport.isReady(),
      this.world.mode,
    );
    const transportSnapshot = {
      voxelSync: this.world.mode,
      voxel: voxelSnapshot,
      movementTransport: movementSnapshot,
    };
    const selectedHotbarText =
      hotbar.selected.kind === "material"
        ? `${hotbar.selectedIndex + 1}:${hotbar.selected.label}`
        : `${hotbar.selectedIndex + 1}:prefab/${hotbar.selected.label}`;
    const selectionText = selection
      ? `${formatCoord(selection.occupiedMacro)} face=${formatCoord(selection.faceNormal)} -> ${formatCoord(selection.adjacentMacro)}`
      : "n/a";

    const flashLine = this.flash !== null ? [`>> ${this.flash.text}`] : [];
    const alertLines = runtimeAlerts.map((alert) => `!! ${alert}`);
    this.hud.textContent = [
      ...flashLine,
      ...alertLines,
      `ex_mmo voxel web-client  frame: ${this.frameCount}`,
      `renderer: ${renderer.active}  backend: ${renderer.backend}  fallback: ${renderer.fallbackReason ?? "none"}`,
      `voxel_sync: ${this.world.mode}  movement_transport: ${this.transport.getMode()}`,
      `voxel_state: ${truncateJson(voxelSnapshot, 360)}`,
      `movement_ready: ${this.transport.isReady()}  transport_state: ${JSON.stringify(transportSnapshot)}`,
      `chunks: ${this.world.store.listChunks().length}  solid_blocks: ${this.world.store.totalSolidBlocks()}`,
      `selected_material: ${getMaterialDefinition(selectedMaterialId).name} (${selectedMaterialId})`,
      `hotbar: ${selectedHotbarText}  entries=${hotbar.entries.map((entry, index) => `${index + 1}:${entry.label}`).join(",")}`,
      `selection: ${selectionText}`,
      `player_rendered: ${formatVector(this.localPlayer.getRenderedPosition())}`,
      `player_authority: ${formatVector(this.localPlayer.getAuthoritativePosition())}`,
      `player_tick: ${currentState?.tick ?? 0}  player_seq: ${currentState?.seq ?? 0}`,
      `player_mode: ${currentState?.movementMode ?? "unknown"}  player_vy: ${(currentState?.velocity?.y ?? 0).toFixed(1)}`,
      // Phase A4-bis follow-up: surface cid + username + visible remote
      // entities one line each so the user can eyeball whether two tabs
      // accidentally share a cid (sessionStorage / browser cache leak)
      // or whether the AOI broadcast pipeline is dropping the other
      // tab. `my_cid` is the local-player id auth issued to this tab;
      // `remote_visible` lists which other-player cids this tab is
      // currently rendering. Two tabs of the *same* player will show
      // the same `my_cid`. Two distinct players who can see each other
      // will show different `my_cid`s and each tab's `remote_visible`
      // will contain the other tab's `my_cid`.
      `multiplayer: my_cid=${(movementSnapshot as { cid?: number | null }).cid ?? "n/a"}` +
        ` username=${(movementSnapshot as { username?: string }).username ?? "n/a"}` +
        ` remote_visible=[${this.remotePlayer.getVisibleEntityIds().join(",")}]` +
        ` self_loop_dropped=${(movementSnapshot as { droppedSelfLoopSnapshotCount?: number }).droppedSelfLoopSnapshotCount ?? 0}`,
      `remote_rendered: ${formatVector(this.remotePlayer.getRenderedPosition())}`,
      `reconcile: acks=${stats.totalAcks} corrections=${stats.totalCorrections} replays=${stats.totalReplays} hard_snaps=${stats.totalHardSnaps}`,
      `last_correction=${stats.lastCorrectionDistance.toFixed(2)}  jitter_ms=${this.localPlayer.getCurrentJitterMs().toFixed(2)}  soft=${this.localPlayer.getCurrentSoftPositionError().toFixed(2)}`,
      `edits: placed=${this.world.store.editStats.placed} broken=${this.world.store.editStats.broken} rejected=${this.world.store.editStats.rejected} conflicts=${this.world.store.editStats.conflicts}`,
      "controls: left click break, right click place, F set heat, wheel hotbar, ctrl+wheel zoom, WASD move, Space jump, 1-7 select",
      'cli: window.__voxelCli?.run("snapshot")',
    ].join("\n");
  }
}

function truncateJson(value: unknown, maxLength: number): string {
  const text = JSON.stringify(value);
  return text.length <= maxLength ? text : `${text.slice(0, maxLength - 3)}...`;
}

export function buildRuntimeAlerts(
  voxelSnapshot: Record<string, unknown>,
  movementSnapshot: Record<string, unknown>,
  movementReady: boolean,
  worldMode: string,
): string[] {
  const alerts: string[] = [];
  const connectionStatus = stringAt(movementSnapshot, "connectionStatus");
  const connectionPhase = stringAt(movementSnapshot, "connectionPhase");
  const connectionLostReason = stringAt(movementSnapshot, "connectionLostReason");
  const movementLastError = stringAt(movementSnapshot, "lastError");
  const wsUrl = stringAt(movementSnapshot, "webSocketUrl") ?? "(unknown ws)";
  const authBase = stringAt(movementSnapshot, "authBaseUrl") || "(vite /ingame proxy)";

  if (connectionStatus === "disconnected") {
    alerts.push(
      `TRANSPORT DISCONNECTED: ${connectionLostReason || movementLastError || "unknown"} auth=${authBase} ws=${wsUrl}`,
    );
  } else if (!movementReady && connectionStatus === "connecting") {
    alerts.push(
      `TRANSPORT CONNECTING: phase=${connectionPhase || "unknown"} auth=${authBase} ws=${wsUrl}`,
    );
  } else if (!movementReady) {
    alerts.push(`MOVEMENT NOT READY: ${movementLastError || connectionStatus || "unknown"}`);
  }

  const blockedInputs = numberAt(movementSnapshot, "blockedInputCount") ?? 0;
  const blockedInputReason = stringAt(movementSnapshot, "lastBlockedInputReason");
  if (blockedInputs > 0) {
    alerts.push(
      `MOVEMENT INPUT BLOCKED: ${blockedInputReason || "unknown"} count=${blockedInputs}`,
    );
  }

  if (worldMode === "server-authoritative") {
    const seedState = stringAt(voxelSnapshot, "seedState");
    const subscriptionState = stringAt(voxelSnapshot, "subscriptionState");
    const voxelError = stringAt(voxelSnapshot, "lastError");
    const voxelTransport = objectAt(voxelSnapshot, "transport");
    const voxelAvailable = booleanAt(voxelTransport, "available");
    const voxelTransportError = stringAt(voxelTransport, "lastError");
    const voxelConnectionStatus = stringAt(voxelTransport, "connectionStatus");
    const voxelConnectionPhase = stringAt(voxelTransport, "connectionPhase");
    const voxelBlockedSend = objectAt(voxelTransport, "lastBlockedSend");

    if (seedState === "failed") {
      alerts.push(`VOXEL DEV SEED FAILED: ${voxelError || "unknown"}`);
    } else if (seedState === "idle" && voxelAvailable === false) {
      alerts.push(
        `VOXEL DEV SEED NOT STARTED: waiting for transport (${voxelConnectionStatus || "unknown"}:${voxelConnectionPhase || "unknown"})`,
      );
    }

    if (voxelAvailable === false) {
      alerts.push(
        `VOXEL TRANSPORT UNAVAILABLE: ${voxelTransportError || voxelConnectionStatus || "not connected"}`,
      );
    }

    if (subscriptionState === "idle" && voxelAvailable !== false) {
      alerts.push(`VOXEL SUBSCRIPTION NOT ACTIVE: ${subscriptionState}`);
    }

    if (voxelBlockedSend) {
      const source = stringAt(voxelBlockedSend, "source") ?? "unknown";
      const reason = stringAt(voxelBlockedSend, "reason") ?? "unknown";
      alerts.push(`VOXEL SEND BLOCKED: ${source}: ${reason}`);
    }

    const lastIntent = objectAt(voxelSnapshot, "lastIntentResult");
    const resultCode = stringAt(lastIntent, "resultCodeName");
    if (resultCode === "rejected" || resultCode === "stale") {
      alerts.push(
        `VOXEL INTENT ${resultCode.toUpperCase()}: ${stringAt(lastIntent, "reason") || "unknown"}`,
      );
    }

    if (voxelError && seedState !== "failed") {
      alerts.push(`VOXEL ERROR: ${voxelError}`);
    }
  }

  return unique(alerts).slice(0, MAX_RUNTIME_ALERTS);
}

function unique(values: string[]): string[] {
  return Array.from(new Set(values));
}

function objectAt(
  source: Record<string, unknown> | undefined,
  key: string,
): Record<string, unknown> | undefined {
  const value = source?.[key];
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function stringAt(source: Record<string, unknown> | undefined, key: string): string | undefined {
  const value = source?.[key];
  return typeof value === "string" ? value : undefined;
}

function numberAt(source: Record<string, unknown> | undefined, key: string): number | undefined {
  const value = source?.[key];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function booleanAt(source: Record<string, unknown> | undefined, key: string): boolean | undefined {
  const value = source?.[key];
  return typeof value === "boolean" ? value : undefined;
}
