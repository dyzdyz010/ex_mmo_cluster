import type { Vector3 } from "three";
import { describe, expect, it } from "vitest";
import type { MovementTransport, MovementTransportTickResult } from "@domain/movement/transport";
import type { MoveInputFrame } from "@domain/movement/types";
import type { ChatMessage, ChatScope } from "../../domain/chat/types";
import { EventBus } from "../../shared/events/eventBus";
import type { AppEvents } from "../../shared/events/events";
import { TransportPump } from "./transportPump";

class FakeChatTransport implements MovementTransport {
  readonly mode = "server-ws";
  readonly sent: Array<{ scope: ChatScope; text: string }> = [];
  readonly chatMessages: ChatMessage[] = [];

  isReady(): boolean {
    return true;
  }

  debugSnapshot(): Record<string, unknown> {
    return {};
  }

  reset(_position: Vector3): void {}

  sendInput(_frame: MoveInputFrame, _nowMs: number): void {}

  tick(_nowMs: number, _dtMs: number): MovementTransportTickResult {
    return { acknowledgements: [], remoteSnapshots: [], spawn: null };
  }

  sendChat(scope: ChatScope, text: string): number | null {
    this.sent.push({ scope, text });
    return 51;
  }

  drainChatMessages(): ChatMessage[] {
    return this.chatMessages.splice(0, this.chatMessages.length);
  }
}

describe("TransportPump chat bridge", () => {
  it("delegates scoped chat sends and publishes server-delivered chat messages", () => {
    const transport = new FakeChatTransport();
    const bus = new EventBus<AppEvents>();
    const delivered: ChatMessage[] = [];
    bus.on("chat:message-received", (message) => delivered.push(message));
    const pump = new TransportPump(transport, bus);

    expect(pump.sendChat("region", "hello region")).toBe(51);
    expect(transport.sent).toEqual([{ scope: "region", text: "hello region" }]);

    transport.chatMessages.push({
      cid: 42,
      username: "tester",
      text: "server delivered",
    });
    pump.onFrame(0, 16);

    expect(delivered).toEqual([
      {
        cid: 42,
        username: "tester",
        text: "server delivered",
      },
    ]);
    expect(transport.chatMessages).toEqual([]);
  });
});
