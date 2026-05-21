import type { FrameSubscriber } from "../../app/gameLoop";
import type { CliCommandResult } from "../../observe/cli";
import type { FMacroCoord } from "../../voxel/core/types";
import type { VoxelWorldAdapter } from "../../voxel/worldAdapter";

export interface VoxelDebugPanelCommandPort {
  executeCliCommand(command: string, args: string[], source?: string): CliCommandResult;
}

export interface VoxelPanelConductionPair {
  sourceCoord: FMacroCoord;
  targetCoord: FMacroCoord;
}

type VoxelPanelButtonTarget = {
  getAttribute(name: string): string | null;
};

type VoxelPanelInputTarget = {
  value: string;
  getAttribute(name: string): string | null;
};

interface VoxelPanelFormState {
  subscribeCx: string;
  subscribeCy: string;
  subscribeCz: string;
  subscribeRadius: string;
  impactX: string;
  impactY: string;
  impactZ: string;
  material: string;
  conductSourceX: string;
  conductSourceY: string;
  conductSourceZ: string;
  conductTargetX: string;
  conductTargetY: string;
  conductTargetZ: string;
  conductPotential: string;
  conductTicks: string;
  conductOutputMode: string;
  conductVoltage: string;
  conductCurrentLimitAmps: string;
  conductFrequencyHz: string;
  conductLoadCurrentAmps: string;
  conductEnergyBudgetJoules: string;
}

const PANEL_REFRESH_INTERVAL_MS = 250;

const DefaultFormState: VoxelPanelFormState = {
  subscribeCx: "0",
  subscribeCy: "0",
  subscribeCz: "0",
  subscribeRadius: "0",
  impactX: "0",
  impactY: "0",
  impactZ: "0",
  material: "1",
  conductSourceX: "",
  conductSourceY: "",
  conductSourceZ: "",
  conductTargetX: "",
  conductTargetY: "",
  conductTargetZ: "",
  conductPotential: "120",
  conductTicks: "90",
  conductOutputMode: "",
  conductVoltage: "",
  conductCurrentLimitAmps: "",
  conductFrequencyHz: "",
  conductLoadCurrentAmps: "",
  conductEnergyBudgetJoules: "",
};

export interface VoxelPanelFieldOverlaySnapshot {
  visible: boolean;
  regionCount: number;
  regions: Array<{
    regionId?: number;
    chunkCoord?: { cx: number; cy: number; cz: number };
    electricCells?: number;
    currentCells?: number;
    smokeParticles?: number;
    temperatureCells?: number;
  }>;
}

/**
 * Visible server-authoritative voxel control surface. It owns only DOM
 * projection; commands are delegated to the same DevTools handler as the CLI.
 */
export class VoxelDebugPanelView implements FrameSubscriber {
  private refreshAccumulatorMs = PANEL_REFRESH_INTERVAL_MS;
  private renderKey = "";
  private formState: VoxelPanelFormState = { ...DefaultFormState };
  private lastResult: CliCommandResult | null = null;

  constructor(
    private readonly panel: HTMLDivElement,
    private readonly commands: VoxelDebugPanelCommandPort,
    private readonly world: VoxelWorldAdapter,
    private readonly fieldOverlayToggle?: () => void,
    private readonly setSelectedVoxelTemperature?: (targetTemperatureCelsius: number) => boolean,
    private readonly selectedVoxel?: () => FMacroCoord | null,
    private readonly selectedConductionPair?: () => VoxelPanelConductionPair | null,
    private readonly fieldOverlaySnapshot?: () => VoxelPanelFieldOverlaySnapshot,
    private readonly openOperationGuide?: () => void,
  ) {
    this.panel.addEventListener("click", this.handleClick);
    this.panel.addEventListener("input", this.handleInput);
    this.panel.addEventListener("pointerdown", this.stopWorldEditPointer);
    this.renderNow(true);
  }

  onFrame(_nowMs: number, dtMs: number): void {
    this.refreshAccumulatorMs += dtMs;
    if (this.refreshAccumulatorMs < PANEL_REFRESH_INTERVAL_MS) {
      return;
    }
    this.refreshAccumulatorMs = 0;
    this.renderNow();
  }

