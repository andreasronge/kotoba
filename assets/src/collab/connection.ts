import type { Channel } from "phoenix";
import type { CollabCredentials } from "../collaboration";
import type { Lease } from "./sockets";

/**
 * The channel of one shared editor, as a state machine. Every event (demand, socket, renewal,
 * join reply, channel error, timer) goes through `update()` or one transition, and only this
 * class opens or closes the channel: Phoenix never retries by itself, since its retries would
 * reuse the credentials.
 *
 * - idle: no channel, none wanted (or the next step is decided in `update()`)
 * - waiting: wanted, the socket is down; its reopening calls `update()`
 * - renewing: credentials are being renewed before a join
 * - joining / joined: a channel
 * - backoff: a retry after 1 s, doubling to 30 s until a join
 * - frozen: refused or disposed; nothing more
 */
export type ConnectionState = "idle" | "waiting" | "renewing" | "joining" | "joined" | "backoff" | "frozen";

export interface ConnectionEvents {
  /** Join parameters besides the token. */
  params(): Record<string, unknown>;
  /** Whether a channel is wanted: always for an eager editor, else on screen, focused or with work. */
  demand(): boolean;
  joined(payload: unknown): void;
  /** A joining or joined channel went away (errors, timeouts, a socket going down). */
  lost(): void;
  /** The state changed (the editor's status follows it). */
  changed(): void;
  transaction(payload: unknown): void;
  presence(payload: unknown): void;
  /** Access was refused: the editor freezes its draft. */
  refused(message: string): void;
}

export const ACCESS_REFUSED = "Access to this shared document is unavailable. Your local draft is preserved.";
// The hook's renewal rejects with this when nobody answered; anything else is a refusal.
const UNANSWERED = "Collaboration credentials could not be renewed";
const STALE_AFTER = 240_000;

export class Connection {
  private current: ConnectionState = "idle";
  channel: Channel | null = null;
  private credentialsAt = Date.now();
  // The server refused these credentials as expired: they never join again.
  private expired = false;
  private backoff = 0;
  private renewing: Promise<void> | null = null;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private parkTimer: ReturnType<typeof setTimeout> | undefined;
  private readonly renewal: ReturnType<typeof setInterval>;
  private readonly socketRefs: string[];
  // The page's socket disconnects itself when the browser goes offline, without close callbacks.
  private readonly offline = (): void => { if (this.channel) this.drop(); };

  constructor(
    private readonly lease: Lease,
    private readonly topic: string,
    private credentials: CollabCredentials,
    private readonly fetchCredentials: () => Promise<CollabCredentials>,
    // null: an eager editor, which never parks.
    private readonly parkAfter: number | null,
    private readonly events: ConnectionEvents,
  ) {
    // The socket going down (a clean close errors no channel) drops the channel; its reopening
    // decides again.
    this.socketRefs = [
      lease.socket.onOpen(() => this.update()),
      lease.socket.onClose(() => { if (this.channel) this.drop(); }),
    ];
    window.addEventListener("offline", this.offline);
    // Joined credentials are kept fresh; a refusal freezes the draft.
    this.renewal = setInterval(() => {
      if (this.current === "joined") this.renew().catch((error: unknown) => { if (!unanswered(error)) this.freeze(ACCESS_REFUSED); });
    }, 180_000);
  }

  get state(): ConnectionState { return this.current; }
  get joined(): boolean { return this.current === "joined"; }

  // Every transition, so that the editor's status follows the state.
  private set(state: ConnectionState): void {
    if (this.current === state) return;
    this.current = state;
    this.events.changed();
  }

  /** Moves toward what the editor wants now. Safe to call at any time. */
  update(): void {
    switch (this.current) {
      case "idle":
      case "waiting":
        if (!this.events.demand()) { this.set("idle"); return; }
        this.go();
        return;
      case "joined":
        this.schedulePark();
        return;
      default:
        // renewing, joining and backoff go on by their own outcome; frozen stays.
        return;
    }
  }

  /** A new channel now (a missed revision, an unanswered transaction): rejoins with the latest snapshot. */
  reset(): void {
    if (this.current === "frozen") return;
    if (this.channel) { this.teardown(); this.events.lost(); }
    this.set("idle");
    this.update();
  }

  updateCredentials(credentials: CollabCredentials): void {
    if (credentials.document_id !== this.credentials.document_id || credentials.user.id !== this.credentials.user.id || credentials.socket !== this.credentials.socket) throw new Error("Collaboration identity cannot change while mounted");
    this.credentials = credentials;
    this.credentialsAt = Date.now();
  }

