import { DEFAULT_MOVEMENT_PROFILE } from "./profile";

describe("DEFAULT_MOVEMENT_PROFILE", () => {
  it("matches the authoritative SceneServer movement defaults", () => {
    expect(DEFAULT_MOVEMENT_PROFILE).toEqual({
      fixedDtMs: 100,
      maxSpeed: 220,
      maxAccel: 1200,
      maxDecel: 1400,
      maxJerk: 9000,
    });
  });
});
