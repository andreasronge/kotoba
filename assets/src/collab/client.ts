import type { Collaboration, CollaborationHost, CollabCredentials } from "../collaboration";
import { Binding, COLLAB_TAG, redo, type Change } from "./binding";
import { Connection } from "./connection";
import { apply, clone, equal, envelope, uuid, type Operation, type State, type Transaction } from "./model";
import { Persistence } from "./persistence";
import { Presence, type Person } from "./presence";
import { lease } from "./sockets";

interface Join { state: State; role: "read" | "write"; people: Person[]; accepted: string[] }
type Waiter = { resolve: () => void; reject: (reason: Error) => void };

const RECONNECT = "Reconnect before saving this form";

class Client implements Collaboration {
  private readRole: boolean;
  // Writing through the channel is not possible: a reader, a frozen draft, or not joined yet.
  private get blocked(): boolean { return this.readRole || this.failure !== null || this.accepted === null; }
  // For the editor's UI: also read-only while a form submit holds the editor.
  get readonly(): boolean { return this.blocked || this.locked; }
  get closed(): boolean { return this.disposed; }
  private readonly persistence: Persistence;
  private readonly binding: Binding;
  private readonly connection: Connection;
  private readonly presence: Presence;
  private readonly bar: HTMLDivElement;
  private readonly status: HTMLOutputElement;
  private readonly recover: HTMLButtonElement;
  private readonly revisionInput: HTMLInputElement;
  private readonly cleanups: (() => void)[] = [];
  private accepted: State | null = null;
  private view: State | null = null;
  private pending: Transaction[] = [];
  private sent = new Set<string>();
  private undoStack: Change[] = [];
  private redoStack: Change[] = [];
  private lastEdit = 0;
  private disposed = false;
  private inFlight: string | null = null;
  private failure: string | null = null;
  private recoveryDraft: unknown;
  private localBackup = true;
  private persistenceChain = Promise.resolve();
  private awarenessTimer: ReturnType<typeof setTimeout> | undefined;
  private lastAwareness = "";
  private sendTimer: ReturnType<typeof setTimeout> | undefined;
  // `join: "visible"`: a channel is wanted while the editor is on screen, focused or has work.
  private readonly lazy: boolean;
  private visible = false;
  private focused = false;
  // Waiting for every pending transaction to be accepted (a flush).
  private drained: Waiter[] = [];
  // Waiting for a join (a flush, an insert before the first join).
  private joins: Waiter[] = [];
  private flushing = 0;
  private everJoined = false;
  // Started: before, nothing joins (the local backup decides the session and pending edits).
  private running = false;
  // A form submit holds the editor read-only until every editor of the form has flushed.
  private locked = false;
  private editableBeforeLock = false;
  private markStarted: () => void = () => {};
  private readonly started = new Promise<void>(resolve => { this.markStarted = resolve; });

  constructor(private readonly host: CollaborationHost) {
    const credentials = host.credentials;
    this.readRole = credentials.role === "read";
    this.lazy = credentials.join === "visible";
    this.persistence = new Persistence(credentials.socket, credentials.document_id, credentials.user.id);
    this.binding = new Binding(host);
    this.bar = document.createElement("div");
    this.bar.className = "kotoba-collab-bar";
    this.status = document.createElement("output");
    this.status.dataset.collabStatus = "";
    this.status.setAttribute("aria-live", "polite");
    this.status.textContent = "Connecting…";
    this.recover = document.createElement("button");
    this.recover.type = "button";
    this.recover.textContent = "Download local draft";
    this.recover.hidden = true;
    this.recover.addEventListener("click", () => this.download());
    this.bar.append(this.status, this.recover);
    host.element.prepend(this.bar);
    this.presence = new Presence(host, this.binding, () => this.persistence.session, this.bar);
    this.revisionInput = document.createElement("input");
    this.revisionInput.type = "hidden";
    this.revisionInput.name = `kotoba_collab[${host.element.id}]`;
    host.element.append(this.revisionInput);
    const topic = `kotoba:${credentials.document_id}`;
    this.connection = new Connection(lease(credentials.socket, topic), topic, credentials, () => host.refreshCredentials(), this.lazy ? credentials.park_after ?? 30_000 : null, {
      params: () => ({ session: this.persistence.session, pending: this.pending.map(transaction => transaction.id) }),
      demand: () => this.demand(),
      joined: payload => this.joined(payload as Join),
      lost: () => this.offline(),
      changed: () => { if (!this.connection.joined) this.presence.offline(); this.showStatus(); },
      transaction: payload => this.receive(payload as Transaction),
      presence: payload => this.presence.receive((payload as { people: Person[] }).people),
      refused: message => this.fail(message),
    });
    // At once: the hook can dispose an editor removed while it starts.
    (host.element as HTMLElement & { kotobaCollab?: Collaboration }).kotobaCollab = this;
  }