  /** Stops for good; with a message, the editor is told (a refusal). */
  freeze(message?: string): void {
    if (this.current === "frozen") return;
    this.set("frozen");
    this.teardown();
    clearTimeout(this.timer);
    clearTimeout(this.parkTimer);
    if (message) this.events.refused(message);
  }

  dispose(): void {
    this.freeze();
    clearInterval(this.renewal);
    this.lease.socket.off(this.socketRefs);
    window.removeEventListener("offline", this.offline);
    this.lease.release();
  }

  private stale(): boolean { return this.expired || Date.now() - this.credentialsAt > STALE_AFTER; }

  // Wanted: join, once the socket is up and with fresh credentials.
  private go(): void {
    // Phoenix would buffer a join with these credentials and send it before anything could
    // renew them: the socket's reopening calls update() instead.
    if (!this.lease.socket.isConnected()) { this.set("waiting"); return; }
    if (this.stale()) { this.renewThenJoin(); return; }
    this.join();
  }

  private renewThenJoin(): void {
    this.set("renewing");
    this.renew().then(() => {
      if (this.current !== "renewing") return;
      this.expired = false;
      this.set("idle");
      this.update();
    }, (error: unknown) => {
      if (this.current !== "renewing") return;
      if (!unanswered(error)) { this.freeze(ACCESS_REFUSED); return; }
      // No answer: refused credentials wait and try again; old ones may still be good.
      if (this.expired) { this.wait(); return; }
      this.set("idle");
      if (!this.events.demand()) return;
      if (this.lease.socket.isConnected()) this.join(); else this.set("waiting");
    });
  }

  // One renewal at a time.
  private renew(): Promise<void> {
    this.renewing ??= this.fetchCredentials().then(credentials => this.updateCredentials(credentials)).finally(() => { this.renewing = null; });
    return this.renewing;
  }

  private join(): void {
    clearTimeout(this.parkTimer);
    this.parkTimer = undefined;
    const channel = this.lease.socket.channel(this.topic, () => ({ ...this.events.params(), token: this.credentials.token }));
    this.channel = channel;
    this.set("joining");
    const current = (): boolean => this.channel === channel;
    channel.on("transaction", payload => { if (current()) this.events.transaction(payload); });
    channel.on("presence", payload => { if (current()) this.events.presence(payload); });
    channel.onError(() => { if (current()) this.drop(); });
    channel.onClose(() => { if (current()) this.drop(); });
    channel.join()
      .receive("ok", payload => {
        if (!current()) return;
        this.set("joined");
        this.backoff = 0;
        this.events.joined(payload);
        this.update();
      })
      .receive("error", payload => {
        if (!current()) return;
        if ((payload as { reason?: string }).reason !== "expired") { this.freeze(ACCESS_REFUSED); return; }
        // Refused again right after a renewal (a cached token, clocks apart): the backoff paces it.
        const renewed = Date.now() - this.credentialsAt < 10_000;
        this.expired = true;
        this.teardown();
        this.events.lost();
        if (renewed) this.wait(); else this.update();
      })
      .receive("timeout", () => { if (current()) { this.teardown(); this.events.lost(); this.wait(); } });
  }

  // The channel failed or the socket went down: the channel is left (no Phoenix retry) and the
  // next step decided here.
  private drop(): void {
    this.teardown();
    this.events.lost();
    if (this.lease.socket.isConnected()) this.wait(); else this.update();
  }

  private teardown(): void {
    const channel = this.channel;
    this.channel = null;
    if (this.current !== "frozen") this.set("idle");
    channel?.leave();
  }

  private wait(): void {
    this.backoff = Math.min(this.backoff ? this.backoff * 2 : 1_000, 30_000);
    this.set("backoff");
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      if (this.current !== "backoff") return;
      this.set("idle");
      this.update();
    }, this.backoff);
  }

  // A joined channel nobody wants is left after park_after.
  private schedulePark(): void {
    if (this.parkAfter === null) return;
    if (this.events.demand()) { clearTimeout(this.parkTimer); this.parkTimer = undefined; return; }
    if (this.parkTimer !== undefined) return;
    this.parkTimer = setTimeout(() => {
      this.parkTimer = undefined;
      if (this.current !== "joined") return;
      if (this.events.demand()) return;
      this.teardown();
    }, this.parkAfter);
  }
}

function unanswered(error: unknown): boolean { return error instanceof Error && error.message === UNANSWERED; }
