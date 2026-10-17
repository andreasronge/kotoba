import { expect, test } from "@playwright/test";

import { openEditor, readDocument, settle } from "./support";

async function typeWithBlankLines(page: import("@playwright/test").Page): Promise<void> {
  await page.keyboard.type("Hello");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Enter");
  await page.keyboard.type("World");
  await settle(page);
}

function paragraphs(doc: Awaited<ReturnType<typeof readDocument>>): string[] {
  return (doc.root.children ?? []).map((node) =>
    (node.children ?? []).map((child) => String(child.text ?? "")).join(""),
  );
}

test("the blank lines a person types are saved, as in a word processor", async ({ page }) => {
  const editable = await openEditor(page);
  await editable.click();
  await typeWithBlankLines(page);

  await expect.poll(async () => paragraphs(await readDocument(page))).toEqual(["Hello", "", "", "World"]);
});

test("with blank_lines={:collapse}, they stay on screen and are left out of the saved document", async ({ page }) => {
  const editable = await openEditor(page, "/?blank_lines=collapse");
  await editable.click();
  await typeWithBlankLines(page);

  await expect(editable.locator("p")).toHaveCount(4);
  await expect.poll(async () => paragraphs(await readDocument(page))).toEqual(["Hello", "World"]);
});
