import { expect, test, type Page, type WebSocketRoute } from "@playwright/test";
import { focusEnd, openEditor } from "./support";

// A page of many shared editors, as a document of many text blocks.
const editor = (page: Page, n: number) => page.locator(`#editor_${n} .kotoba-editable`);
const status = (page: Page, n: number) => page.locator(`#editor_${n} [data-collab-status]`);

interface Traffic { sockets: string[]; joins: string[]; leaves: string[] }

// The collaboration sockets the page opens, and the channel joins and leaves it sends on them.
function watch(page: Page): Traffic {
  const traffic: Traffic = { sockets: [], joins: [], leaves: [] };
  page.on("websocket", socket => {
    if (!socket.url().includes("/kotoba/socket")) return;
    traffic.sockets.push(socket.url());
    socket.on("framesent", frame => {
      if (typeof frame.payload !== "string") return;
      const [, , topic, event] = JSON.parse(frame.payload) as [string, string, string, string];
      if (event === "phx_join") traffic.joins.push(topic);
      if (event === "phx_leave") traffic.leaves.push(topic);
    });
  });
  return traffic;
}

// Routes the collaboration socket: `blocked` refuses it; `delay` holds the server's messages back,
// and `delays` those of one topic (each topic's messages stay in order).
// `failFlush` answers the flush requests of one topic with an error.
// `crash(topic)` sends the page a channel error for that topic, as when its channel process dies;
// `expire` answers the next join of that topic as with an expired token.
interface Control { blocked: boolean; delay: number; delays: Record<string, number>; failFlush: string | null; expire: string | null; expireAlways: string | null; tokens: Record<string, string[]>; crash: (topic: string) => void }
async function route(page: Page): Promise<Control> {
  const joinRefs = new Map<string, string>();
  let page_: WebSocketRoute | null = null;
  const control: Control = {
    blocked: false, delay: 0, delays: {}, failFlush: null, expire: null, expireAlways: null, tokens: {},
    crash: topic => page_?.send(JSON.stringify([joinRefs.get(topic), null, topic, "phx_error", {}])),
  };
  const queues = new Map<string, Promise<void>>();
  await page.routeWebSocket(/\/kotoba\/socket/, (socket: WebSocketRoute) => {
    // An abnormal close, as when the server is unreachable: Phoenix reconnects only then.
    if (control.blocked) { void socket.close({ code: 4000, reason: "blocked" }); return; }
    const server = socket.connectToServer();
    page_ = socket;
    socket.onMessage(message => {
      const frame = typeof message === "string" ? JSON.parse(message) as [string, string, string, string, unknown] : null;
      if (frame && frame[3] === "phx_join") {
        joinRefs.set(frame[2], frame[0]);
        (control.tokens[frame[2]] ??= []).push((frame[4] as unknown as { token: string }).token);
      }
      if (frame && frame[3] === "phx_join" && (frame[2] === control.expire || frame[2] === control.expireAlways)) {
        control.expire = null;
        socket.send(JSON.stringify([frame[0], frame[1], frame[2], "phx_reply", { status: "error", response: { reason: "expired" } }]));
        return;
      }
      if (frame && frame[3] === "flush" && frame[2] === control.failFlush) {
        socket.send(JSON.stringify([frame[0], frame[1], frame[2], "phx_reply", { status: "error", response: {} }]));
        return;
      }
      server.send(message);
    });
    server.onMessage(message => {
      const topic = typeof message === "string" ? (JSON.parse(message) as string[])[2] : "";
      const delay = control.delays[topic] ?? control.delay;
      const queue = (queues.get(topic) ?? Promise.resolve()).then(() => new Promise<void>(resolve => setTimeout(() => { socket.send(message); resolve(); }, delay)));
      queues.set(topic, queue);
    });
  });
  return control;
}

async function open(page: Page, query: string, first = 1): Promise<void> {
  await openEditor(page, `/collab/many?${query}`, `editor_${first}`);
  await expect(page.locator(`#editor_${first}`)).toHaveAttribute("data-collab-state", "saved");
}

test("the editors of a page share one socket", async ({ page, browser }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await open(page, `document=${id}&count=12&name=Ada`);
  for (let n = 1; n <= 12; n++) await expect(page.locator(`#editor_${n}`)).toHaveAttribute("data-collab-state", "saved");
  expect(traffic.sockets).toHaveLength(1);
  expect(new Set(traffic.joins).size).toBe(12);

  const context = await browser.newContext();
  const other = await context.newPage();
  await open(other, `document=${id}&count=12&name=Grace`);
  await editor(other, 7).scrollIntoViewIfNeeded();
  await expect(other.locator(`#editor_${7}`)).toHaveAttribute("data-collab-state", "saved");
  await focusEnd(other, editor(other, 7));
  await other.keyboard.type("seven");
  await expect(editor(page, 7)).toHaveText("seven");
  await expect(editor(page, 6)).toHaveText("");
  await context.close();
});