  // The one place that decides whether a channel is wanted: an eager editor always; a lazy one
  // on screen or focused (in a tab that is not hidden), or with work to send, confirm or wait for.
  private demand(): boolean {
    if (this.failure || this.disposed || !this.running) return false;
    if (!this.lazy) return true;
    const wanted = document.visibilityState !== "hidden" && (this.visible || this.focused);
    return wanted || this.pending.length > 0 || this.inFlight !== null || this.drained.length > 0 || this.joins.length > 0 || this.flushing > 0;
  }

  async start(): Promise<void> {
    this.host.setReadonly(true);
    try {
      const backup = await this.persistence.open();
      if (backup?.state.v === 1 && backup.state.schema === 1) {
        this.accepted = backup.state;
        this.pending = backup.pending;
        this.sent = new Set(backup.sent ?? backup.pending.map(transaction => transaction.id));
        this.render(false);
        this.applyReadonly();
      }
    } catch { this.localBackup = false; }
    // Removed while its backup opened: release the session and database it got meanwhile.
    if (this.disposed) { this.persistence.close(); return; }
    const api = this.host.api.lexical;
    this.cleanups.push(this.host.editor.registerUpdateListener(({ tags, dirtyElements, dirtyLeaves }) => {
      // Not `readonly`: a server insert during a form submit is captured too.
      if (tags.has(COLLAB_TAG) || !this.view || this.blocked || (dirtyElements.size === 0 && dirtyLeaves.size === 0)) return;
      const change = this.binding.capture(this.view);
      if (!change) { this.awareness(); return; }
      const isTyping = (op: Operation): boolean => op.op === "insert_text" || op.op === "text_visibility" || (op.op === "insert_node" && op.data.type === "text") || op.op === "set_attrs";
      const typing = change.forward.some(op => op.op === "insert_text") && change.forward.every(isTyping);
      const last = this.undoStack[this.undoStack.length - 1];
      if (typing && last && Date.now() - this.lastEdit < 300 && last.forward.every(isTyping)) {
        (last.forward as Operation[]).push(...change.forward);
        last.inverse.unshift(...change.inverse);
      } else this.undoStack.push(change);
      this.lastEdit = Date.now();
      this.redoStack = [];
      this.enqueue(change.forward, false);
      this.historyState();
    }));
    this.cleanups.push(this.host.editor.registerCommand(api.UNDO_COMMAND, () => this.history(false), api.COMMAND_PRIORITY_CRITICAL));
    this.cleanups.push(this.host.editor.registerCommand(api.REDO_COMMAND, () => this.history(true), api.COMMAND_PRIORITY_CRITICAL));
    this.cleanups.push(this.host.editor.registerCommand(api.SELECTION_CHANGE_COMMAND, () => { this.awareness(); return false; }, api.COMMAND_PRIORITY_LOW));
    const status = (): void => this.showStatus();
    window.addEventListener("offline", status);
    window.addEventListener("online", status);
    this.cleanups.push(() => { window.removeEventListener("offline", status); window.removeEventListener("online", status); });
    if (this.lazy) this.watchVisibility();
    this.running = true;
    this.showStatus();
    this.connection.update();
    const compositionEnd = (): void => { setTimeout(() => { if (!this.disposed && !this.failure) { this.render(); this.send(); this.awareness(); } }, 0); };
    this.host.editable.addEventListener("compositionend", compositionEnd);
    this.cleanups.push(() => this.host.editable.removeEventListener("compositionend", compositionEnd));
    this.markStarted();
  }

