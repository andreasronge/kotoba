import { expect, test, type Page } from "@playwright/test";
import { documentEnd, focusEnd, openEditor, settle } from "./support";

// A page of many shared editors, as a document of many text blocks.
const editor = (page: Page, n: number) => page.locator(`#editor_${n} .kotoba-editable`);
const status = (page: Page, n: number) => page.locator(`#editor_${n} [data-collab-status]`);

async function open(page: Page, query: string, first = 1): Promise<void> {
  await openEditor(page, `/collab/many?${query}`, `editor_${first}`);
  await expect(status(page, first)).toHaveText("Saved");
}

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