test("a colleague's edit in another editor of the page leaves the caret where it is", async ({ page, browser }) => {
  const id = crypto.randomUUID();
  await open(page, `document=${id}&count=3&name=Ada`);
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  await focusEnd(page, editor(page, 2));
  await page.keyboard.type("two");
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("one");

  const context = await browser.newContext();
  const other = await context.newPage();
  await open(other, `document=${id}&count=3&name=Grace`);
  await expect(other.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  await focusEnd(other, editor(other, 2));
  await other.keyboard.type("!");
  await expect(editor(page, 2)).toHaveText("two!");
  await page.keyboard.type(" more");
  await expect(editor(page, 1)).toHaveText("one more");
  await expect(editor(page, 2)).toHaveText("two!");
  await context.close();
});

test("a second editor of the same document gets its own socket", async ({ page }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await open(page, `document=${id}&count=3&name=Ada&repeat=1`);
  await expect(page.locator(`#editor_${4}`)).toHaveAttribute("data-collab-state", "saved");
  expect(traffic.sockets).toHaveLength(2);
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("twice");
  await expect(editor(page, 4)).toHaveText("twice");
});

test("join: :visible opens the channels of the editors near the screen, and parks those that leave it", async ({ page, browser }) => {
  const id = crypto.randomUUID();
  const query = `document=${id}&count=12&join=visible&park_after=300`;
  const traffic = watch(page);
  await open(page, `${query}&name=Ada`);
  expect(traffic.sockets).toHaveLength(1);
  expect(traffic.joins).toContain(`kotoba:${id}-1`);
  expect(traffic.joins).not.toContain(`kotoba:${id}-10`);
  expect(new Set(traffic.joins).size).toBeLessThanOrEqual(3);

  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved");
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "saved");
  await focusEnd(page, editor(page, 10));
  await page.keyboard.type("ten");
  await expect(page.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved");

  // Off screen and idle: the channel leaves; the editor keeps its text.
  await page.locator("#editor_1").scrollIntoViewIfNeeded();
  await editor(page, 1).focus();
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "idle");
  expect(traffic.leaves).toContain(`kotoba:${id}-10`);

  // A colleague's edit made while it is parked shows when it comes back.
  const context = await browser.newContext();
  const other = await context.newPage();
  await open(other, `${query}&name=Grace`);
  await editor(other, 10).scrollIntoViewIfNeeded();
  await expect(editor(other, 10)).toHaveText("ten");
  await focusEnd(other, editor(other, 10));
  await other.keyboard.type("!");
  await expect(other.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved");
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(editor(page, 10)).toHaveText("ten!");
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "saved");
  await context.close();
});

test("an editor with unsent edits stays joined off screen until they are accepted", async ({ page, browser, context }) => {
  const id = crypto.randomUUID();
  const query = `document=${id}&count=12&join=visible&park_after=200`;
  await open(page, `${query}&name=Ada`);
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved");
  await context.setOffline(true);
  await expect(status(page, 10)).toContainText("Offline");
  await focusEnd(page, editor(page, 10));
  await page.keyboard.type("offline");
  await page.locator("#editor_1").scrollIntoViewIfNeeded();
  await editor(page, 1).focus();
  await page.waitForTimeout(500);
  await context.setOffline(false);
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "idle");

  const otherContext = await browser.newContext();
  const other = await otherContext.newPage();
  await open(other, `${query}&name=Grace`);
  await editor(other, 10).scrollIntoViewIfNeeded();
  await expect(editor(other, 10)).toHaveText("offline");
  await otherContext.close();
});

test("a form publishes the accepted revisions of parked editors too", async ({ page }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await open(page, `document=${id}&count=6&join=visible&park_after=200&name=Ada`);
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("one");
  await editor(page, 5).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${5}`)).toHaveAttribute("data-collab-state", "saved");
  await focusEnd(page, editor(page, 5));
  await page.keyboard.type("five");
  await expect(page.locator(`#editor_${5}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#many-save").scrollIntoViewIfNeeded();
  await editor(page, 1).focus();
  await expect(page.locator("#editor_5")).toHaveAttribute("data-collab-state", "idle");
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("one||||five|");
  expect(new Set(traffic.joins).size).toBe(6);
});

test("a reload with unsent edits in an off-screen editor sends them without scrolling to it", async ({ page, browser }) => {
  const id = crypto.randomUUID();
  const query = `document=${id}&count=12&join=visible&park_after=200`;
  const control = await route(page);
  await open(page, `${query}&name=Ada`);
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved");
  control.blocked = true;
  await page.context().setOffline(true);
  await expect(status(page, 10)).toContainText("Offline");
  await page.context().setOffline(false);
  await focusEnd(page, editor(page, 10));
  await page.keyboard.type("kept");
  await expect(status(page, 10)).toContainText("Offline");
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.reload();
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  control.blocked = false;

  const context = await browser.newContext();
  const other = await context.newPage();
  await open(other, `${query}&name=Grace`);
  await editor(other, 10).scrollIntoViewIfNeeded();
  await expect(other.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved");
  await expect(editor(other, 10)).toHaveText("kept");
  await context.close();
});

test("parking waits for a flush reply", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=4&join=visible&park_after=100&name=Ada`);
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("one");
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved");
  control.delay = 400;
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("one|||");
});

test("an editor first joined by a form submit can be edited afterwards", async ({ page }) => {
  const id = crypto.randomUUID();
  await open(page, `document=${id}&count=6&join=visible&park_after=200&name=Ada`);
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("|||||");
  await editor(page, 5).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${5}`)).toHaveAttribute("data-collab-state", "saved");
  await focusEnd(page, editor(page, 5));
  await page.keyboard.type("five");
  await expect(editor(page, 5)).toHaveText("five");
});

