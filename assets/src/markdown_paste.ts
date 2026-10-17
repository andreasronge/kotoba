// Pasted Markdown. When a paste has plain text that reads as Markdown (a
// heading, a list, a quote, a fence, a table, emphasis, a link...) and no
// rich HTML (none, or the HTML of a code editor: no headings, paragraphs,
// lists or links), the server reads it with the same parser as
// `Kotoba.Content.from_markdown/2` and replies with the nodes, which go in
// at the selection. So a pasted README looks as it does on GitHub, and as
// it would after a save.
//
// The server's half is the `Kotoba.MarkdownPaste` LiveComponent that
// `<.kotoba>` renders next to the editor (`data-markdown`): no event
// handler in the app. With no reply (the LiveView is away), the text goes
// in as plain text. In a code block, a paste is always plain text.

import { $isCodeNode } from "@lexical/code-core";
import { $generateNodesFromSerializedNodes, $insertGeneratedNodes, type BaseSerializedNode } from "@lexical/clipboard";
import { $findMatchingParent } from "@lexical/utils";
import {
  $getRoot,
  $getSelection,
  $isRangeSelection,
  COMMAND_PRIORITY_LOW,
  PASTE_COMMAND,
  type LexicalEditor,
} from "lexical";

export interface MarkdownPasteOptions {
  /** Sends the Markdown to the server, and calls `reply` with its answer. */
  request: (markdown: string, reply: (payload: unknown) => void) => void;
  announce: (message: string) => void;
  /** How long to wait for the server, in milliseconds. */
  timeout?: number;
}

// Block syntax at the start of a line, or inline syntax anywhere.
const BLOCK = /^(?: {0,3})(?:#{1,6}\s|>|[-*+]\s|\d{1,9}[.)]\s|```|~~~|\|.*\||\[\^[^\]]+\]:)/m;
const INLINE = /\*\*[^*\s][^*]*\*\*|__[^_\s][^_]*__|(?<![\w*])\*[^*\s][^*]*\*(?![\w*])|~~[^~]+~~|`[^`\n]+`|!?\[[^\]\n]+\]\([^)\s]+[^)]*\)|\[\^[^\]\s]+\]/;
// The tags of rich HTML, which Lexical's own HTML import keeps.
const RICH_HTML = /<(?:p|h[1-6]|ul|ol|li|table|blockquote|a|strong|b|em|i|img)[\s>]/i;

/** Returns `true` when plain text reads as Markdown. */
export function looksLikeMarkdown(text: string): boolean {
  return text.trim() !== "" && (BLOCK.test(text) || INLINE.test(text));
}

/** Returns `true` for the HTML of a rich paste (a page, a document). */
export function isRichHtml(html: string): boolean {
  return RICH_HTML.test(html);
}

export function registerMarkdownPaste(editor: LexicalEditor, options: MarkdownPasteOptions): () => void {
  return editor.registerCommand(
    PASTE_COMMAND,
    (event) => {
      if (!(event instanceof ClipboardEvent) || event.clipboardData === null) return false;
      const text = event.clipboardData.getData("text/plain");
      const html = event.clipboardData.getData("text/html");
      if (!looksLikeMarkdown(text) || (html !== "" && isRichHtml(html))) return false;

      const selection = $getSelection();
      if ($isRangeSelection(selection) && $findMatchingParent(selection.anchor.getNode(), $isCodeNode)) return false;

      event.preventDefault();
      let done = false;
      const fallback = window.setTimeout(() => {
        if (done) return;
        done = true;
        editor.update(() => $insertText(text));
      }, options.timeout ?? 5000);

      options.request(text, (payload) => {
        if (done) return;
        done = true;
        window.clearTimeout(fallback);
        const nodes = (payload as { nodes?: unknown } | null)?.nodes;
        editor.update(() => {
          if (Array.isArray(nodes)) $insertNodes(editor, nodes as BaseSerializedNode[]);
          else $insertText(text);
        });
      });
      return true;
    },
    // Before the rich text paste of Lexical.
    COMMAND_PRIORITY_LOW,
  );
}

function $selection() {
  const selection = $getSelection();
  if (selection !== null) return selection;
  return $getRoot().selectEnd();
}

function $insertNodes(editor: LexicalEditor, serialized: BaseSerializedNode[]): void {
  $insertGeneratedNodes(editor, $generateNodesFromSerializedNodes(serialized), $selection());
}

function $insertText(text: string): void {
  const selection = $selection();
  if ($isRangeSelection(selection)) selection.insertRawText(text);
}
