import type { LexicalEditor } from "lexical";
import type { ExtensionAPI } from "./extensions";
import type { SubmitParticipant } from "./forms";

export interface CollabCredentials {
  document_id: string;
  token: string;
  socket: string;
  role: "read" | "write";
  user: { id: string; name: string; color: string };
  /** "visible": join while on screen, focused or sending; leave after `park_after` ms off screen and idle. */
  join?: "eager" | "visible";
  park_after?: number;
}

/** A shared editor's client; its form's submit coordinator flushes and locks it. */
export interface Collaboration extends SubmitParticipant {
  readonly: boolean;
  flush(): Promise<{ epoch: string; revision: number }>;
  /** Resolves after the first join (joining now if needed): the editor holds the shared document. */
  whenJoined(): Promise<void>;
  updateCredentials(credentials: CollabCredentials): void;
  /** Puts its status on the editor again (a LiveView patch replaces the element's data attributes). */
  showStatus(): void;
  dispose(): void;
}

export interface CollaborationHost {
  editor: LexicalEditor;
  api: ExtensionAPI;
  element: HTMLElement;
  surface: HTMLElement;
  editable: HTMLElement;
  credentials: CollabCredentials;
  initialReadonly: boolean;
  announce(message: string): void;
  setReadonly(value: boolean): void;
  refreshCredentials(): Promise<CollabCredentials>;
  readDocument(): unknown;
}

type Factory = (host: CollaborationHost) => Promise<Collaboration>;
let factory: Factory | null = null;

/** The optional bundle receives the editor's own Lexical through this boundary. */
export function registerCollaboration(implementation: Factory): void { factory = implementation; }

export function attachCollaboration(host: CollaborationHost): Promise<Collaboration> {
  if (factory === null) throw new Error("Kotoba collaboration needs enableCollaboration(registerCollaboration) in app.js");
  return factory(host);
}

export function readCollabCredentials(json: string | undefined): CollabCredentials | null {
  if (!json) return null;
  const data = JSON.parse(json) as CollabCredentials;
  if (!data || typeof data.document_id !== "string" || typeof data.token !== "string" || typeof data.socket !== "string" || !["read", "write"].includes(data.role) || typeof data.user?.id !== "string" || !["eager", "visible", undefined].includes(data.join) || !["number", "undefined"].includes(typeof data.park_after)) throw new Error("Invalid Kotoba collaboration credentials");
  return data;
}