test("a submit right after the page loads waits for every editor", async ({ page }) => {
  const id = crypto.randomUUID();
  await page.goto(`/collab/many?document=${id}&count=6&name=Ada`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("|||||");
});

test("a hidden tab parks its editors, and joins them again when shown", async ({ page }) => {
  const id = crypto.randomUUID();
  await open(page, `document=${id}&count=3&join=visible&park_after=200&name=Ada`);
  await focusEnd(page, editor(page, 1));
  const show = (state: "hidden" | "visible") => page.evaluate(value => {
    Object.defineProperty(document, "visibilityState", { get: () => value, configurable: true });
    document.dispatchEvent(new Event("visibilitychange"));
  }, state);
  await show("hidden");
  await expect(page.locator("#editor_1")).toHaveAttribute("data-collab-state", "idle");
  await show("visible");
  await expect(page.locator("#editor_1")).toHaveAttribute("data-collab-state", "saved");
  await page.keyboard.type("back");
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved");
});

test("a parked editor renews old credentials before it joins again", async ({ page }) => {
  const id = crypto.randomUUID();
  const events: string[] = [];
  page.on("websocket", socket => socket.on("framesent", frame => {
    if (typeof frame.payload !== "string") return;
    const [, , topic, event, payload] = JSON.parse(frame.payload) as [string, string, string, string, { event?: string; value?: { document_id?: string } }];
    if (event === "phx_join" && topic === `kotoba:${id}-10`) events.push("join");
    if (payload?.event === "kotoba:collab_token" && payload.value?.document_id === `${id}-10`) events.push("renew");
  }));
  await page.clock.install();
  await open(page, `document=${id}&count=12&join=visible&park_after=200&name=Ada`);
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#editor_1").scrollIntoViewIfNeeded();
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "idle");
  await page.clock.fastForward("04:30");
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "saved");
  expect(events).toEqual(["join", "renew", "join"]);
});

