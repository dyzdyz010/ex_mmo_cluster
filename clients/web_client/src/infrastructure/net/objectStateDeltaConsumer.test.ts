import { describe, expect, it, vi } from "vitest";

import type { ObjectStateDelta } from "./objectStateDelta";
import {
  ObjectStateDeltaConsumer,
  ObjectStateFlag,
  describeObjectStateFlag,
} from "./objectStateDeltaConsumer";

function buildDelta(overrides: Partial<ObjectStateDelta> = {}): ObjectStateDelta {
  return {
    logicalSceneId: 1n,
    objectId: 42n,
    objectVersion: 1n,
    stateFlags: 0,
    attributePatchCount: 0,
    tagPatchCount: 0,
    affectedChunks: [{ x: 0, y: 0, z: 0 }],
    ...overrides,
  };
}

describe("describeObjectStateFlag", () => {
  it("maps known flag bits to canonical names", () => {
    expect(describeObjectStateFlag(ObjectStateFlag.Damaged)).toBe("damaged");
    expect(describeObjectStateFlag(ObjectStateFlag.PartDestroyed)).toBe("part_destroyed");
    expect(describeObjectStateFlag(ObjectStateFlag.Destroyed)).toBe("destroyed");
  });

  it("prefers destroyed > part_destroyed > damaged when bits combine", () => {
    expect(
      describeObjectStateFlag(
        ObjectStateFlag.Damaged | ObjectStateFlag.PartDestroyed | ObjectStateFlag.Destroyed,
      ),
    ).toBe("destroyed");

    expect(
      describeObjectStateFlag(ObjectStateFlag.Damaged | ObjectStateFlag.PartDestroyed),
    ).toBe("part_destroyed");
  });

  it("returns 'unknown' for empty / unknown bit patterns", () => {
    expect(describeObjectStateFlag(0)).toBe("unknown");
    expect(describeObjectStateFlag(0xff00)).toBe("unknown");
  });
});

describe("ObjectStateDeltaConsumer", () => {
  it("forwards a fresh delta and records last_seen_version", () => {
    const onDelta = vi.fn();
    const consumer = new ObjectStateDeltaConsumer({ onDelta });

    const delta = buildDelta({
      objectId: 100n,
      objectVersion: 5n,
      stateFlags: ObjectStateFlag.Damaged,
    });

    expect(consumer.consume(delta)).toBe(true);
    expect(onDelta).toHaveBeenCalledWith(delta, "damaged");
    expect(consumer.knownObjectVersion(100n)).toBe(5n);
  });

  it("dedupes a stale (lower-or-equal) version for the same object", () => {
    const onDelta = vi.fn();
    const onDuplicate = vi.fn();
    const consumer = new ObjectStateDeltaConsumer({ onDelta, onDuplicate });

    const first = buildDelta({ objectId: 1n, objectVersion: 7n });
    const sameVersion = buildDelta({ objectId: 1n, objectVersion: 7n });
    const olderVersion = buildDelta({ objectId: 1n, objectVersion: 6n });

    expect(consumer.consume(first)).toBe(true);
    expect(consumer.consume(sameVersion)).toBe(false);
    expect(consumer.consume(olderVersion)).toBe(false);

    expect(onDelta).toHaveBeenCalledTimes(1);
    expect(onDuplicate).toHaveBeenCalledTimes(2);
  });

  it("tracks each object_id independently", () => {
    const onDelta = vi.fn();
    const consumer = new ObjectStateDeltaConsumer({ onDelta });

    consumer.consume(buildDelta({ objectId: 1n, objectVersion: 5n }));
    consumer.consume(buildDelta({ objectId: 2n, objectVersion: 1n }));

    expect(onDelta).toHaveBeenCalledTimes(2);
    expect(consumer.knownObjectVersion(1n)).toBe(5n);
    expect(consumer.knownObjectVersion(2n)).toBe(1n);
  });

  it("admits a higher version after a lower version", () => {
    const onDelta = vi.fn();
    const consumer = new ObjectStateDeltaConsumer({ onDelta });

    consumer.consume(buildDelta({ objectId: 1n, objectVersion: 1n }));
    expect(consumer.consume(buildDelta({ objectId: 1n, objectVersion: 2n }))).toBe(true);
    expect(consumer.knownObjectVersion(1n)).toBe(2n);
  });

  it("reset clears dedupe state", () => {
    const onDelta = vi.fn();
    const consumer = new ObjectStateDeltaConsumer({ onDelta });

    consumer.consume(buildDelta({ objectId: 1n, objectVersion: 7n }));
    expect(consumer.consume(buildDelta({ objectId: 1n, objectVersion: 7n }))).toBe(false);

    consumer.reset();

    expect(consumer.knownObjectVersion(1n)).toBeUndefined();
    expect(consumer.consume(buildDelta({ objectId: 1n, objectVersion: 7n }))).toBe(true);
  });

  it("invokes the default console.log hook when no onDelta is provided", () => {
    const consumer = new ObjectStateDeltaConsumer();
    const spy = vi.spyOn(console, "log").mockImplementation(() => undefined);

    expect(
      consumer.consume(
        buildDelta({ objectId: 9n, objectVersion: 1n, stateFlags: ObjectStateFlag.Destroyed }),
      ),
    ).toBe(true);

    expect(spy).toHaveBeenCalled();
    spy.mockRestore();
  });

  it("describes part_destroyed bit alone", () => {
    const onDelta = vi.fn();
    const consumer = new ObjectStateDeltaConsumer({ onDelta });

    consumer.consume(
      buildDelta({ objectId: 1n, objectVersion: 1n, stateFlags: ObjectStateFlag.PartDestroyed }),
    );

    expect(onDelta).toHaveBeenCalledWith(expect.anything(), "part_destroyed");
  });
});
