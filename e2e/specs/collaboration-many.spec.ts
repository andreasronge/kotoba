import { expect, test, type Page, type WebSocketRoute } from "@playwright/test";
import { documentEnd, focusEnd, openEditor, settle } from "./support";

// A page of many shared editors, as a document of many text blocks.
const editor = (page: Page, n: number) => page.locator(`#editor_${n} .kotoba-editable`);
const status = (page: Page, n: number) => page.locator(`#editor_${n} [data-collab-status]`);

async function open(page: Page, query: string, first = 1): Promise<void> {
  await openEditor(page, `/collab/many?${query}`, `editor_${first}`);
  await expect(status(page, first)).toHaveText("Saved");
}

interface Traffic { sockets: string[]; closed: number; joins: string[]; leaves: string[] }

// The collaboration sockets the page opens and closes, and the channel joins and leaves it sends on them.
function watch(page: Page): Traffic {
  const traffic: Traffic = { sockets: [], closed: 0, joins: [], leaves: [] };
  page.on("websocket", socket => {
    if (!socket.url().includes("/kotoba/socket")) return;
    traffic.sockets.push(socket.url());
    socket.on("close", () => { traffic.closed += 1; });
    socket.on("framesent", frame => {
      if (typeof frame.payload !== "string") return;
      const [, , topic, event] = JSON.parse(frame.payload) as [string, string, string, string];
      if (event === "phx_join") traffic.joins.push(topic);
      if (event === "phx_leave") traffic.leaves.push(topic);
    });
  });
  return traffic;
}

const count = (values: string[], value: string): number => values.filter(v => v === value).length;

// Routes the collaboration socket: `blocked` refuses new connections, `drop()` closes the current
// one as an unreachable server does, `hold` drops what the server sends on one topic, and `skip`
// drops the next transaction broadcast on one topic, and `slowLeave` holds the page's channel leaves
// back for that many milliseconds.
interface Control { blocked: boolean; hold: string | null; skip: string | null; slowLeave: number; drop: () => void }
async function route(page: Page): Promise<Control> {
  let current: WebSocketRoute | null = null;
  const control: Control = { blocked: false, hold: null, skip: null, slowLeave: 0, drop: () => void current?.close({ code: 4000, reason: "dropped" }) };
  await page.routeWebSocket(/\/kotoba\/socket/, socket => {
    // An abnormal close: Phoenix reconnects only then.
    if (control.blocked) { void socket.close({ code: 4000, reason: "blocked" }); return; }
    current = socket;
    const server = socket.connectToServer();
    socket.onMessage(message => {
      const event = typeof message === "string" ? (JSON.parse(message) as string[])[3] : null;
      if (event === "phx_leave" && control.slowLeave > 0) setTimeout(() => server.send(message), control.slowLeave);
      else server.send(message);
    });
    server.onMessage(message => {
      const [, , topic, event] = typeof message === "string" ? JSON.parse(message) as string[] : [];
      if (topic === control.hold) return;
      if (topic === control.skip && event === "transaction") { control.skip = null; return; }
      socket.send(message);
    });
  });
  return control;
}

test("the editors of a page share one socket, each with its own channel", async ({ page, browser }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await open(page, `document=${id}&count=6&name=Ada`);
  for (let n = 1; n <= 6; n++) await expect(status(page, n)).toHaveText("Saved");
  expect(traffic.sockets).toHaveLength(1);
  expect(new Set(traffic.joins).size).toBe(6);

  const context = await browser.newContext();
  const other = await context.newPage();
  await open(other, `document=${id}&count=6&name=Grace`);
  await expect(status(other, 5)).toHaveText("Saved");
  await focusEnd(other, editor(other, 5));
  await other.keyboard.type("five");
  await expect(editor(page, 5)).toHaveText("five");
  await expect(editor(page, 4)).toHaveText("");
  await context.close();
});

test("a second editor of the same document gets its own socket", async ({ page }) => {
  const traffic = watch(page);
  await open(page, `document=${crypto.randomUUID()}&count=3&name=Ada&repeat=1`);
  await expect(status(page, 4)).toHaveText("Saved");
  expect(traffic.sockets).toHaveLength(2);
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("twice");
  await expect(editor(page, 4)).toHaveText("twice");
});