test("a submit keeps every editor locked until all of them have joined and flushed", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=6&join=visible&park_after=200&name=Ada`);
  await editor(page, 5).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${5}`)).toHaveAttribute("data-collab-state", "saved");
  await focusEnd(page, editor(page, 5));
  await page.keyboard.type("five");
  await expect(page.locator(`#editor_${5}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#many-save").scrollIntoViewIfNeeded();
  await page.locator("#many-save").focus();
  await expect(page.locator("#editor_5")).toHaveAttribute("data-collab-state", "idle");
  // Editor 5 joins at once; editor 6's join is held back.
  control.delays[`kotoba:${id}-6`] = 500;
  await page.locator("#many-save").click();
  await expect(page.locator("#editor_5")).toHaveAttribute("data-collab-state", "saved");
  await focusEnd(page, editor(page, 5));
  await page.keyboard.type("X");
  await expect(page.locator("#many-saved")).toHaveText("||||five|", { timeout: 15_000 });
  await expect(editor(page, 5)).toHaveText("five");
});

test("an offline hidden tab parks its editors and does not rejoin them when it is back online", async ({ page, context }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await open(page, `document=${id}&count=3&join=visible&park_after=200&name=Ada`);
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  await context.setOffline(true);
  await expect(status(page, 1)).toContainText("Offline");
  await page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", { get: () => "hidden", configurable: true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await page.waitForTimeout(600);
  const joins = traffic.joins.length;
  await context.setOffline(false);
  await page.waitForTimeout(1500);
  expect(traffic.joins.length).toBe(joins);
  await expect(page.locator("#editor_1")).toHaveAttribute("data-collab-state", "idle");
});

test("a submit waits for an editor still loading its node modules", async ({ page }) => {
  const id = crypto.randomUUID();
  let release = (): void => {};
  const held = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/assets/nodes/tag.js", async route => { await held; await route.continue(); });
  await openEditor(page, `/collab/many?document=${id}&count=3&nodes=3&name=Ada`, "editor_1");
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#many-save").click();
  await page.waitForTimeout(300);
  await expect(page.locator("#many-saved")).toHaveCount(0);
  release();
  await expect(page.locator("#many-saved")).toHaveText("||");
});

test("a submit waits for its only editor while it loads its node modules", async ({ page }) => {
  const id = crypto.randomUUID();
  let release = (): void => {};
  const held = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/assets/nodes/tag.js", async route => { await held; await route.continue(); });
  await page.goto(`/collab/many?document=${id}&count=1&nodes=1&name=Ada`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await page.locator("#many-save").click();
  await page.waitForTimeout(300);
  await expect(page.locator("#many-saved")).toHaveCount(0);
  release();
  await expect(page.locator("#many-saved")).toHaveText("");
  await expect(page.locator("#many-saved")).toHaveCount(1);
});

test("after a submit that joined a parked editor, its toolbar works", async ({ page }) => {
  const id = crypto.randomUUID();
  await open(page, `document=${id}&count=6&join=visible&park_after=200&name=Ada`);
  await editor(page, 5).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${5}`)).toHaveAttribute("data-collab-state", "saved");
  await focusEnd(page, editor(page, 5));
  await page.keyboard.type("five");
  await expect(page.locator(`#editor_${5}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#many-save").scrollIntoViewIfNeeded();
  await page.locator("#many-save").focus();
  await expect(page.locator("#editor_5")).toHaveAttribute("data-collab-state", "idle");
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("||||five|");
  await expect(page.locator("#editor_5 .kotoba-toolbar button[data-kotoba-command=bold]")).toBeEnabled();
});

test("an editor removed while it starts no longer holds the form's submit", async ({ page }) => {
  const id = crypto.randomUUID();
  await page.route("**/assets/nodes/tag.js", () => new Promise(() => {}));
  await openEditor(page, `/collab/many?document=${id}&count=3&nodes=3&name=Ada`, "editor_1");
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#many-remove").click();
  await expect(page.locator("#editor_3")).toHaveCount(0);
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("|");
});

test("an editor removed while it opens its local backup no longer holds the form's submit", async ({ page }) => {
  const id = crypto.randomUUID();
  // Editor 3's local backup never opens: its session lock is never granted.
  await page.addInitScript(hang => {
    const prototype = LockManager.prototype as unknown as { request: (...args: unknown[]) => Promise<unknown> };
    const request = prototype.request;
    prototype.request = function (this: LockManager, name: unknown, ...rest: unknown[]) {
      return String(name).includes(hang) ? new Promise(() => {}) : request.call(this, name, ...rest);
    };
  }, `${id}-3`);
  await openEditor(page, `/collab/many?document=${id}&count=3&name=Ada`, "editor_1");
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  await expect(status(page, 3)).toHaveText("Connecting…");
  await page.locator("#many-remove").click();
  await expect(page.locator("#editor_3")).toHaveCount(0);
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("|");
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("one");
  await expect(editor(page, 1)).toHaveText("one");
});

test("an editor not joined yet shows its field's saved text, read-only", async ({ page }) => {
  const id = crypto.randomUUID();
  await open(page, `document=${id}&count=12&join=visible&text=1&name=Ada`);
  await expect(editor(page, 10)).toHaveText("Block 10");
  await expect(editor(page, 10)).toHaveAttribute("contenteditable", "false");
  // Not offline: parked until it is wanted.
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "idle");
  await expect(status(page, 10)).toHaveText("Saved");
});

test("an editor scrolled out of a scrolling box parks, though it is still in the window", async ({ page }) => {
  const id = crypto.randomUUID();
  await open(page, `document=${id}&count=6&join=visible&park_after=200&scroller=1&name=Ada`);
  await page.locator("#many-scroller").evaluate(box => { box.scrollTop = 700; });
  const box = await page.locator("#editor_1").boundingBox();
  expect(box!.y + box!.height).toBeGreaterThan(0);
  await expect(page.locator("#editor_1")).toHaveAttribute("data-collab-state", "idle");
});

test("an editor removed while it opens its local backup releases its session when the backup opens", async ({ page }) => {
  const id = crypto.randomUUID();
  await page.addInitScript(hang => {
    const prototype = LockManager.prototype as unknown as { request: (...args: unknown[]) => Promise<unknown> };
    const request = prototype.request;
    let release = (): void => {};
    const held = new Promise<void>(resolve => { release = resolve; });
    (window as unknown as { releaseLock: () => void }).releaseLock = release;
    prototype.request = function (this: LockManager, name: unknown, ...rest: unknown[]) {
      return String(name).includes(hang) ? held.then(() => request.call(this, name, ...rest)) : request.call(this, name, ...rest);
    };
  }, `${id}-3`);
  await openEditor(page, `/collab/many?document=${id}&count=3&name=Ada`, "editor_1");
  await expect(status(page, 3)).toHaveText("Connecting…");
  await page.locator("#many-remove").click();
  await expect(page.locator("#editor_3")).toHaveCount(0);
  await page.evaluate(() => (window as unknown as { releaseLock: () => void }).releaseLock());
  await expect.poll(() => page.evaluate(async hang => (await navigator.locks.query()).held!.some(lock => lock.name!.includes(hang)), `${id}-3`)).toBe(false);
});

test("a box that starts clipping after the page loads parks the editors it hides", async ({ page }) => {
  const id = crypto.randomUUID();
  await open(page, `document=${id}&count=6&join=visible&park_after=200&name=Ada`);
  await page.locator("#many-scroller").evaluate(box => {
    box.setAttribute("style", "height: 240px; overflow: auto; margin-top: 600px");
    box.scrollTop = 700;
  });
  const box = await page.locator("#editor_1").boundingBox();
  expect(box!.y + box!.height).toBeGreaterThan(0);
  await expect(page.locator("#editor_1")).toHaveAttribute("data-collab-state", "idle");
});

test("a box that clips only across leaves the editors below it on screen", async ({ page }) => {
  const id = crypto.randomUUID();
  await open(page, `document=${id}&count=3&join=visible&park_after=200&scroller=x&name=Ada`);
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  await page.waitForTimeout(600);
  await expect(page.locator("#editor_2")).toHaveAttribute("data-collab-state", "saved");
});

test("a submit keeps the toolbars locked too: Undo does not change a flushed editor", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=6&join=visible&park_after=200&name=Ada`);
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("one");
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved");
  control.delays[`kotoba:${id}-6`] = 500;
  await page.locator("#many-save").click();
  await expect(page.locator("#editor_1 .kotoba-toolbar button[data-kotoba-command=undo]")).toBeDisabled();
  await expect(page.locator("#many-saved")).toHaveText("one|||||", { timeout: 15_000 });
  await expect(editor(page, 1)).toHaveText("one");
});