  dispose(): void {
    this.panel.removeEventListener("click", this.handleClick);
    this.panel.removeEventListener("input", this.handleInput);
    this.panel.removeEventListener("pointerdown", this.stopWorldEditPointer);
    this.panel.innerHTML = "";
  }

  captureConductionEndpoint(role: "source" | "target", _source = "keyboard"): CliCommandResult {
    this.lastResult = this.captureSelectedConductionEndpoint(role);
    this.renderKey = "";
    this.renderNow(true);
    return this.lastResult;
  }

  submitConduction(source = "keyboard"): CliCommandResult {
    this.lastResult = this.runConduction(source);
    this.renderKey = "";
    this.renderNow(true);
    return this.lastResult;
  }

  private readonly handleClick = (event: MouseEvent): void => {
    const button = closestVoxelPanelButton(event.target);
    if (!button) {
      return;
    }

    const action = button.getAttribute("data-voxel-action");
    if (!action) {
      return;
    }

    event.preventDefault();
    this.lastResult = this.runAction(action);
    this.renderKey = "";
    this.renderNow(true);
  };

  private readonly handleInput = (event: Event): void => {
    const input = voxelPanelInput(event.target);
    if (!input) {
      return;
    }

    const field = input.getAttribute("data-voxel-input");
    if (isVoxelPanelField(field)) {
      this.formState = { ...this.formState, [field]: input.value };
    }
  };

  private readonly stopWorldEditPointer = (event: PointerEvent): void => {
    event.stopPropagation();
  };

  private runAction(action: string): CliCommandResult {
    switch (action) {
      case "refresh":
        return this.commands.executeCliCommand("voxel_sync", []);
      case "probe":
        return this.commands.executeCliCommand("voxel_probe", []);
      case "rebind":
        return this.commands.executeCliCommand("voxel_probe", [
          `voxel_rebind ${this.logicalSceneId()} all`,
        ]);
      case "versions":
        return this.commands.executeCliCommand("chunk_versions", []);
      case "subscribe":
        return this.commands.executeCliCommand("voxel_subscribe", [
          this.formState.subscribeCx,
          this.formState.subscribeCy,
          this.formState.subscribeCz,
          this.formState.subscribeRadius,
        ]);
      case "impact":
        return this.commands.executeCliCommand("voxel_impact", [
          this.formState.impactX,
          this.formState.impactY,
          this.formState.impactZ,
          this.formState.material,
        ]);
      case "field-overlay":
        this.fieldOverlayToggle?.();
        return { ok: true, command: action, text: "field overlay toggled" };
      case "guide":
        this.openOperationGuide?.();
        return { ok: true, command: action, text: "operation guide opened" };
      case "heat-selected": {
        const ok = this.setSelectedVoxelTemperature?.(800) === true;
        return {
          ok,
          command: action,
          text: ok ? "set selected voxel to 800C" : "heat selected voxel rejected",
        };
      }
      case "cool-selected": {
        const ok = this.setSelectedVoxelTemperature?.(0) === true;
        return {
          ok,
          command: action,
          text: ok ? "set selected voxel to 0C" : "cool selected voxel rejected",
        };
      }
      case "conduct-source-selection":
        return this.captureSelectedConductionEndpoint("source");
      case "conduct-target-selection":
        return this.captureSelectedConductionEndpoint("target");
      case "auto-circuit-selected":
        return this.runAutoCircuit("voxel_panel");
      case "conduct":
        return this.runConduction("voxel_panel");
      default:
        return { ok: false, command: action, text: "unknown voxel panel action" };
    }
  }

  private runConduction(source: string): CliCommandResult {
    const endpointArgs = this.conductionEndpointArgs();
    if (!endpointArgs) {
      return {
        ok: false,
        command: "conduct",
        text: "aim at a voxel or fill source/target coordinates",
      };
    }

    return this.commands.executeCliCommand(
      "voxel_conduct",
      [
        ...endpointArgs,
        this.formState.conductPotential,
        this.formState.conductTicks,
        ...this.conductionPowerArgs(),
      ],
      source,
    );
  }