test("removing an editor leaves its channel only, a new editor joins on the same socket, and the last one closes it", async ({ page, browser }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await open(page, `document=${id}&count=3&name=Ada`);
  await expect(status(page, 3)).toHaveText("Saved");
  await page.locator("#many-remove").click();
  await expect(page.locator("#editor_3")).toHaveCount(0);
  await expect.poll(() => traffic.leaves).toEqual([`kotoba:${id}-3`]);

  const context = await browser.newContext();
  const other = await context.newPage();
  await open(other, `document=${id}&count=3&name=Grace`);
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("still here");
  await expect(editor(other, 1)).toHaveText("still here");

  await page.locator("#many-add").click();
  await expect(status(page, 4)).toHaveText("Saved");
  await focusEnd(page, editor(page, 4));
  await page.keyboard.type("new");
  await expect(status(page, 4)).toHaveText("Saved");
  expect(traffic.joins).toContain(`kotoba:${id}-4`);
  expect(traffic.sockets).toHaveLength(1);
  expect(traffic.closed).toBe(0);

  for (let n = 3; n >= 1; n--) await page.locator("#many-remove").click();
  await expect(page.locator("#editor_1")).toHaveCount(0);
  await expect.poll(() => traffic.closed).toBe(1);
  await context.close();
});

test("an editor past Phoenix's channel limit of a socket gets another socket", async ({ page }) => {
  test.setTimeout(60_000);
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await open(page, `document=${id}&count=101&name=Ada`);
  await expect(status(page, 101)).toHaveText("Saved", { timeout: 30_000 });
  for (let n = 1; n <= 101; n++) await expect(page.locator(`#editor_${n}`)).toHaveAttribute("data-collab-state", "saved");
  expect(traffic.sockets).toHaveLength(2);
});

test("an editor that replaces another on a full socket joins once the server has let the other go", async ({ page }) => {
  test.setTimeout(60_000);
  const id = crypto.randomUUID();
  const control = await route(page);
  const traffic = watch(page);
  await open(page, `document=${id}&count=100&name=Ada`);
  for (let n = 1; n <= 100; n++) await expect(page.locator(`#editor_${n}`)).toHaveAttribute("data-collab-state", "saved", { timeout: 30_000 });
  // The server still counts the removed editor's channel when the new editor's join arrives.
  control.slowLeave = 1_000;
  await page.locator("#many-remove").click();
  await page.locator("#many-add").click();
  await expect(status(page, 101)).toHaveText("Saved", { timeout: 15_000 });
  expect(count(traffic.joins, `kotoba:${id}-101`)).toBeGreaterThan(1);
  expect(traffic.sockets).toHaveLength(1);
});

test("the editors of a nested LiveView share the socket with the parent's editor", async ({ page }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await openEditor(page, `/collab/nested?document=${id}&count=2&name=Ada`, "parent_editor");
  for (const element of ["parent_editor", "editor_1", "editor_2"]) await expect(page.locator(`#${element}`)).toHaveAttribute("data-collab-state", "saved");
  expect(traffic.sockets).toHaveLength(1);
  expect(new Set(traffic.joins)).toEqual(new Set([`kotoba:${id}-parent`, `kotoba:${id}-1`, `kotoba:${id}-2`]));
});

test("offline and back online, every editor joins again on one socket", async ({ page, context, browser }) => {
  const id = crypto.randomUUID();
  const traffic = watch(page);
  await open(page, `document=${id}&count=3&name=Ada`);
  for (let n = 1; n <= 3; n++) await expect(status(page, n)).toHaveText("Saved");
  await context.setOffline(true);
  for (let n = 1; n <= 3; n++) await expect(page.locator(`#editor_${n}`)).toHaveAttribute("data-collab-state", "offline");
  await focusEnd(page, editor(page, 2));
  await page.keyboard.type("typed offline");
  await context.setOffline(false);
  for (let n = 1; n <= 3; n++) await expect(status(page, n)).toHaveText("Saved");
  expect(traffic.sockets).toHaveLength(2);

  const otherContext = await browser.newContext();
  const other = await otherContext.newPage();
  await open(other, `document=${id}&count=3&name=Grace`);
  await expect(editor(other, 2)).toHaveText("typed offline");
  await otherContext.close();
});

test("an editor whose push times out joins again alone while the others keep editing", async ({ page, browser }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  const traffic = watch(page);
  await page.clock.install();
  await open(page, `document=${id}&count=3&name=Ada`);
  for (let n = 1; n <= 3; n++) await expect(status(page, n)).toHaveText("Saved");
  const context = await browser.newContext();
  const other = await context.newPage();
  await open(other, `document=${id}&count=3&name=Grace`);

  control.hold = `kotoba:${id}-2`;
  await focusEnd(page, editor(page, 2));
  await page.keyboard.type("two");
  await expect(status(page, 2)).toHaveText("Saving…");
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("one");
  await expect(editor(other, 1)).toHaveText("one");
  await expect(status(page, 1)).toHaveText("Saved");
  await focusEnd(other, editor(other, 3));
  await other.keyboard.type("three");
  await expect(editor(page, 3)).toHaveText("three");

  control.hold = null;
  await page.clock.fastForward(16_000);
  await expect(status(page, 2)).toHaveText("Saved");
  await expect(editor(other, 2)).toHaveText("two");
  expect(traffic.leaves).toEqual([`kotoba:${id}-2`]);
  expect(count(traffic.joins, `kotoba:${id}-2`)).toBe(2);
  expect(count(traffic.joins, `kotoba:${id}-1`)).toBe(1);
  expect(traffic.sockets).toHaveLength(1);

  await focusEnd(page, editor(page, 1));
  await page.keyboard.type(" more");
  await expect(editor(other, 1)).toHaveText("one more");
  await context.close();
});

