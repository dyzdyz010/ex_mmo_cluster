import type { CliCommandResult } from "../../observe/cli";
import type { ChatMessage, ChatScope } from "../../domain/chat/types";
import { isChatScope } from "../../domain/chat/types";

export interface ChatPanelCommandPort {
  executeCliCommand(command: string, args: string[], source?: string): CliCommandResult;
}

interface ChatPanelState {
  scope: ChatScope;
  draft: string;
  messages: ChatMessage[];
}

type ChatPanelTarget = {
  getAttribute(name: string): string | null;
};

type ChatPanelInputTarget = {
  value: string;
  getAttribute(name: string): string | null;
};

const MaxVisibleMessages = 8;

export class ChatPanelView {
  private state: ChatPanelState = {
    scope: "world",
    draft: "",
    messages: [],
  };
  private lastResult: CliCommandResult | null = null;

  constructor(
    private readonly panel: HTMLDivElement,
    private readonly commands: ChatPanelCommandPort,
  ) {
    this.panel.addEventListener("click", this.handleClick);
    this.panel.addEventListener("input", this.handleInput);
    this.panel.addEventListener("keydown", this.handleKeyDown);
    this.panel.addEventListener("pointerdown", this.stopWorldEditPointer);
    this.renderNow();
  }

  appendMessage(message: ChatMessage): void {
    this.state = {
      ...this.state,
      messages: [...this.state.messages, message].slice(-MaxVisibleMessages),
    };
    this.renderNow();
  }

  dispose(): void {
    this.panel.removeEventListener("click", this.handleClick);
    this.panel.removeEventListener("input", this.handleInput);
    this.panel.removeEventListener("keydown", this.handleKeyDown);
    this.panel.removeEventListener("pointerdown", this.stopWorldEditPointer);
    this.panel.innerHTML = "";
  }

  private readonly handleClick = (event: MouseEvent): void => {
    const target = closestChatPanelTarget(event.target);
    if (!target) return;

    const requestedScope = target.getAttribute("data-chat-scope");
    if (isChatScope(requestedScope)) {
      event.preventDefault();
      this.state = { ...this.state, scope: requestedScope };
      this.renderNow();
      return;
    }

    const action = target.getAttribute("data-chat-action");
    if (action === "send") {
      event.preventDefault();
      this.sendDraft();
    }
  };

  private readonly handleInput = (event: Event): void => {
    const input = chatPanelInput(event.target);
    if (!input || input.getAttribute("data-chat-input") !== "message") {
      return;
    }
    this.state = { ...this.state, draft: input.value };
  };

  private readonly handleKeyDown = (event: KeyboardEvent): void => {
    const input = chatPanelInput(event.target);
    if (!input || input.getAttribute("data-chat-input") !== "message") {
      return;
    }
    event.stopPropagation();
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.sendDraft();
    }
  };

  private readonly stopWorldEditPointer = (event: PointerEvent): void => {
    event.stopPropagation();
  };

  private sendDraft(): void {
    const text = this.state.draft.trim();
    if (text.length === 0) {
      this.lastResult = { ok: false, command: "chat", text: "empty chat message" };
      this.renderNow();
      return;
    }

    this.lastResult = this.commands.executeCliCommand(
      "chat",
      [this.state.scope, text],
      "chat_panel",
    );
    if (this.lastResult.ok) {
      this.state = { ...this.state, draft: "" };
    }
    this.renderNow();
  }

  private renderNow(): void {
    this.panel.innerHTML = renderChatPanelHtml(this.state, this.lastResult);
  }
}

export function renderChatPanelHtml(
  state: ChatPanelState,
  lastResult: CliCommandResult | null,
): string {
  const resultClass = lastResult ? (lastResult.ok ? " is-ok" : " is-error") : "";
  const resultText = lastResult
    ? `${lastResult.command}: ${lastResult.text}`
    : "server-derived world / region / local chat";
  const messages =
    state.messages.length > 0
      ? state.messages.map(renderChatMessage).join("")
      : `<li class="chat-panel-empty">No messages yet</li>`;

  return [
    `<section class="chat-panel-surface" aria-label="World Chat">`,
    `<div class="chat-panel-header">`,
    `<span class="chat-panel-title">World Chat</span>`,
    `<span class="chat-panel-badge">${escapeHtml(state.scope)}</span>`,
    `</div>`,
    `<div class="chat-panel-scopes" role="toolbar" aria-label="Chat scope">`,
    renderScopeButton("world", state.scope),
    renderScopeButton("region", state.scope),
    renderScopeButton("local", state.scope),
    `</div>`,
    `<ul class="chat-panel-messages">${messages}</ul>`,
    `<div class="chat-panel-compose">`,
    `<input type="text" value="${escapeHtml(state.draft)}" data-chat-input="message" aria-label="Chat message" maxlength="240" />`,
    `<button type="button" data-chat-action="send" aria-label="Send chat message">Send</button>`,
    `</div>`,
    `<div class="chat-panel-result${resultClass}">${escapeHtml(resultText)}</div>`,
    `<div class="chat-panel-cli"><code>window.__voxelCli?.run(&quot;chat region hello&quot;)</code></div>`,
    `</section>`,
  ].join("");
}

function renderScopeButton(scope: ChatScope, selected: ChatScope): string {
  const className = scope === selected ? "chat-panel-scope is-selected" : "chat-panel-scope";
  return [
    `<button class="${className}" type="button"`,
    ` data-chat-scope="${scope}"`,
    ` aria-pressed="${scope === selected ? "true" : "false"}">`,
    escapeHtml(scope),
    `</button>`,
  ].join("");
}

function renderChatMessage(message: ChatMessage): string {
  return [
    `<li class="chat-panel-message">`,
    `<span>${escapeHtml(message.username || `#${message.cid}`)}</span>`,
    `<p>${escapeHtml(message.text)}</p>`,
    `</li>`,
  ].join("");
}

function closestChatPanelTarget(target: EventTarget | null): ChatPanelTarget | null {
  const candidate = target as
    | {
        closest?: (selector: string) => ChatPanelTarget | null;
      }
    | null
    | undefined;
  return candidate?.closest?.("[data-chat-action],[data-chat-scope]") ?? null;
}

function chatPanelInput(target: EventTarget | null): ChatPanelInputTarget | null {
  const candidate = target as Partial<ChatPanelInputTarget> | null | undefined;
  return typeof candidate?.value === "string" && typeof candidate.getAttribute === "function"
    ? (candidate as ChatPanelInputTarget)
    : null;
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