  private runAutoCircuit(source: string): CliCommandResult {
    const coord = this.selectedVoxel?.();
    if (!coord) {
      return {
        ok: false,
        command: "voxel_auto_circuit",
        text: "no selected voxel",
      };
    }

    return this.commands.executeCliCommand(
      "voxel_auto_circuit",
      [String(coord.x), String(coord.y), String(coord.z), this.formState.conductTicks],
      source,
    );
  }

  private conductionPowerArgs(): string[] {
    const args = [
      this.formState.conductOutputMode,
      this.formState.conductVoltage,
      this.formState.conductCurrentLimitAmps,
      this.formState.conductFrequencyHz,
      this.formState.conductLoadCurrentAmps,
      this.formState.conductEnergyBudgetJoules,
    ];
    if (args.every((value) => value.trim().length === 0)) {
      return [];
    }

    return [
      this.formState.conductOutputMode || "dc",
      this.formState.conductVoltage || this.formState.conductPotential,
      this.formState.conductCurrentLimitAmps,
      this.formState.conductFrequencyHz,
      this.formState.conductLoadCurrentAmps,
      this.formState.conductEnergyBudgetJoules,
    ];
  }

  private conductionEndpointArgs(): string[] | null {
    const manualArgs = [
      this.formState.conductSourceX,
      this.formState.conductSourceY,
      this.formState.conductSourceZ,
      this.formState.conductTargetX,
      this.formState.conductTargetY,
      this.formState.conductTargetZ,
    ];

    if (manualArgs.every((value) => value.trim().length > 0)) {
      return manualArgs;
    }

    const pair = this.selectedConductionPair?.();
    if (!pair) return null;

    this.formState = {
      ...this.formState,
      conductSourceX: String(pair.sourceCoord.x),
      conductSourceY: String(pair.sourceCoord.y),
      conductSourceZ: String(pair.sourceCoord.z),
      conductTargetX: String(pair.targetCoord.x),
      conductTargetY: String(pair.targetCoord.y),
      conductTargetZ: String(pair.targetCoord.z),
    };

    return [
      this.formState.conductSourceX,
      this.formState.conductSourceY,
      this.formState.conductSourceZ,
      this.formState.conductTargetX,
      this.formState.conductTargetY,
      this.formState.conductTargetZ,
    ];
  }

  private captureSelectedConductionEndpoint(role: "source" | "target"): CliCommandResult {
    const coord = this.selectedVoxel?.();
    if (!coord) {
      return {
        ok: false,
        command: `conduct-${role}-selection`,
        text: "no selected voxel",
      };
    }

    this.formState = {
      ...this.formState,
      ...(role === "source"
        ? {
            conductSourceX: String(coord.x),
            conductSourceY: String(coord.y),
            conductSourceZ: String(coord.z),
          }
        : {
            conductTargetX: String(coord.x),
            conductTargetY: String(coord.y),
            conductTargetZ: String(coord.z),
          }),
    };

    return {
      ok: true,
      command: `conduct-${role}-selection`,
      text: `${role} set to ${coord.x},${coord.y},${coord.z}`,
    };
  }

  private logicalSceneId(): number {
    return numberAt(this.world.debugSnapshot(), "logicalSceneId") ?? 1;
  }

  private renderNow(force = false): void {
    const snapshot = this.world.debugSnapshot();
    const nextKey = JSON.stringify({
      snapshot: summarizeVoxelSnapshot(snapshot),
      field: summarizeFieldOverlaySnapshot(this.fieldOverlaySnapshot?.()),
      formState: this.formState,
      lastResult: summarizeResult(this.lastResult),
    });

    if (!force && nextKey === this.renderKey) {
      return;
    }

    this.panel.innerHTML = renderVoxelDebugPanelHtml(
      snapshot,
      this.formState,
      this.lastResult,
      this.fieldOverlaySnapshot?.(),
    );
    this.renderKey = nextKey;
  }
}

