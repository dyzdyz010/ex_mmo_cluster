import {
  cloneMoveInputFrame,
  clonePredictedMoveState,
  type MoveInputFrame,
  type PredictedMoveState,
} from "./types";

export class InputHistory {
  private readonly frames: MoveInputFrame[] = [];

  constructor(private readonly capacity: number) {}

  push(frame: MoveInputFrame): void {
    this.frames.push(cloneMoveInputFrame(frame));
    if (this.frames.length > this.capacity) {
      this.frames.splice(0, this.frames.length - this.capacity);
    }
  }

  dropThroughTick(authTick: number): void {
    while ((this.frames[0]?.clientTick ?? Number.POSITIVE_INFINITY) <= authTick) {
      this.frames.shift();
    }
  }

  dropThroughSeq(ackSeq: number): void {
    while ((this.frames[0]?.seq ?? Number.POSITIVE_INFINITY) <= ackSeq) {
      this.frames.shift();
    }
  }

  framesAfterTick(tick: number): MoveInputFrame[] {
    return this.frames.filter((frame) => frame.clientTick > tick).map(cloneMoveInputFrame);
  }

  framesAfterSeq(seq: number): MoveInputFrame[] {
    return this.frames.filter((frame) => frame.seq > seq).map(cloneMoveInputFrame);
  }

  retainRecent(limit: number): void {
    if (this.frames.length > limit) {
      this.frames.splice(0, this.frames.length - limit);
    }
  }

  clear(): void {
    this.frames.splice(0, this.frames.length);
  }

  len(): number {
    return this.frames.length;
  }
}

export class PredictedHistory {
  private readonly states: PredictedMoveState[] = [];

  constructor(private readonly capacity: number) {}

  push(state: PredictedMoveState): void {
    this.states.push(clonePredictedMoveState(state));
    if (this.states.length > this.capacity) {
      this.states.splice(0, this.states.length - this.capacity);
    }
  }

  stateAtTick(tick: number): PredictedMoveState | null {
    const state = this.findLatest((candidate) => candidate.tick === tick);
    return state ? clonePredictedMoveState(state) : null;
  }

  stateAtSeq(seq: number): PredictedMoveState | null {
    if (seq === 0) {
      return null;
    }
    const state = this.findLatest((candidate) => candidate.seq === seq);
    return state ? clonePredictedMoveState(state) : null;
  }

  replaceFromTick(tick: number, state: PredictedMoveState): void {
    while ((this.states.at(-1)?.tick ?? Number.NEGATIVE_INFINITY) >= tick) {
      this.states.pop();
    }
    this.push(state);
  }

  truncateAfterTick(tick: number): void {
    while ((this.states.at(-1)?.tick ?? Number.NEGATIVE_INFINITY) > tick) {
      this.states.pop();
    }
  }

  truncateAfterSeq(seq: number): void {
    while ((this.states.at(-1)?.seq ?? Number.NEGATIVE_INFINITY) > seq) {
      this.states.pop();
    }
  }

  latest(): PredictedMoveState | null {
    const state = this.states.at(-1);
    return state ? clonePredictedMoveState(state) : null;
  }

  clear(): void {
    this.states.splice(0, this.states.length);
  }

  private findLatest(predicate: (state: PredictedMoveState) => boolean): PredictedMoveState | null {
    for (let index = this.states.length - 1; index >= 0; index -= 1) {
      const state = this.states[index];
      if (state && predicate(state)) {
        return state;
      }
    }
    return null;
  }
}