test("an editor removed while the socket reconnects leaves the others to join again", async ({ page }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  const traffic = watch(page);
  await open(page, `document=${id}&count=3&name=Ada`);
  for (let n = 1; n <= 3; n++) await expect(status(page, n)).toHaveText("Saved");
  control.blocked = true;
  control.drop();
  for (let n = 1; n <= 3; n++) await expect(page.locator(`#editor_${n}`)).toHaveAttribute("data-collab-state", "offline");
  await page.locator("#many-remove").click();
  await expect(page.locator("#editor_3")).toHaveCount(0);
  const joinsBefore = traffic.joins.length;
  control.blocked = false;
  for (let n = 1; n <= 2; n++) await expect(status(page, n)).toHaveText("Saved", { timeout: 15_000 });
  const rejoined = traffic.joins.slice(joinsBefore);
  expect(new Set(rejoined)).toEqual(new Set([`kotoba:${id}-1`, `kotoba:${id}-2`]));
  await focusEnd(page, editor(page, 2));
  await page.keyboard.type("after");
  await expect(status(page, 2)).toHaveText("Saved");
});

test("a colleague's edit in another editor of the page leaves the caret where it is", async ({ page, browser }) => {
  const id = crypto.randomUUID();
  await open(page, `document=${id}&count=3&name=Ada`);
  await expect(status(page, 2)).toHaveText("Saved");
  await focusEnd(page, editor(page, 2));
  await page.keyboard.type("two");
  await focusEnd(page, editor(page, 1));
  await page.keyboard.type("one");

  const context = await browser.newContext();
  const other = await context.newPage();
  await open(other, `document=${id}&count=3&name=Grace`);
  await expect(status(other, 2)).toHaveText("Saved");
  await focusEnd(other, editor(other, 2));
  await other.keyboard.type("!");
  await expect(editor(page, 2)).toHaveText("two!");
  await expect(editor(page, 1)).toBeFocused();
  await page.keyboard.type(" more");
  await expect(editor(page, 1)).toHaveText("one more");
  await expect(editor(page, 2)).toHaveText("two!");
  await context.close();
});

test("keyboard undo and redo return focus to the collaborative editor", async ({ page }) => {
  await open(page, `document=${crypto.randomUUID()}&count=1&name=Ada`);
  const editable = editor(page, 1);
  const toolbar = page.locator("#editor_1 [role=toolbar]");
  await focusEnd(page, editable);
  await page.keyboard.type("to undo");
  await settle(page);
  await page.keyboard.press("Shift+Tab");
  await page.keyboard.press("End");
  await page.keyboard.press("ArrowLeft");

  const undo = toolbar.getByRole("button", { name: "Undo", exact: true });
  await expect(undo).toBeFocused();
  await expect(undo).toHaveAttribute("aria-disabled", "false");
  await page.keyboard.press("Enter");
  await expect(editable).not.toHaveText("to undo");
  await expect(editable).toBeFocused();

  await settle(page);
  await page.keyboard.press("Shift+Tab");
  await expect(undo).toBeFocused();
  await page.keyboard.press("ArrowRight");
  await expect(toolbar.getByRole("button", { name: "Redo", exact: true })).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(editable).toHaveText("to undo");
  await expect(editable).toBeFocused();
  await documentEnd(page);
  await settle(page);
  await page.keyboard.type(" more");
  await expect(editable).toHaveText("to undo more");
});

test("an editor that missed a revision joins again alone", async ({ page, browser }) => {
  const id = crypto.randomUUID();
  const control = await route(page);
  const traffic = watch(page);
  await open(page, `document=${id}&count=3&name=Ada`);
  for (let n = 1; n <= 3; n++) await expect(status(page, n)).toHaveText("Saved");
  const context = await browser.newContext();
  const other = await context.newPage();
  await open(other, `document=${id}&count=3&name=Grace`);

  control.skip = `kotoba:${id}-2`;
  await focusEnd(other, editor(other, 2));
  await other.keyboard.type("a");
  await expect(status(other, 2)).toHaveText("Saved");
  await other.keyboard.type("b");
  await expect(editor(page, 2)).toHaveText("ab");
  expect(traffic.leaves).toEqual([`kotoba:${id}-2`]);
  expect(count(traffic.joins, `kotoba:${id}-2`)).toBe(2);
  expect(count(traffic.joins, `kotoba:${id}-1`)).toBe(1);
  expect(traffic.sockets).toHaveLength(1);
  await context.close();
});
