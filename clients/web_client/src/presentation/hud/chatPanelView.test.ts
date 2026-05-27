import { describe, expect, it } from "vitest";
import type { CliCommandResult } from "../../observe/cli";
import type { ChatMessage } from "../../domain/chat/types";
import { ChatPanelView, renderChatPanelHtml, type ChatPanelCommandPort } from "./chatPanelView";

class FakeChatPanelRoot {
  innerHTML = "";
  private clickListener: ((event: MouseEvent) => void) | null = null;
  private inputListener: ((event: Event) => void) | null = null;
  private keydownListener: ((event: KeyboardEvent) => void) | null = null;
  private pointerDownListener: ((event: PointerEvent) => void) | null = null;

  addEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    if (type === "click") this.clickListener = listener as (event: MouseEvent) => void;
    if (type === "input") this.inputListener = listener as (event: Event) => void;
    if (type === "keydown") this.keydownListener = listener as (event: KeyboardEvent) => void;
    if (type === "pointerdown") {
      this.pointerDownListener = listener as (event: PointerEvent) => void;
    }
  }

  removeEventListener(type: string, listener: EventListenerOrEventListenerObject): void {
    if (type === "click" && this.clickListener === listener) this.clickListener = null;
    if (type === "input" && this.inputListener === listener) this.inputListener = null;
    if (type === "keydown" && this.keydownListener === listener) this.keydownListener = null;
    if (type === "pointerdown" && this.pointerDownListener === listener) {
      this.pointerDownListener = null;
    }
  }

  clickAction(action: string): void {
    this.clickListener?.({
      preventDefault: () => undefined,
      target: {
        closest: () => ({
          getAttribute: (name: string) => (name === "data-chat-action" ? action : null),
        }),
      },
    } as unknown as MouseEvent);
  }

  clickScope(scope: string): void {
    this.clickListener?.({
      preventDefault: () => undefined,
      target: {
        closest: () => ({
          getAttribute: (name: string) => (name === "data-chat-scope" ? scope : null),
        }),
      },
    } as unknown as MouseEvent);
  }

  inputMessage(value: string): void {
    this.inputListener?.({
      target: {
        value,
        getAttribute: (name: string) => (name === "data-chat-input" ? "message" : null),
      },
    } as unknown as Event);
  }

  keyDownMessage(key: string): { stopped: boolean; prevented: boolean } {
    let stopped = false;
    let prevented = false;
    this.keydownListener?.({
      key,
      shiftKey: false,
      stopPropagation: () => {
        stopped = true;
      },
      preventDefault: () => {
        prevented = true;
      },
      target: {
        value: "draft",
        getAttribute: (name: string) => (name === "data-chat-input" ? "message" : null),
      },
    } as unknown as KeyboardEvent);
    return { stopped, prevented };
  }

  pointerDown(): boolean {
    let stopped = false;
    this.pointerDownListener?.({
      stopPropagation: () => {
        stopped = true;
      },
    } as unknown as PointerEvent);
    return stopped;
  }
}

class FakeCommands implements ChatPanelCommandPort {
  readonly calls: Array<{ command: string; args: string[]; source?: string }> = [];

  executeCliCommand(command: string, args: string[], source?: string): CliCommandResult {
    this.calls.push(source === undefined ? { command, args } : { command, args, source });
    return { ok: true, command, text: `chat ${args[0]} sent request=61`, data: { args } };
  }
}

describe("ChatPanelView", () => {
  it("renders scope selection, recent messages, and CLI-compatible chat hint", () => {
    const html = renderChatPanelHtml(
      {
        scope: "local",
        draft: "hi",
        messages: [{ cid: 42, username: "tester", text: "hello world" }],
      },
      null,
    );

    expect(html).toContain("World Chat");
    expect(html).toContain('data-chat-scope="world"');
    expect(html).toContain('data-chat-scope="region"');
    expect(html).toContain('data-chat-scope="local"');
    expect(html).toContain("is-selected");
    expect(html).toContain("tester");
    expect(html).toContain("hello world");
    expect(html).toContain("window.__voxelCli?.run(&quot;chat region hello&quot;)");
  });

  it("sends through the shared CLI command port and keeps clicks out of world editing", () => {
    const root = new FakeChatPanelRoot();
    const commands = new FakeCommands();
    const view = new ChatPanelView(root as unknown as HTMLDivElement, commands);

    root.clickScope("region");
    root.inputMessage("hello region");
    root.clickAction("send");

    expect(commands.calls).toEqual([
      { command: "chat", args: ["region", "hello region"], source: "chat_panel" },
    ]);
    expect(root.innerHTML).toContain("chat region sent request=61");
    expect(root.pointerDown()).toBe(true);

    view.dispose();
    root.inputMessage("after dispose");
    root.clickAction("send");
    expect(commands.calls).toHaveLength(1);
  });

  it("keeps chat input keyboard events out of world movement controls", () => {
    const root = new FakeChatPanelRoot();
    const commands = new FakeCommands();
    const view = new ChatPanelView(root as unknown as HTMLDivElement, commands);

    expect(root.keyDownMessage("w")).toEqual({ stopped: true, prevented: false });
    expect(root.keyDownMessage("Enter")).toEqual({ stopped: true, prevented: true });

    view.dispose();
  });

  it("appends server-delivered messages without inventing client-side channel authority", () => {
    const root = new FakeChatPanelRoot();
    const commands = new FakeCommands();
    const view = new ChatPanelView(root as unknown as HTMLDivElement, commands);
    const delivered: ChatMessage = { cid: 42, username: "tester", text: "server delivered" };

    view.appendMessage(delivered);

    expect(root.innerHTML).toContain("tester");
    expect(root.innerHTML).toContain("server delivered");
    expect(root.innerHTML).not.toContain("region_id");

    view.dispose();
  });
});