export function renderVoxelDebugPanelHtml(
  snapshot: Record<string, unknown>,
  formState: VoxelPanelFormState = DefaultFormState,
  lastResult: CliCommandResult | null = null,
  fieldOverlaySnapshot?: VoxelPanelFieldOverlaySnapshot,
): string {
  const summary = summarizeVoxelSnapshot(snapshot);
  const fieldSummary = summarizeFieldOverlaySnapshot(fieldOverlaySnapshot);
  const alerts = summarizeVoxelAlerts(snapshot);
  const resultClass = lastResult ? (lastResult.ok ? " is-ok" : " is-error") : "";
  const badgeClass = alerts.length > 0 ? " is-error" : "";
  const resultText = lastResult
    ? `${lastResult.command}: ${lastResult.text}`
    : `${summary.mode} / ${summary.subscriptionState}`;
  const alertHtml =
    alerts.length > 0
      ? `<div class="voxel-panel-alerts" data-voxel-panel-alerts>${alerts
          .map((alert) => `<div>${escapeHtml(alert)}</div>`)
          .join("")}</div>`
      : "";

  return [
    `<section class="voxel-panel-surface" aria-label="Server voxel">`,
    `<div class="voxel-panel-header">`,
    `<span class="voxel-panel-title">Voxel Runtime</span>`,
    `<span class="voxel-panel-badge${badgeClass}" data-voxel-panel-status>${escapeHtml(summary.subscriptionState)}</span>`,
    `</div>`,
    alertHtml,
    `<dl class="voxel-panel-stats">`,
    renderStat("mode", summary.mode),
    renderStat("seed", summary.seedState),
    renderStat("snapshots", summary.snapshotCount),
    renderStat("chunk", summary.lastChunk),
    renderStat("cells", summary.cells),
    renderStat("intent", summary.lastIntent),
    renderStat("field", fieldSummary),
    `</dl>`,
    `<div class="voxel-panel-result${resultClass}" data-voxel-panel-result>${escapeHtml(resultText)}</div>`,
    `<div class="voxel-panel-actions" role="toolbar" aria-label="Pointer-worthy voxel actions">`,
    renderButton("field-overlay", "Field"),
    renderButton("auto-circuit-selected", "Circuit"),
    renderButton("guide", "Guide"),
    `</div>`,
    `<div class="voxel-panel-form voxel-panel-form--subscribe">`,
    renderNumberInput("subscribeCx", "Sub X", formState.subscribeCx),
    renderNumberInput("subscribeCy", "Sub Y", formState.subscribeCy),
    renderNumberInput("subscribeCz", "Sub Z", formState.subscribeCz),
    renderNumberInput("subscribeRadius", "R", formState.subscribeRadius, 0),
    renderButton("subscribe", "Subscribe"),
    `</div>`,
    renderShortcutGuidance(),
    renderCliHints(),
    renderConductionReadout(formState),
    `</section>`,
  ].join("");
}

function renderShortcutGuidance(): string {
  return [
    `<section class="voxel-panel-guidance" data-voxel-panel-shortcuts>`,
    `<h3>快捷键</h3>`,
    renderShortcutRow("WASD / Space", "移动 / 跳跃"),
    renderShortcutRow("Mouse L/R", "破坏 / 放置当前热栏材料"),
    renderShortcutRow("1-9 / Wheel", "选择热栏材料或 prefab"),
    renderShortcutRow("F / E", "加热准星方块 / 对准导电"),
    renderShortcutRow("Z / X / C", "记录电源 / 记录目标 / 执行导电"),
    `</section>`,
  ].join("");
}

function renderShortcutRow(keys: string, text: string): string {
  return [
    `<div class="voxel-panel-shortcut">`,
    `<kbd>${escapeHtml(keys)}</kbd>`,
    `<span>${escapeHtml(text)}</span>`,
    `</div>`,
  ].join("");
}