  private watchVisibility(): void {
    const element = this.host.element;
    // Near the screen: within 200 px of the viewport and of every box that clips the editor,
    // on each axis an ancestor clips (its computed overflow there is not visible; read at each
    // measure, as styles change). The observer is not enough alone (a page that renders no
    // frames, as headless WebKit under load, gets no callback and no scroll events), so
    // scrolling, resizing and a timer every second also measure the editor; measuring needs no
    // frame.
    let measured = false;
    const measure = (): void => {
      const box = element.getBoundingClientRect();
      let top = -200, left = -200, bottom = window.innerHeight + 200, right = window.innerWidth + 200;
      for (let parent = element.parentElement; parent; parent = parent.parentElement) {
        const style = getComputedStyle(parent);
        const across = style.overflowX !== "visible", down = style.overflowY !== "visible";
        if (!across && !down) continue;
        const clip = parent.getBoundingClientRect();
        if (across) { left = Math.max(left, clip.left - 200); right = Math.min(right, clip.right + 200); }
        if (down) { top = Math.max(top, clip.top - 200); bottom = Math.min(bottom, clip.bottom + 200); }
      }
      const near = top <= bottom && left <= right && (box.width > 0 || box.height > 0) && box.bottom >= top && box.top <= bottom && box.right >= left && box.left <= right;
      if (measured && near === this.visible) return;
      measured = true;
      this.visible = near;
      this.connection.update();
    };
    const observer = new IntersectionObserver(measure, { rootMargin: "200px" });
    observer.observe(element);
    let timer: ReturnType<typeof setTimeout> | undefined = setTimeout(() => { timer = undefined; measure(); }, 0);
    const moved = (): void => { if (timer === undefined) timer = setTimeout(() => { timer = undefined; measure(); }, 50); };
    const interval = setInterval(measure, 1_000);
    window.addEventListener("scroll", moved, { capture: true, passive: true });
    window.addEventListener("resize", moved);
    // A hidden tab parks its editors, so an idle tab holds no channels.
    const update = (): void => this.connection.update();
    document.addEventListener("visibilitychange", update);
    const focusin = (): void => { this.focused = true; update(); };
    const focusout = (event: FocusEvent): void => {
      if (event.relatedTarget instanceof Node && element.contains(event.relatedTarget)) return;
      this.focused = false;
      update();
    };
    element.addEventListener("focusin", focusin);
    element.addEventListener("focusout", focusout);
    this.cleanups.push(() => {
      clearTimeout(timer);
      clearInterval(interval);
      observer.disconnect();
      window.removeEventListener("scroll", moved, { capture: true });
      window.removeEventListener("resize", moved);
      document.removeEventListener("visibilitychange", update);
      element.removeEventListener("focusin", focusin);
      element.removeEventListener("focusout", focusout);
    });
  }

  private joined(payload: Join): void {
    if (this.disposed || this.failure) return;
    if (this.pending.length > 0 && this.accepted?.epoch !== payload.state.epoch) { this.fail("The shared document changed. Your local draft is preserved."); return; }
    this.lastAwareness = "";
    this.inFlight = null;
    this.accepted = payload.state;
    this.readRole = payload.role === "read";
    const accepted = new Set(payload.accepted ?? []);
    this.pending = this.pending.filter(transaction => !accepted.has(transaction.id));
    if (this.blocked && this.pending.length > 0) { this.fail("Write access changed. Your local draft is preserved."); return; }
    this.presence.receive(payload.people);
    try {
      this.render(this.view !== null);
      this.applyReadonly();
      this.persist();
      this.send();
      this.showStatus();
      this.awareness();
    } catch { this.fail("Your local edits need review. Your local draft is preserved."); return; }
    this.everJoined = true;
    this.settle(this.joins);
  }

