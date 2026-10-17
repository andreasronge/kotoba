import { expect, test } from "@playwright/test";

import { expectNodes, openEditor, pasteData, pasteText } from "./support";

const README = `# Kotoba

Rich text for **Phoenix**, with *Markdown*.

> A quote of blocks:
>
> - first
> - second

| Feature | Status |
| :-- | --: |
| Tables | done |

![Logo](/images/logo.png "The logo")

A note[^1].

[^1]: The footnote.
`;

test.beforeEach(async ({ page }) => {
  const editable = await openEditor(page);
  await editable.click();
});

test("pasted Markdown becomes rich text, read by the server", async ({ page }) => {
  const editable = page.locator("#post_body_editor .kotoba-editable");
  await pasteText(page, editable, README);

  await expect(editable.locator("h1")).toHaveText("Kotoba");
  await expect(editable.locator("strong")).toHaveText("Phoenix");
  await expect(editable.locator("blockquote li")).toHaveText(["first", "second"]);
  await expect(editable.locator("table td").first()).toHaveText("Tables");
  await expect(editable.locator(".kotoba-image img")).toHaveAttribute("alt", "Logo");
  await expect(editable.locator(".kotoba-footnote-ref")).toHaveText("1");
  await expect(editable.locator(".kotoba-footnote")).toHaveText("The footnote.");

  expect((await expectNodes(page, "quote", 1))[0]?.shadowRoot).toBe(true);
  expect((await expectNodes(page, "image", 1))[0]).toMatchObject({ url: "/images/logo.png", alt: "Logo", title: "The logo" });
  expect((await expectNodes(page, "footnotedefinition", 1))[0]?.label).toBe("1");
});

test("plain text with no Markdown pastes as text", async ({ page }) => {
  const editable = page.locator("#post_body_editor .kotoba-editable");
  await pasteText(page, editable, "Just a sentence.");
  await expect(editable.locator("p").last()).toHaveText("Just a sentence.");
});

test("rich HTML keeps Lexical's own paste", async ({ page }) => {
  const editable = page.locator("#post_body_editor .kotoba-editable");
  await pasteData(page, editable, { html: "<p><em>from a page</em></p>", text: "# not a heading" });
  await expect(editable.locator("em")).toHaveText("from a page");
  await expect(editable.locator("h1")).toHaveCount(0);
});

test("in a code block, Markdown pastes as text", async ({ page }) => {
  const editable = page.locator("#post_body_editor .kotoba-editable");
  await page.keyboard.type("```");
  await page.keyboard.press("Space");
  await pasteText(page, editable, "# not a heading");
  await expect(editable.locator("code")).toContainText("# not a heading");
  await expect(editable.locator("h1")).toHaveCount(0);
});
