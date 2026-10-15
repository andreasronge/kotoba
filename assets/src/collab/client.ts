import { Socket, type Channel } from "phoenix";
import type { Collaboration, CollaborationHost, CollabCredentials } from "../collaboration";
import { Binding, COLLAB_TAG, redo, type Change } from "./binding";
import { apply, clone, equal, envelope, uuid, type Operation, type State, type Transaction } from "./model";
import { Persistence } from "./persistence";
import { Presence, type Person } from "./presence";

interface FormBarrier { clients: Set<Client>; resubmit: boolean; busy: boolean; handler: (event: SubmitEvent) => void }
const forms = new WeakMap<HTMLFormElement, FormBarrier>();

interface Join { state: State; role: "read" | "write"; people: Person[]; accepted: string[] }

class Client implements Collaboration {
  private readRole: boolean;
  get readonly(): boolean { return this.readRole || this.failure !== null || this.accepted === null; }
  private credentials: CollabCredentials;
  private readonly persistence: Persistence;
  private readonly binding: Binding;
  private readonly socket: Socket;
  private readonly channel: Channel;
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
  private connected = false;
  private disposed = false;
  private inFlight: string | null = null;
  private failure: string | null = null;
  private recoveryDraft: unknown;
  private localBackup = true;
  private persistenceChain = Promise.resolve();
  private waiters: { resolve: () => void; reject: (reason: Error) => void }[] = [];
  private awarenessTimer: ReturnType<typeof setTimeout> | undefined;
  private lastAwareness = "";
  private sendTimer: ReturnType<typeof setTimeout> | undefined;
  private refreshTimer: ReturnType<typeof setInterval> | undefined;