test("a failed flush keeps the other editors locked until theirs have settled", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=6&join=visible&park_after=200&name=Ada`);
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  control.failFlush = `kotoba:${id}-2`;
  control.delays[`kotoba:${id}-6`] = 1000;
  await page.locator("#many-save").click();
  await page.waitForTimeout(400);
  await expect(editor(page, 1)).toHaveAttribute("contenteditable", "false");
  await expect(editor(page, 1)).toHaveAttribute("contenteditable", "true", { timeout: 15_000 });
  await expect(page.locator("#many-saved")).toHaveCount(0);
});

test("a rejoin after a long disconnection renews the credentials first", async ({ page, context }) => {
  const id = crypto.randomUUID();
  const events: string[] = [];
  page.on("websocket", socket => socket.on("framesent", frame => {
    if (typeof frame.payload !== "string") return;
    const [, , topic, event, payload] = JSON.parse(frame.payload) as [string, string, string, string, { event?: string; value?: { document_id?: string } }];
    if (event === "phx_join" && topic === `kotoba:${id}-1`) events.push("join");
    if (payload?.event === "kotoba:collab_token" && payload.value?.document_id === `${id}-1`) events.push("renew");
  }));
  await page.clock.install();
  await open(page, `document=${id}&count=2&name=Ada`);
  await context.setOffline(true);
  await expect(status(page, 1)).toContainText("Offline");
  await page.clock.fastForward("05:30");
  await context.setOffline(false);
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved", { timeout: 15_000 });
  expect(events.slice(0, 3)).toEqual(["join", "renew", "join"]);
});

test("an editor opened while offline renews old credentials before it joins on reconnect", async ({ page, context }) => {
  const id = crypto.randomUUID();
  const events: string[] = [];
  page.on("websocket", socket => socket.on("framesent", frame => {
    if (typeof frame.payload !== "string") return;
    const [, , topic, event, payload] = JSON.parse(frame.payload) as [string, string, string, string, { event?: string; value?: { document_id?: string } }];
    if (event === "phx_join" && topic === `kotoba:${id}-10`) events.push("join");
    if (payload?.event === "kotoba:collab_token" && payload.value?.document_id === `${id}-10`) events.push("renew");
  }));
  await page.clock.install();
  await open(page, `document=${id}&count=12&join=visible&park_after=200&name=Ada`);
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#editor_1").scrollIntoViewIfNeeded();
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "idle");
  // Opened offline with credentials still fresh, back online after they have expired.
  await context.setOffline(true);
  await page.clock.fastForward("01:00");
  await editor(page, 10).focus();
  await page.clock.fastForward("05:00");
  await context.setOffline(false);
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "saved", { timeout: 15_000 });
  expect(events).toEqual(["join", "renew", "join"]);
});

test("a submit with the collaboration socket down gives up and unlocks the form", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  control.blocked = true;
  await page.clock.install();
  await page.goto(`/collab/many?document=${id}&count=2&name=Ada`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await page.locator("#many-save").click();
  // The wait starts once the editors have started: move the clock on until it has given up.
  await expect.poll(async () => {
    await page.clock.fastForward(5_000);
    return page.locator("#editor_1 .kotoba-live").textContent();
  }, { timeout: 15_000 }).toBe("Reconnect before saving this form");
  await expect(page.locator("#many-saved")).toHaveCount(0);
});

test("an editor opened offline and parked again does not join when back online", async ({ page, context }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await open(page, `document=${id}&count=12&join=visible&park_after=200&name=Ada`);
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#editor_1").scrollIntoViewIfNeeded();
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "idle");
  await context.setOffline(true);
  await editor(page, 10).focus();
  await editor(page, 10).blur();
  await page.locator("#editor_1").scrollIntoViewIfNeeded();
  await page.waitForTimeout(600);
  const joins = traffic.joins.filter(topic => topic === `kotoba:${id}-10`).length;
  await context.setOffline(false);
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved");
  await page.waitForTimeout(1_000);
  expect(traffic.joins.filter(topic => topic === `kotoba:${id}-10`).length).toBe(joins);
});

test("an editor added while the others flush is flushed before the form submits", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=2&name=Ada`);
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  control.delays[`kotoba:${id}-1`] = 1000;
  await page.locator("#many-save").click();
  await page.locator("#many-add").click();
  await expect(page.locator("#editor_3")).toHaveCount(1);
  await expect(page.locator("#many-saved")).toHaveText("||", { timeout: 15_000 });
});