function renderCliHints(): string {
  const commands = [
    `window.__voxelCli?.run("snapshot")`,
    `window.__voxelCli?.run("voxel_sync")`,
    `window.__voxelCli?.run("logs 20")`,
    `window.__voxelCli?.run("voxel_auto_circuit 4 12 12")`,
    `window.__voxelCli?.run("voxel_subscribe 0 0 0 1")`,
  ];
  return [
    `<section class="voxel-panel-guidance voxel-panel-guidance--cli">`,
    `<h3>程序指令</h3>`,
    `<p>鼠标被视角占用时，优先用键盘和控制台命令。</p>`,
    `<ul>`,
    ...commands.map((command) => `<li><code>${escapeHtml(command)}</code></li>`),
    `</ul>`,
    `</section>`,
  ].join("");
}

function renderConductionReadout(formState: VoxelPanelFormState): string {
  return [
    `<section class="voxel-panel-guidance">`,
    `<h3>导电状态</h3>`,
    renderShortcutRow("source", conductionCoordText(formState, "source")),
    renderShortcutRow("target", conductionCoordText(formState, "target")),
    renderShortcutRow("power", `${formState.conductPotential}V / ${formState.conductTicks} ticks`),
    `</section>`,
  ].join("");
}

function conductionCoordText(formState: VoxelPanelFormState, role: "source" | "target"): string {
  const values =
    role === "source"
      ? [formState.conductSourceX, formState.conductSourceY, formState.conductSourceZ]
      : [formState.conductTargetX, formState.conductTargetY, formState.conductTargetZ];
  return values.every((value) => value.trim().length > 0) ? values.join(",") : "未记录";
}

function renderStat(label: string, value: string): string {
  const className =
    label === "field" ? "voxel-panel-stat voxel-panel-stat--field" : "voxel-panel-stat";
  return [
    `<div class="${className}">`,
    `<dt>${escapeHtml(label)}</dt>`,
    `<dd>${escapeHtml(value)}</dd>`,
    `</div>`,
  ].join("");
}

function renderButton(action: string, label: string): string {
  return [
    `<button class="voxel-panel-button" type="button"`,
    ` data-voxel-action="${escapeHtml(action)}"`,
    ` aria-label="${escapeHtml(label)}">`,
    escapeHtml(label),
    `</button>`,
  ].join("");
}

function renderNumberInput(
  field: keyof VoxelPanelFormState,
  label: string,
  value: string,
  min?: number,
): string {
  const minAttr = min === undefined ? "" : ` min="${min}"`;
  return [
    `<label class="voxel-panel-input">`,
    `<span>${escapeHtml(label)}</span>`,
    `<input type="number"${minAttr} value="${escapeHtml(value)}"`,
    ` data-voxel-input="${field}" aria-label="${escapeHtml(label)}" />`,
    `</label>`,
  ].join("");
}

function summarizeVoxelSnapshot(snapshot: Record<string, unknown>) {
  const lastSnapshot = objectAt(snapshot, "lastSnapshot");
  const lastIntent = objectAt(snapshot, "lastIntentResult");
  const transport = objectAt(snapshot, "transport");
  const snapshotCount = numberText(transport?.receivedVoxelSnapshotCount);
  const chunkCoord = stringAt(lastSnapshot, "chunkCoord") ?? "none";
  const chunkVersion = numberText(lastSnapshot?.chunkVersion);
  const intentCode = stringAt(lastIntent, "resultCodeName") ?? "none";
  const intentRef = numberText(lastIntent?.resultRef);
  const totalSolid = numberText(snapshot.totalSolidBlocks);
  const totalRefined = numberText(snapshot.totalRefinedCells);

  return {
    mode: stringAt(snapshot, "mode") ?? "unknown",
    seedState: stringAt(snapshot, "seedState") ?? "n/a",
    subscriptionState: stringAt(snapshot, "subscriptionState") ?? "n/a",
    snapshotCount,
    lastChunk: `${chunkCoord} v${chunkVersion}`,
    lastIntent: `${intentCode} #${intentRef}`,
    cells: `solid=${totalSolid} refined=${totalRefined}`,
  };
}

