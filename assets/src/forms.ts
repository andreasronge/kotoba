/**
 * One coordinator per form with shared editors: it owns the form's members and the whole
 * submit. A member is a shared editor, from its mount: starting (loading node modules or
 * extensions, opening its local backup), failed (it could not start) or started (its client
 * takes part). A submit
 *
 * - is refused while a member could not start (its field has no confirmed revision);
 * - waits for starting members, locks every started one (editor and toolbars) until the end,
 *   and flushes in rounds until each has a confirmed revision: one that starts meanwhile is
 *   flushed too, and so is one that changed after its flush;
 * - reports the first failure of a member still there, or submits the form again, with its
 *   submit button when that is still one of the form's.
 */

/** A started shared editor, as its form's submit sees it. */
export interface SubmitParticipant {
  /** Removed (disposed): nothing to submit. */
  readonly closed: boolean;
  lock(): void;
  unlock(): void;
  /** Puts a confirmed revision in the editor's revision input. */
  flush(): Promise<unknown>;
  /** Work the form's revision does not include (pending edits, or no confirmed revision). */
  unsettled(): boolean;
}

export interface FormMembership {
  started(participant: SubmitParticipant): void;
  failed(): void;
  removed(): void;
}

const REFUSED = "A shared editor of this form could not start";
const NONE: FormMembership = { started() {}, failed() {}, removed() {} };

interface Member { state: "starting" | "failed" | "started"; participant: SubmitParticipant | null; announce: (message: string) => void }

class FormCoordinator {
  private readonly members = new Map<HTMLElement, Member>();
  private busy = false;
  // The coordinator's own resubmission goes through; cleared after it in any case (a
  // resubmission the browser's validation stops fires no submit event).
  private resubmitting = false;
  private readonly locked = new Set<SubmitParticipant>();
  private wakers: (() => void)[] = [];
  private readonly handler = (event: SubmitEvent): void => this.submit(event);

  constructor(private readonly form: HTMLFormElement) {
    form.addEventListener("submit", this.handler, true);
  }

  join(element: HTMLElement, announce: (message: string) => void): FormMembership {
    const member: Member = { state: "starting", participant: null, announce };
    this.members.set(element, member);
    const current = (): boolean => this.members.get(element) === member;
    return {
      started: participant => {
        if (!current() || member.state !== "starting") return;
        member.state = "started";
        member.participant = participant;
        if (this.busy) this.lock(participant);
        this.wake();
      },
      failed: () => {
        if (!current()) return;
        member.state = "failed";
        member.participant = null;
        this.wake();
      },
      removed: () => {
        if (!current()) return;
        this.members.delete(element);
        if (member.participant) { this.locked.delete(member.participant); }
        this.wake();
        if (this.members.size === 0 && !this.busy) this.detach();
      },
    };
  }

  private submit(event: SubmitEvent): void {
    if (this.resubmitting) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (this.busy) return;
    if (this.refuse()) return;
    this.busy = true;
    void this.run(event.submitter);
  }

  private async run(submitter: HTMLElement | null): Promise<void> {
    const outcomes = new Map<SubmitParticipant, PromiseSettledResult<unknown>>();
    try {
      for (const member of this.members.values()) if (member.participant) this.lock(member.participant);
      for (let round = 0; ; ) {
        await this.started();
        const next = this.participants().filter(participant => {
          const outcome = outcomes.get(participant);
          return !outcome || (outcome.status === "fulfilled" && participant.unsettled());
        });
        if (next.length === 0) {
          // A member that mounted since the wait above (starting, or failed at once): the wait
          // decides again (it refuses for a failed one).
          if ([...this.members.values()].some(member => member.state !== "started")) continue;
          break;
        }
        if (++round > 10) throw new Error("The form could not be saved");
        const settled = await Promise.allSettled(next.map(participant => participant.flush()));
        settled.forEach((outcome, index) => outcomes.set(next[index], outcome));
      }
      const live = new Set(this.participants());
      const failed = [...outcomes].find(([participant, outcome]) => outcome.status === "rejected" && live.has(participant));
      if (failed) throw (failed[1] as PromiseRejectedResult).reason;
      this.resubmit(submitter);
    } catch (error) {
      this.announce(error instanceof Error ? error.message : "The form could not be saved");
    } finally {
      this.busy = false;
      for (const participant of this.locked) participant.unlock();
      this.locked.clear();
      if (this.members.size === 0) this.detach();
    }
  }

  // Resolves when no member is starting; rejects if one could not start.
  private async started(): Promise<void> {
    for (;;) {
      const states = [...this.members.values()].map(member => member.state);
      if (states.includes("failed")) throw new Error(REFUSED);
      if (!states.includes("starting")) return;
      await new Promise<void>(resolve => this.wakers.push(resolve));
    }
  }

  private refuse(): boolean {
    const failed = [...this.members.values()].filter(member => member.state === "failed");
    failed.forEach(member => member.announce(REFUSED));
    return failed.length > 0;
  }

  private participants(): SubmitParticipant[] {
    return [...this.members.values()].flatMap(member => member.participant && !member.participant.closed ? [member.participant] : []);
  }

  private lock(participant: SubmitParticipant): void {
    if (this.locked.has(participant)) return;
    this.locked.add(participant);
    participant.lock();
  }

  private wake(): void { this.wakers.splice(0).forEach(resolve => resolve()); }

  private announce(message: string): void { this.members.values().next().value?.announce(message); }

  private resubmit(submitter: HTMLElement | null): void {
    const button = submitter instanceof HTMLButtonElement || submitter instanceof HTMLInputElement ? submitter : null;
    this.resubmitting = true;
    try {
      // A patch can replace the button meanwhile: then without it.
      this.form.requestSubmit(button && button.isConnected && button.form === this.form ? button : undefined);
    } catch (error) {
      console.error("Kotoba: the form could not be submitted again", error);
    } finally {
      this.resubmitting = false;
    }
  }

  private detach(): void {
    if (coordinators.get(this.form) !== this) return;
    this.form.removeEventListener("submit", this.handler, true);
    coordinators.delete(this.form);
  }
}

const coordinators = new WeakMap<HTMLFormElement, FormCoordinator>();

/** Makes a shared editor a member of its form (from its mount); outside a form, nothing. */
export function joinForm(element: HTMLElement, announce: (message: string) => void): FormMembership {
  const form = element.closest("form");
  if (!form) return NONE;
  let coordinator = coordinators.get(form);
  if (!coordinator) {
    coordinator = new FormCoordinator(form);
    coordinators.set(form, coordinator);
  }
  return coordinator.join(element, announce);
}