test("an editor changed by the server after its flush is flushed again before the form submits", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=2&nodes=1&name=Ada`);
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  control.delays[`kotoba:${id}-2`] = 1500;
  await page.locator("#many-save").click();
  await page.waitForTimeout(300);
  await page.locator("#many-insert").click();
  await expect(page.locator("#editor_1 .kotoba-editable")).toContainText("tag");
  await expect(page.locator("#many-saved")).toHaveText(/^[^?|]+\|$/, { timeout: 15_000 });
});

test("an editor whose flush failed and that is removed no longer fails the submit", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=3&name=Ada`);
  await expect(page.locator(`#editor_${3}`)).toHaveAttribute("data-collab-state", "saved");
  control.failFlush = `kotoba:${id}-3`;
  control.delays[`kotoba:${id}-1`] = 1500;
  await page.locator("#many-save").click();
  await page.waitForTimeout(300);
  await page.locator("#many-remove").click();
  await expect(page.locator("#editor_3")).toHaveCount(0);
  await expect(page.locator("#many-saved")).toHaveText("|", { timeout: 15_000 });
});

test("a server insert into an editor not joined yet waits for its join", async ({ page }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await open(page, `document=${id}&count=12&join=visible&nodes=12&name=Ada`);
  expect(traffic.joins).not.toContain(`kotoba:${id}-12`);
  await page.locator("#many-insert").click();
  await page.locator("#editor_12").scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${12}`)).toHaveAttribute("data-collab-state", "saved");
  await expect(editor(page, 12)).toContainText("tag");
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText(/\|[^?|]+$/);
});

test("a channel error with old credentials renews them before the channel joins again", async ({ page }) => {
  const id = crypto.randomUUID();
  const events: string[] = [];
  page.on("websocket", socket => socket.on("framesent", frame => {
    if (typeof frame.payload !== "string") return;
    const [, , topic, event, payload] = JSON.parse(frame.payload) as [string, string, string, string, { event?: string; value?: { document_id?: string } }];
    if (event === "phx_join" && topic === `kotoba:${id}-1`) events.push("join");
    if (payload?.event === "kotoba:collab_token" && payload.value?.document_id === `${id}-1`) events.push("renew");
  }));
  const control = await route(page);
  await page.clock.install();
  await open(page, `document=${id}&count=2&join=visible&name=Ada`);
  // The credentials age past four minutes (no timer runs), then the channel fails while the
  // socket stays up.
  events.length = 0;
  await page.clock.setSystemTime(Date.now() + 6 * 60_000);
  control.crash(`kotoba:${id}-1`);
  await page.clock.runFor(3_000);
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved", { timeout: 15_000 });
  expect(events.slice(0, 2)).toEqual(["renew", "join"]);
});

test("a server insert waiting for a join while the socket is down is not dropped by parking", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  const traffic = watch(page);
  await open(page, `document=${id}&count=12&join=visible&park_after=200&nodes=12&name=Ada`);
  control.blocked = true;
  await page.context().setOffline(true);
  await page.context().setOffline(false);
  await expect(status(page, 1)).toContainText("Offline");
  // Editor 12 comes on screen (a join deferred until the socket opens), takes an insert, and
  // leaves the screen again past park_after.
  await page.locator("#editor_12").scrollIntoViewIfNeeded();
  await page.locator("#many-insert").click();
  await page.locator("#editor_1").scrollIntoViewIfNeeded();
  await page.waitForTimeout(600);
  control.blocked = false;
  await expect.poll(() => traffic.joins.includes(`kotoba:${id}-12`), { timeout: 15_000 }).toBe(true);
  await page.locator("#editor_12").scrollIntoViewIfNeeded();
  await expect(editor(page, 12)).toContainText("tag");
});

test("a join refused as expired renews once and joins again with the new credentials", async ({ page }) => {
  const id = crypto.randomUUID();
  // The LiveView answers the renewal after 2.5 s: longer than Phoenix's first channel retry.
  await page.routeWebSocket(/\/live\/websocket/, socket => {
    const server = socket.connectToServer();
    server.onMessage(message => {
      if (typeof message === "string" && message.includes("park_after")) setTimeout(() => socket.send(message), 2_500);
      else socket.send(message);
    });
  });
  const control = await route(page);
  await open(page, `document=${id}&count=12&join=visible&park_after=200&name=Ada`);
  const topic = `kotoba:${id}-10`;
  control.expire = topic;
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved", { timeout: 15_000 });
  const [refused, ...after] = control.tokens[topic];
  expect(after).toHaveLength(1);
  expect(after[0]).not.toBe(refused);
});

test("a join refused as expired whose renewal is refused freezes the draft instead of joining again", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=12&join=visible&park_after=200&deny=1&name=Ada`);
  const topic = `kotoba:${id}-10`;
  control.expire = topic;
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(status(page, 10)).toHaveText("Access to this shared document is unavailable. Your local draft is preserved.");
  await page.waitForTimeout(1_000);
  expect(control.tokens[topic]).toHaveLength(1);
});

test("old credentials whose renewal is refused freeze the draft instead of joining", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await page.clock.install();
  await open(page, `document=${id}&count=12&join=visible&park_after=200&deny=1&name=Ada`);
  const topic = `kotoba:${id}-10`;
  await page.clock.setSystemTime(Date.now() + 5 * 60_000);
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(status(page, 10)).toHaveText("Access to this shared document is unavailable. Your local draft is preserved.");
  expect(control.tokens[topic]).toBeUndefined();
});