function summarizeFieldOverlaySnapshot(
  snapshot: VoxelPanelFieldOverlaySnapshot | undefined,
): string {
  const regions = snapshot?.regions ?? [];
  const electricCells = regions.reduce((sum, region) => sum + (region.electricCells ?? 0), 0);
  const currentCells = regions.reduce((sum, region) => sum + (region.currentCells ?? 0), 0);
  const smokeParticles = regions.reduce((sum, region) => sum + (region.smokeParticles ?? 0), 0);
  return `field=${snapshot?.visible ? "on" : "off"} regions=${snapshot?.regionCount ?? 0} electric=${electricCells} current=${currentCells} smoke=${smokeParticles}`;
}

function summarizeVoxelAlerts(snapshot: Record<string, unknown>): string[] {
  const alerts: string[] = [];
  const seedState = stringAt(snapshot, "seedState");
  const subscriptionState = stringAt(snapshot, "subscriptionState");
  const lastError = stringAt(snapshot, "lastError");
  const transport = objectAt(snapshot, "transport");
  const available = booleanAt(transport, "available");
  const transportStatus = stringAt(transport, "connectionStatus");
  const transportPhase = stringAt(transport, "connectionPhase");
  const connectionLostReason = stringAt(transport, "connectionLostReason");
  const transportError = stringAt(transport, "lastError");
  const blockedSend = objectAt(transport, "lastBlockedSend");
  const lastIntent = objectAt(snapshot, "lastIntentResult");
  const intentCode = stringAt(lastIntent, "resultCodeName");

  if (seedState === "failed") {
    alerts.push(`dev_seed failed: ${lastError || "unknown"}`);
  } else if (seedState === "idle" && available === false) {
    alerts.push(
      `dev_seed not started: waiting for transport (${transportStatus || "unknown"}:${transportPhase || "unknown"})`,
    );
  }

  if (available === false) {
    alerts.push(
      `transport unavailable: ${transportError || connectionLostReason || transportStatus || "not connected"}`,
    );
  }

  if (subscriptionState === "idle" && available !== false) {
    alerts.push(`subscription not active: ${subscriptionState}`);
  }

  if (blockedSend) {
    alerts.push(
      `send blocked: ${stringAt(blockedSend, "source") || "unknown"}: ${stringAt(blockedSend, "reason") || "unknown"}`,
    );
  }

  if (intentCode === "rejected" || intentCode === "stale") {
    alerts.push(`${intentCode}: ${stringAt(lastIntent, "reason") || "unknown"}`);
  }

  if (lastError && seedState !== "failed") {
    alerts.push(`last error: ${lastError}`);
  }

  return Array.from(new Set(alerts)).slice(0, 5);
}

function summarizeResult(result: CliCommandResult | null): Record<string, unknown> | null {
  if (!result) {
    return null;
  }
  return { ok: result.ok, command: result.command, text: result.text };
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

function numberText(value: unknown): string {
  return typeof value === "number" && Number.isFinite(value) ? String(value) : "0";
}

function closestVoxelPanelButton(target: EventTarget | null): VoxelPanelButtonTarget | null {
  const candidate = target as { closest?: (selector: string) => unknown } | null;
  const button = candidate?.closest?.("[data-voxel-action]");
  if (!button || typeof (button as { getAttribute?: unknown }).getAttribute !== "function") {
    return null;
  }
  return button as VoxelPanelButtonTarget;
}

function voxelPanelInput(target: EventTarget | null): VoxelPanelInputTarget | null {
  const candidate = target as Partial<VoxelPanelInputTarget> | null;
  if (
    !candidate ||
    typeof candidate.value !== "string" ||
    typeof candidate.getAttribute !== "function"
  ) {
    return null;
  }
  return candidate as VoxelPanelInputTarget;
}

function isVoxelPanelField(field: string | null): field is keyof VoxelPanelFormState {
  return field !== null && Object.prototype.hasOwnProperty.call(DefaultFormState, field);
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => {
    switch (char) {
      case "&":
        return "&amp;";
      case "<":
        return "&lt;";
      case ">":
        return "&gt;";
      case '"':
        return "&quot;";
      case "'":
        return "&#39;";
      default:
        return char;
    }
  });
}
