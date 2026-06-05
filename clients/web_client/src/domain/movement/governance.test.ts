import { describe, expect, it } from "vitest";
import { DEFAULT_REPLAY_GOVERNANCE, effectiveSoftPositionError } from "./governance";

describe("movement replay governance", () => {
  it("uses a soft correction band wide enough to avoid jittery local pullback", () => {
    expect(DEFAULT_REPLAY_GOVERNANCE.baseSoftPositionError).toBeGreaterThanOrEqual(8);
    expect(DEFAULT_REPLAY_GOVERNANCE.maxSoftPositionError).toBeGreaterThanOrEqual(32);
    expect(effectiveSoftPositionError(DEFAULT_REPLAY_GOVERNANCE, 400)).toBe(
      DEFAULT_REPLAY_GOVERNANCE.maxSoftPositionError,
    );
  });
});