  private receive(event: Transaction): void {
    if (!this.accepted || this.failure || this.disposed || event.epoch !== this.accepted.epoch) return;
    const revision = event.revision ?? 0;
    if (revision <= this.accepted.revision && !this.pending.some(transaction => transaction.id === event.id)) return;
    if (revision > this.accepted.revision + 1) { this.connection.reset(); return; }
    if (revision > this.accepted.revision) {
      this.accepted = apply(this.accepted, event.ops);
      this.accepted.revision = revision;
    }
    this.pending = this.pending.filter(transaction => transaction.id !== event.id);
    if (this.inFlight === event.id) this.inFlight = null;
    try { this.render(); } catch { this.fail("A concurrent change needs review. Your local draft is preserved."); return; }
    this.persist();
    this.showStatus();
    this.presence.draw();
    this.send();
    if (this.pending.length === 0) this.settle(this.drained);
    this.connection.update();
  }

  private enqueue(operations: Operation[], render = true): void {
    if (!this.accepted || !this.view || operations.length === 0) return;
    operations = operations.map(op => {
      if (op.op !== "insert_text") return op;
      const attrs = op.atoms[0]?.attrs ?? {};
      return { ...op, attrs, atoms: op.atoms.map(atom => ({ id: atom.id, text: atom.text, ...(equal(attrs, atom.attrs) ? {} : { attrs: atom.attrs }) })) };
    });
    const tail = this.pending[this.pending.length - 1];
    if (tail && !this.sent.has(tail.id) && tail.ops.length + operations.length <= 900) {
      // Replace an unsent transaction; once sent, its payload never changes.
      this.pending[this.pending.length - 1] = { ...tail, ops: [...tail.ops, ...clone(operations)] };
    } else {
      const transaction: Transaction = { v: 1, schema: 1, epoch: this.accepted.epoch, id: uuid(), base_revision: this.accepted.revision, ops: clone(operations) };
      this.pending.push(transaction);
    }
    this.view = apply(this.view, operations);
    if (render) this.binding.render(this.view);
    this.revisionInput.value = "";
    this.persist();
    this.connection.update();
    this.showStatus();
    clearTimeout(this.sendTimer);
    this.sendTimer = setTimeout(() => this.send(), 80);
    this.awareness();
  }

  private render(preserve = true): void {
    if (!this.accepted || this.host.editor.isComposing()) return;
    let state = clone(this.accepted);
    for (const transaction of this.pending) state = apply(state, transaction.ops);
    this.binding.render(state, preserve);
    this.view = state;
  }

  private persist(): void {
    if (!this.accepted || !this.localBackup) return;
    const backup = clone({ state: this.accepted, pending: this.pending, sent: this.pending.filter(transaction => this.sent.has(transaction.id)).map(transaction => transaction.id) });
    this.persistenceChain = this.persistenceChain.then(() => this.persistence.save(backup)).catch(() => { this.localBackup = false; this.showStatus(); });
  }