test("a joined editor whose periodic renewal is refused freezes the draft", async ({ page }) => {
  const id = crypto.randomUUID();
  await page.clock.install();
  await open(page, `document=${id}&count=2&deny=1&name=Ada`);
  await page.clock.fastForward("03:05");
  await expect(status(page, 1)).toHaveText("Access to this shared document is unavailable. Your local draft is preserved.");
  await expect(editor(page, 1)).toHaveAttribute("contenteditable", "false");
});

test("a form with a shared editor that could not start refuses to submit", async ({ page }) => {
  const id = crypto.randomUUID();
  // Editor 3's start throws (its visibility watch cannot start).
  await page.addInitScript(() => {
    const observe = IntersectionObserver.prototype.observe;
    IntersectionObserver.prototype.observe = function (this: IntersectionObserver, target: Element) {
      if (target.id === "editor_3") throw new Error("broken");
      observe.call(this, target);
    };
  });
  await openEditor(page, `/collab/many?document=${id}&count=3&join=visible&name=Ada`, "editor_1");
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#many-save").click();
  await expect(page.locator(".kotoba-live", { hasText: "A shared editor of this form could not start" })).not.toHaveCount(0);
  await expect(page.locator("#many-saved")).toHaveCount(0);
  // Without it, the form submits again.
  await page.locator("#many-remove").click();
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("|");
});

test("a channel retry whose credentials grow old during the backoff renews them first", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await page.clock.install();
  await open(page, `document=${id}&count=2&join=visible&name=Ada`);
  const topic = `kotoba:${id}-1`;
  // Just under four minutes old when the channel fails; over four by the retry.
  await page.clock.setSystemTime(Date.now() + 3 * 60_000 + 59_500);
  control.crash(topic);
  await page.clock.runFor(3_000);
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved", { timeout: 15_000 });
  const [first, ...after] = control.tokens[topic];
  expect(after.length).toBeGreaterThan(0);
  expect(after[0]).not.toBe(first);
});

test("removing a started editor keeps a later editor that could not start in the form's guard", async ({ page }) => {
  const id = crypto.randomUUID();
  await page.addInitScript(() => {
    const observe = IntersectionObserver.prototype.observe;
    IntersectionObserver.prototype.observe = function (this: IntersectionObserver, target: Element) {
      if (target.id === "editor_3") throw new Error("broken");
      observe.call(this, target);
    };
  });
  await open(page, `document=${id}&count=2&join=visible&name=Ada`);
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#many-add").click();
  await expect(page.locator("#editor_3")).toHaveCount(1);
  await page.locator("#many-remove-first").click();
  await expect(page.locator("#editor_1")).toHaveCount(0);
  await page.locator("#many-save").click();
  await expect(page.locator(".kotoba-live", { hasText: "A shared editor of this form could not start" })).not.toHaveCount(0);
});

test("a channel retry does not reopen an editor that has parked meanwhile", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=12&join=visible&park_after=2000&name=Ada`);
  const topic = `kotoba:${id}-10`;
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(page.locator(`#editor_${10}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#editor_1").scrollIntoViewIfNeeded();
  control.crash(topic);
  await page.waitForTimeout(2_500);
  expect(control.tokens[topic]).toHaveLength(1);
  // Parked, not offline.
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "idle");
});

test("a server insert does not change a frozen draft", async ({ page }) => {
  const id = crypto.randomUUID();
  await page.clock.install();
  await open(page, `document=${id}&count=2&deny=1&nodes=1&name=Ada`);
  await page.clock.fastForward("03:05");
  await expect(status(page, 1)).toHaveText("Access to this shared document is unavailable. Your local draft is preserved.");
  await page.locator("#many-insert").click();
  await page.clock.runFor(1_000);
  await expect(editor(page, 1)).not.toContainText("tag");
});

test("typing while a channel retry waits does not join before the backoff", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=2&name=Ada`);
  const topic = `kotoba:${id}-1`;
  await focusEnd(page, editor(page, 1));
  control.crash(topic);
  await page.keyboard.type("abc");
  await page.waitForTimeout(400);
  expect(control.tokens[topic]).toHaveLength(1);
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved", { timeout: 10_000 });
  await expect(editor(page, 1)).toHaveText("abc");
});

test("a held submit whose button is gone meanwhile still submits, and the editor keeps working", async ({ page }) => {
  const id = crypto.randomUUID();
  let release = (): void => {};
  const held = new Promise<void>(resolve => { release = resolve; });
  await page.route("**/assets/nodes/tag.js", async route => { await held; await route.continue(); });
  await page.goto(`/collab/many?document=${id}&count=1&nodes=1&name=Ada`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await page.locator("#many-save").click();
  // The button is replaced, as a LiveView patch can.
  await page.evaluate(() => { const button = document.getElementById("many-save")!; button.replaceWith(button.cloneNode(true)); });
  release();
  await expect(page.locator("#many-saved")).toHaveCount(1);
  await page.locator("#many-insert").click();
  await expect(editor(page, 1)).toContainText("tag");
});

test("a resubmit stopped by the browser's validation leaves the next submit to flush again", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=1&required=1&name=Ada`);
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("one");
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved");
  control.delays[`kotoba:${id}-1`] = 800;
  await page.locator("#many-save").click();
  await page.locator("#many-required").fill("");
  await page.waitForTimeout(2_000);
  await expect(page.locator("#many-saved")).toHaveCount(0);
  control.delays = {};
  await page.locator("#many-required").fill("x");
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type(" two");
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("one two");
});

