export type ChatScope = "world" | "region" | "local";

export interface ChatMessage {
  cid: number;
  username: string;
  text: string;
}

export function isChatScope(value: string | null | undefined): value is ChatScope {
  return value === "world" || value === "region" || value === "local";
}