  private send(): void {
    const channel = this.connection.channel;
    if (!channel || !this.connection.joined || this.inFlight || this.failure || this.pending.length === 0 || this.disposed || this.host.editor.isComposing()) return;
    const transaction = this.pending[0];
    this.inFlight = transaction.id;
    this.sent.add(transaction.id);
    this.persist();
    void this.persistenceChain.then(() => {
      if (!this.connection.joined || this.disposed || this.inFlight !== transaction.id || this.connection.channel !== channel) return;
      channel.push("transaction", transaction, 15_000)
        .receive("ok", payload => {
          const event = payload as Transaction & { duplicate?: boolean };
          if (!event.duplicate) this.receive(event);
          else {
            this.pending = this.pending.filter(value => value.id !== transaction.id);
            if (this.inFlight === transaction.id) this.inFlight = null;
            this.flushing += 1;
            channel.push("flush", {}).receive("ok", value => {
              this.flushing -= 1;
              const payload = value as Join;
              if (this.accepted && payload.state.revision >= this.accepted.revision) this.accepted = payload.state;
              this.render(); this.persist(); this.showStatus(); this.send();
              if (this.pending.length === 0) this.settle(this.drained);
              this.connection.update();
            }).receive("error", () => { this.flushing -= 1; this.fail("Access changed. Your local draft is preserved."); }).receive("timeout", () => { this.flushing -= 1; this.connection.update(); });
          }
        })
        .receive("error", payload => { console.error("Kotoba collaboration rejected transaction:", (payload as { reason?: string }).reason); this.fail("The server could not save your edits. Your local draft is preserved."); })
        .receive("timeout", () => { if (this.connection.channel === channel) this.connection.reset(); });
    });
  }

  private history(isRedo: boolean): boolean {
    if (this.readonly) return true;
    const source = isRedo ? this.redoStack : this.undoStack;
    const target = isRedo ? this.undoStack : this.redoStack;
    const change = source.pop();
    if (!change) return true;
    this.enqueue(isRedo ? redo(change) : change.inverse);
    target.push(change);
    this.lastEdit = 0;
    this.historyState();
    return true;
  }

  private historyState(): void {
    const api = this.host.api.lexical;
    this.host.editor.dispatchCommand(api.CAN_UNDO_COMMAND, this.undoStack.length > 0);
    this.host.editor.dispatchCommand(api.CAN_REDO_COMMAND, this.redoStack.length > 0);
  }

