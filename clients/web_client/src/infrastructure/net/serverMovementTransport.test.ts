import { describe, expect, it } from "vitest";
import {
  resolveAuthBaseUrl,
  resolveDefaultUsername,
  resolveGameWsUrl,
} from "./serverMovementTransport";

const viteDevLocation = {
  protocol: "http:",
  host: "127.0.0.1:5173",
  origin: "http://127.0.0.1:5173",
};

describe("server movement transport runtime config", () => {
  it("honors explicit VITE_GAME_* endpoint overrides", () => {
    const env = {
      VITE_GAME_AUTH_BASE_URL: "http://127.0.0.1:20000",
      VITE_AUTH_BASE_URL: "http://wrong.example.test",
      VITE_GAME_WS_URL: "ws://127.0.0.1:20000/ingame/ws",
      VITE_WS_URL: "ws://wrong.example.test/ingame/ws",
      VITE_GAME_CLIENT_USERNAME: "alice",
      VITE_GAME_USERNAME: "legacy_alice",
    };

    expect(resolveAuthBaseUrl(env, viteDevLocation)).toBe("http://127.0.0.1:20000");
    expect(resolveGameWsUrl(env, viteDevLocation)).toBe("ws://127.0.0.1:20000/ingame/ws");
    expect(resolveDefaultUsername(env, null)).toBe("alice");
  });

  it("keeps legacy env names working for manual npm runs", () => {
    const env = {
      VITE_AUTH_BASE_URL: "http://127.0.0.1:20000",
      VITE_WS_URL: "ws://127.0.0.1:20000/ingame/ws",
      VITE_GAME_USERNAME: "manual_user",
    };

    expect(resolveAuthBaseUrl(env, viteDevLocation)).toBe("http://127.0.0.1:20000");
    expect(resolveGameWsUrl(env, viteDevLocation)).toBe("ws://127.0.0.1:20000/ingame/ws");
    expect(resolveDefaultUsername(env, null)).toBe("manual_user");
  });

  it("uses the Vite /ingame proxy when auth env mapping is absent", () => {
    expect(resolveAuthBaseUrl({}, viteDevLocation)).toBe("");
    expect(resolveGameWsUrl({}, viteDevLocation)).toBe("ws://127.0.0.1:5173/ingame/ws");
  });
});