  constructor(private readonly host: CollaborationHost) {
    this.credentials = host.credentials;
    this.readRole = host.credentials.role === "read";
    this.persistence = new Persistence(this.credentials.socket, this.credentials.document_id, this.credentials.user.id);
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
    this.socket = new Socket(this.credentials.socket);
    this.channel = this.socket.channel(`kotoba:${this.credentials.document_id}`, () => ({ token: this.credentials.token, session: this.persistence.session, pending: this.pending.map(transaction => transaction.id) }));
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
        this.host.setReadonly(this.readonly || this.host.initialReadonly);
      }
    } catch { this.localBackup = false; }
    const api = this.host.api.lexical;
    this.cleanups.push(this.host.editor.registerUpdateListener(({ tags, dirtyElements, dirtyLeaves }) => {
      if (tags.has(COLLAB_TAG) || !this.view || this.readonly || this.failure || (dirtyElements.size === 0 && dirtyLeaves.size === 0)) return;
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
    this.channel.on("transaction", payload => this.receive(payload as Transaction));
    this.channel.on("presence", payload => this.presence.receive((payload as { people: Person[] }).people));
    this.channel.onError(() => this.offline());
    this.channel.onClose(() => this.offline());
    this.channel.join().receive("ok", payload => this.joined(payload as Join)).receive("error", payload => { if ((payload as { reason?: string }).reason === "expired") void this.refreshCredentials(); else this.fail("Access to this shared document is unavailable. Your local draft is preserved."); }).receive("timeout", () => this.offline());
    const disconnect = (): void => { this.offline(); this.socket.disconnect(); };
    const reconnect = (): void => { if (!this.disposed && !this.failure) this.socket.connect(); };
    window.addEventListener("offline", disconnect);
    window.addEventListener("online", reconnect);
    this.cleanups.push(() => { window.removeEventListener("offline", disconnect); window.removeEventListener("online", reconnect); });
    if (navigator.onLine) this.socket.connect(); else this.offline();
    this.refreshTimer = setInterval(() => { if (this.connected) void this.refreshCredentials(); }, 180_000);
    const compositionEnd = (): void => { setTimeout(() => { if (!this.disposed && !this.failure) { this.render(); this.send(); this.awareness(); } }, 0); };
    this.host.editable.addEventListener("compositionend", compositionEnd);
    this.cleanups.push(() => this.host.editable.removeEventListener("compositionend", compositionEnd));
    this.watchForm();
    (this.host.element as HTMLElement & { kotobaCollab?: Collaboration }).kotobaCollab = this;
  }

  private joined(payload: Join): void {
    if (this.disposed) return;
    if (this.pending.length > 0 && this.accepted?.epoch !== payload.state.epoch) { this.fail("The shared document changed. Your local draft is preserved."); return; }
    this.connected = true;
    this.lastAwareness = "";
    this.inFlight = null;
    this.accepted = payload.state;
    this.readRole = payload.role === "read";
    const accepted = new Set(payload.accepted ?? []);
    this.pending = this.pending.filter(transaction => !accepted.has(transaction.id));
    if (this.readonly && this.pending.length > 0) { this.fail("Write access changed. Your local draft is preserved."); return; }
    this.presence.receive(payload.people);
    try {
      this.render(this.view !== null);
      this.host.setReadonly(this.readonly || this.host.initialReadonly);
      this.persist();
      this.send();
      this.updateStatus();
      this.awareness();
    } catch { this.fail("Your local edits need review. Your local draft is preserved."); }
  }

  private receive(event: Transaction): void {
    if (!this.accepted || this.failure || this.disposed || event.epoch !== this.accepted.epoch) return;
    const revision = event.revision ?? 0;
    if (revision <= this.accepted.revision && !this.pending.some(transaction => transaction.id === event.id)) return;
    if (revision > this.accepted.revision + 1) { this.offline(); this.socket.disconnect(); this.socket.connect(); return; }
    if (revision > this.accepted.revision) {
      this.accepted = apply(this.accepted, event.ops);
      this.accepted.revision = revision;
    }
    this.pending = this.pending.filter(transaction => transaction.id !== event.id);
    if (this.inFlight === event.id) this.inFlight = null;
    try { this.render(); } catch { this.fail("A concurrent change needs review. Your local draft is preserved."); return; }
    this.persist();
    this.updateStatus();
    this.presence.draw();
    this.send();
    if (this.pending.length === 0) this.waiters.splice(0).forEach(waiter => waiter.resolve());
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
    this.updateStatus();
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
    this.persistenceChain = this.persistenceChain.then(() => this.persistence.save(backup)).catch(() => { this.localBackup = false; this.updateStatus(); });
  }

  private send(): void {
    if (!this.connected || this.inFlight || this.failure || this.pending.length === 0 || this.disposed || this.host.editor.isComposing()) return;
    const transaction = this.pending[0];
    this.inFlight = transaction.id;
    this.sent.add(transaction.id);
    this.persist();
    void this.persistenceChain.then(() => {
      if (!this.connected || this.disposed || this.inFlight !== transaction.id) return;
      this.channel.push("transaction", transaction, 15_000)
        .receive("ok", payload => {
          const event = payload as Transaction & { duplicate?: boolean };
          if (!event.duplicate) this.receive(event);
          else {
            this.pending = this.pending.filter(value => value.id !== transaction.id);
            if (this.inFlight === transaction.id) this.inFlight = null;
            this.channel.push("flush", {}).receive("ok", value => {
              const payload = value as Join;
              if (this.accepted && payload.state.revision >= this.accepted.revision) this.accepted = payload.state;
              this.render(); this.persist(); this.updateStatus(); this.send();
              if (this.pending.length === 0) this.waiters.splice(0).forEach(waiter => waiter.resolve());
            }).receive("error", () => this.fail("Access changed. Your local draft is preserved."));
          }
        })
        .receive("error", payload => { console.error("Kotoba collaboration rejected transaction:", (payload as { reason?: string }).reason); this.fail("The server could not save your edits. Your local draft is preserved."); })
        .receive("timeout", () => { this.inFlight = null; this.offline(); this.socket.disconnect(); this.socket.connect(); });
    });
  }

  private history(isRedo: boolean): boolean {
    if (this.readonly || this.failure) return true;
    const source = isRedo ? this.redoStack : this.undoStack;
    const target = isRedo ? this.undoStack : this.redoStack;
    const change = source.pop();
    if (!change) return true;
    // An explicit history command returns focus from its toolbar before rendering.
    this.host.editable.focus({ preventScroll: true });
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

  async flush(): Promise<{ epoch: string; revision: number }> {
    if (!this.connected || this.failure || !this.accepted) throw new Error(this.failure ?? "Reconnect before saving this form");
    this.send();
    if (this.pending.length > 0) await new Promise<void>((resolve, reject) => this.waiters.push({ resolve, reject }));
    const payload = await new Promise<Join>((resolve, reject) => this.channel.push("flush", {}).receive("ok", value => resolve(value as Join)).receive("error", () => reject(new Error("Access changed"))).receive("timeout", () => reject(new Error("The server did not confirm this revision"))));
    if (this.pending.length > 0) return this.flush();
    if (payload.state.revision >= this.accepted.revision) this.accepted = payload.state;
    this.render();
    this.persist();
    const revision = { epoch: payload.state.epoch, revision: payload.state.revision };
    this.revisionInput.value = JSON.stringify(revision);
    return revision;
  }

  private watchForm(): void {
    const form = this.host.element.closest("form");
    if (!form) return;
    let barrier = forms.get(form);
    if (!barrier) {
      barrier = { clients: new Set(), resubmit: false, busy: false, handler: () => {} };
      const shared = barrier;
      shared.handler = (event): void => {
        if (shared.resubmit) { shared.resubmit = false; return; }
        event.preventDefault();
        event.stopImmediatePropagation();
        if (shared.busy) return;
        shared.busy = true;
        const editing = [...shared.clients].map(client => ({ client, editable: client.host.editor.isEditable() }));
        editing.forEach(({ client }) => client.host.editor.setEditable(false));
        void Promise.all(editing.map(({ client }) => client.flush())).then(() => {
          shared.resubmit = true;
          form.requestSubmit((event.submitter as HTMLButtonElement | HTMLInputElement | null) ?? undefined);
        }).catch(error => this.host.announce(error instanceof Error ? error.message : "The form could not be saved")).finally(() => {
          shared.busy = false;
          editing.forEach(({ client, editable }) => { if (!client.disposed && !client.failure) client.host.editor.setEditable(editable && !client.readonly); });
        });
      };
      forms.set(form, shared);
      form.addEventListener("submit", shared.handler, true);
    }
    barrier.clients.add(this);
    const shared = barrier;
    this.cleanups.push(() => {
      shared.clients.delete(this);
      if (shared.clients.size === 0) { form.removeEventListener("submit", shared.handler, true); forms.delete(form); }
    });
  }

  private awareness(): void {
    clearTimeout(this.awarenessTimer);
    this.awarenessTimer = setTimeout(() => {
      if (!this.connected || this.failure || this.disposed) return;
      const selection = this.readonly ? null : this.binding.selection();
      const signature = JSON.stringify(selection);
      if (signature === this.lastAwareness) return;
      this.lastAwareness = signature;
      this.channel.push("awareness", { selection });
    }, 40);
  }

  private offline(): void {
    this.connected = false;
    this.inFlight = null;
    this.presence.offline();
    this.waiters.splice(0).forEach(waiter => waiter.reject(new Error("Reconnect before saving this form")));
    this.updateStatus();
  }

  private fail(message: string): void {
    this.recoveryDraft = this.host.readDocument();
    this.failure = message;
    this.host.setReadonly(true);
    this.recover.hidden = this.view === null;
    this.waiters.splice(0).forEach(waiter => waiter.reject(new Error(message)));
    this.updateStatus();
    this.host.announce(message);
  }

  private updateStatus(): void {
    this.status.textContent = this.failure ?? (!this.connected ? (this.localBackup ? "Offline — edits are kept on this device" : "Offline — edits are kept in this tab") : this.pending.length > 0 ? "Saving…" : this.readonly ? "Live view" : "Saved");
    this.host.element.dataset.collabState = this.failure ? "error" : !this.connected ? "offline" : this.pending.length > 0 ? "saving" : "saved";
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
    if (credentials.document_id !== this.credentials.document_id || credentials.user.id !== this.credentials.user.id || credentials.socket !== this.credentials.socket) throw new Error("Collaboration identity cannot change while mounted");
    this.credentials = credentials;
  }
  private async refreshCredentials(): Promise<void> {
    try { this.updateCredentials(await this.host.refreshCredentials()); } catch { if (!this.connected) this.offline(); }
  }

  dispose(): void {
    this.disposed = true;
    clearTimeout(this.sendTimer);
    clearTimeout(this.awarenessTimer);
    clearInterval(this.refreshTimer);
    this.persist();
    this.waiters.splice(0).forEach(waiter => waiter.reject(new Error("The editor closed")));
    this.cleanups.reverse().forEach(cleanup => cleanup());
    this.channel.leave();
    this.socket.disconnect();
    this.presence.dispose();
    this.bar.remove();
    this.revisionInput.remove();
    void this.persistenceChain.finally(() => this.persistence.close());
    delete (this.host.element as HTMLElement & { kotobaCollab?: Collaboration }).kotobaCollab;
  }
}

export async function createCollaboration(host: CollaborationHost): Promise<Collaboration> {
  const client = new Client(host);
  await client.start();
  return client;
}