test("a lazy editor that leaves the screen while its credentials renew does not join", async ({ page }) => {
  const id = crypto.randomUUID();
  await page.routeWebSocket(/\/live\/websocket/, socket => {
    const server = socket.connectToServer();
    server.onMessage(message => {
      if (typeof message === "string" && message.includes("park_after")) setTimeout(() => socket.send(message), 2_500);
      else socket.send(message);
    });
  });
  const control = await route(page);
  await page.clock.install();
  await open(page, `document=${id}&count=12&join=visible&park_after=200&name=Ada`);
  await page.clock.setSystemTime(Date.now() + 5 * 60_000);
  await editor(page, 10).scrollIntoViewIfNeeded();
  await page.locator("#editor_1").scrollIntoViewIfNeeded();
  // The renewal's answer comes after 2.5 s of real time.
  await page.waitForTimeout(3_500);
  await page.clock.runFor(1_000);
  expect(control.tokens[`kotoba:${id}-10`]).toBeUndefined();
});

test("an editor whose credentials cannot be read refuses the form's submit until it is removed", async ({ page }) => {
  const id = crypto.randomUUID();
  await openEditor(page, `/collab/many?document=${id}&count=3&badcollab=3&name=Ada`, "editor_1");
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#many-save").click();
  await page.waitForTimeout(500);
  await expect(page.locator("#many-saved")).toHaveCount(0);
  await page.locator("#many-remove").click();
  await expect(page.locator("#editor_3")).toHaveCount(0);
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("|");
});

test("joins refused as expired again and again after renewals are paced by the backoff", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=12&join=visible&park_after=200&name=Ada`);
  const topic = `kotoba:${id}-10`;
  control.expireAlways = topic;
  await editor(page, 10).scrollIntoViewIfNeeded();
  await page.waitForTimeout(3_500);
  expect(control.tokens[topic].length).toBeLessThanOrEqual(5);
});

test("the app making an editor writable during a submit does not unlock it before the flushes settle", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=2&name=Ada`);
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  control.delays[`kotoba:${id}-2`] = 1_500;
  await page.locator("#many-save").click();
  await page.locator("#many-writable").click();
  await page.waitForTimeout(300);
  await expect(editor(page, 1)).toHaveAttribute("contenteditable", "false");
  await expect(page.locator("#many-saved")).toHaveText("|", { timeout: 15_000 });
  await expect(editor(page, 1)).toHaveAttribute("contenteditable", "true");
});

test("the editors of a nested LiveView share the page's socket, and their form submits", async ({ page }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await openEditor(page, `/collab/nested?document=${id}&count=3&name=Ada`, "editor_1");
  await expect(page.locator("#parent_editor [data-collab-status]")).toHaveText("Saved");
  for (let n = 1; n <= 3; n++) await expect(page.locator(`#editor_${n}`)).toHaveAttribute("data-collab-state", "saved");
  expect(traffic.sockets).toHaveLength(1);
  expect(new Set(traffic.joins).size).toBe(4);
  await focusEnd(page, editor(page, 2));
  await page.keyboard.type("two");
  await expect(page.locator(`#editor_${2}`)).toHaveAttribute("data-collab-state", "saved");
  await page.locator("#many-save").click();
  await expect(page.locator("#many-saved")).toHaveText("|two|");
});

test("a nested editor renews old credentials through its own LiveView", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await page.clock.install();
  await openEditor(page, `/collab/nested?document=${id}&count=2&name=Ada`, "editor_1");
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved");
  const topic = `kotoba:${id}-1`;
  await page.clock.setSystemTime(Date.now() + 5 * 60_000);
  control.crash(topic);
  await page.clock.runFor(3_000);
  await expect(page.locator(`#editor_${1}`)).toHaveAttribute("data-collab-state", "saved", { timeout: 15_000 });
  const [first, ...after] = control.tokens[topic];
  expect(after.length).toBeGreaterThan(0);
  expect(after[0]).not.toBe(first);
});

test("an editor's status follows its connection: offline while it waits to retry, parked once unwanted", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=12&join=visible&park_after=200&name=Ada`);
  const topic = `kotoba:${id}-10`;
  await editor(page, 10).scrollIntoViewIfNeeded();
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "saved");
  control.delays[topic] = 3_000;
  control.crash(topic);
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "offline");
  await page.locator("#editor_1").scrollIntoViewIfNeeded();
  await expect(page.locator("#editor_10")).toHaveAttribute("data-collab-state", "idle", { timeout: 10_000 });
});

test("an editor that fails to start while the form submits refuses the submit", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  await open(page, `document=${id}&count=2&badcollab=3&name=Ada`);
  await expect(page.locator("#editor_2")).toHaveAttribute("data-collab-state", "saved");
  control.delays[`kotoba:${id}-1`] = 1_500;
  await page.locator("#many-save").click();
  await page.locator("#many-add").click();
  await expect(page.locator("#editor_3")).toHaveCount(1);
  await expect(page.locator(".kotoba-live", { hasText: "A shared editor of this form could not start" })).not.toHaveCount(0, { timeout: 10_000 });
  await expect(page.locator("#many-saved")).toHaveCount(0);
});

