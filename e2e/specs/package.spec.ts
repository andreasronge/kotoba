import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { expect, test } from "@playwright/test";

const root = resolve(__dirname, "../..");

test("the package can be required and imported from Node", () => {
  // A project with the package in node_modules, whatever the name of the
  // checkout directory.
  const project = mkdtempSync(join(tmpdir(), "kotoba-package-"));
  try {
    mkdirSync(join(project, "node_modules"));
    symlinkSync(root, join(project, "node_modules", "kotoba"), "dir");

    const script = `
      const cjs = Object.keys(require("kotoba")).sort().join(",");
      import("kotoba").then((esm) => console.log(cjs + "|" + Object.keys(esm).sort().join(",")));
    `;
    const output = execFileSync(process.execPath, ["-e", script], { cwd: project });
    expect(output.toString().trim()).toBe("AttachmentNode,FootnoteDefinitionNode,FootnoteReferenceNode,GalleryNode,ImageNode,Kotoba,MentionNode,highlightRenderedContent,registerCollaboration|AttachmentNode,FootnoteDefinitionNode,FootnoteReferenceNode,GalleryNode,ImageNode,Kotoba,MentionNode,highlightRenderedContent,registerCollaboration");
  } finally {
    rmSync(project, { recursive: true, force: true });
  }
});