  // Waits for a join: at most 15 s (with the socket down there is no channel whose join could
  // time out).
  private waitForJoin(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.joins = this.joins.filter(value => value !== waiter);
        this.connection.update();
        reject(new Error(RECONNECT));
      }, 15_000);
      const waiter: Waiter = {
        resolve: () => { clearTimeout(timer); resolve(); },
        reject: (reason: Error) => { clearTimeout(timer); reject(reason); },
      };
      this.joins.push(waiter);
      this.connection.update();
    });
  }

  async flush(): Promise<{ epoch: string; revision: number }> {
    await this.started;
    if (this.disposed) throw new Error("The editor closed");
    if (this.failure) throw new Error(this.failure);
    if (!this.connection.joined) {
      if (!navigator.onLine) throw new Error(RECONNECT);
      await this.waitForJoin();
    }
    const channel = this.connection.channel;
    if (!channel || !this.connection.joined || this.failure || !this.accepted) throw new Error(this.failure ?? RECONNECT);
    this.send();
    if (this.pending.length > 0) await new Promise<void>((resolve, reject) => this.drained.push({ resolve, reject }));
    this.flushing += 1;
    const payload = await new Promise<Join>((resolve, reject) => channel.push("flush", {}).receive("ok", value => resolve(value as Join)).receive("error", () => reject(new Error("Access changed"))).receive("timeout", () => reject(new Error("The server did not confirm this revision")))).finally(() => { this.flushing -= 1; this.connection.update(); });
    if (this.pending.length > 0) return this.flush();
    if (payload.state.revision >= this.accepted.revision) this.accepted = payload.state;
    this.render();
    this.persist();
    const revision = { epoch: payload.state.epoch, revision: payload.state.revision };
    this.revisionInput.value = JSON.stringify(revision);
    return revision;
  }

  unsettled(): boolean { return this.pending.length > 0 || this.revisionInput.value === ""; }

  lock(): void {
    // An editor that is read-only only until its channel joins counts as editable.
    this.editableBeforeLock = this.host.editor.isEditable() || (this.accepted === null && !this.readRole && !this.host.initialReadonly);
    this.locked = true;
    this.host.setReadonly(true);
  }

  unlock(): void {
    this.locked = false;
    if (!this.disposed && !this.failure) this.host.setReadonly(!this.editableBeforeLock || this.blocked || this.host.initialReadonly);
  }

  whenJoined(): Promise<void> {
    if (this.failure || this.disposed) return Promise.reject(new Error(this.failure ?? "The editor closed"));
    if (this.everJoined) return Promise.resolve();
    return new Promise((resolve, reject) => { this.joins.push({ resolve, reject }); this.connection.update(); });
  }

  private applyReadonly(): void { this.host.setReadonly(this.readonly || this.host.initialReadonly); }

  private settle(waiters: Waiter[]): void { waiters.splice(0).forEach(waiter => waiter.resolve()); }

  private rejectAll(message: string, includeJoins: boolean): void {
    const error = new Error(message);
    this.drained.splice(0).forEach(waiter => waiter.reject(error));
    if (includeJoins) this.joins.splice(0).forEach(waiter => waiter.reject(error));
  }

  private awareness(): void {
    clearTimeout(this.awarenessTimer);
    this.awarenessTimer = setTimeout(() => {
      const channel = this.connection.channel;
      if (!channel || !this.connection.joined || this.failure || this.disposed) return;
      const selection = this.blocked ? null : this.binding.selection();
      const signature = JSON.stringify(selection);
      if (signature === this.lastAwareness) return;
      this.lastAwareness = signature;
      channel.push("awareness", { selection });
    }, 40);
  }

  // The channel went away: what waits for it to be accepted waits no more. A join waiter keeps
  // waiting (bounded), since the connection tries again.
  private offline(): void {
    this.inFlight = null;
    this.presence.offline();
    this.rejectAll(RECONNECT, false);
    this.showStatus();
  }

  private fail(message: string): void {
    if (this.disposed || this.failure) return;
    this.recoveryDraft = this.host.readDocument();
    this.failure = message;
    this.connection.freeze();
    this.host.setReadonly(true);
    this.recover.hidden = this.view === null;
    this.rejectAll(message, true);
    this.presence.offline();
    this.showStatus();
    this.host.announce(message);
  }

  showStatus(): void {
    const joined = this.connection.joined;
    // Parked: not wanted (idle), not waiting for a socket, a retry or a join. One that never
    // joined shows its field's saved text, so it is "Saved" too.
    const parked = this.lazy && this.connection.state === "idle" && this.pending.length === 0 && navigator.onLine;
    if (parked && !this.failure) {
      this.status.textContent = this.readRole ? "Live view" : "Saved";
      this.host.element.dataset.collabState = "idle";
      return;
    }
    this.status.textContent = this.failure ?? (!joined ? (this.localBackup ? "Offline — edits are kept on this device" : "Offline — edits are kept in this tab") : this.pending.length > 0 ? "Saving…" : this.blocked ? "Live view" : "Saved");
    this.host.element.dataset.collabState = this.failure ? "error" : !joined ? "offline" : this.pending.length > 0 ? "saving" : "saved";
  }

  private download(): void {
    if (!this.view) return;
    const url = URL.createObjectURL(new Blob([JSON.stringify(this.recoveryDraft ?? envelope(this.view), null, 2)], { type: "application/json" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = "kotoba-local-draft.json";
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1_000);
  }

  updateCredentials(credentials: CollabCredentials): void {
    this.connection.updateCredentials(credentials);
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.markStarted();
    clearTimeout(this.sendTimer);
    clearTimeout(this.awarenessTimer);
    this.persist();
    this.rejectAll("The editor closed", true);
    this.cleanups.reverse().forEach(cleanup => cleanup());
    this.connection.dispose();
    this.presence.dispose();
    this.bar.remove();
    this.revisionInput.remove();
    void this.persistenceChain.finally(() => this.persistence.close());
    delete (this.host.element as HTMLElement & { kotobaCollab?: Collaboration }).kotobaCollab;
  }
}

export async function createCollaboration(host: CollaborationHost): Promise<Collaboration> {
  const client = new Client(host);
  // A client that could not start is disposed (it leaves nothing behind).
  try { await client.start(); } catch (error) { client.dispose(); throw error; }
  return client;
}
