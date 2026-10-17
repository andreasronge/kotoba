// The Lexical editor: its nodes, its theme, its Markdown shortcuts and the
// plugins that its features share (see features.ts).

import { restoreHostPrism } from "./prism";

import { CodeHighlightNode, CodeNode } from "@lexical/code-core";
import { PrismTokenizer, registerCodeHighlighting } from "@lexical/code-prism";
// The grammars that @lexical/code-prism does not load (see code_languages.ts).
// markup-templating comes before php, which needs it.
import "prismjs/components/prism-bash";
import "prismjs/components/prism-docker";
import "prismjs/components/prism-elixir";
import "prismjs/components/prism-erlang";
import "prismjs/components/prism-graphql";
import "prismjs/components/prism-json";
import "prismjs/components/prism-kotlin";
import "prismjs/components/prism-markup-templating";
import "prismjs/components/prism-php";
import "prismjs/components/prism-ruby";
import "prismjs/components/prism-toml";
import "prismjs/components/prism-yaml";
import { $createHorizontalRuleNode, $isHorizontalRuleNode, HorizontalRuleNode, signal } from "@lexical/extension";
import { AutoLinkNode, LinkNode } from "@lexical/link";
import { ListItemNode, ListNode } from "@lexical/list";
import {
  CHECK_LIST,
  CODE,
  HEADING,
  QUOTE,
  ORDERED_LIST,
  UNORDERED_LIST,
  TEXT_FORMAT_TRANSFORMERS,
  TEXT_MATCH_TRANSFORMERS,
  type ElementTransformer,
  type Transformer,
} from "@lexical/markdown";
import { HeadingNode, QuoteNode } from "@lexical/rich-text";
import {
  TableCellNode,
  TableNode,
  TableRowNode,
  registerTableCellUnmergeTransform,
  registerTablePlugin,
  registerTableSelectionObserver,
  setScrollableTablesActive,
} from "@lexical/table";
import { $getNearestNodeOfType } from "@lexical/utils";
import {
  $getSelection,
  $isRangeSelection,
  COMMAND_PRIORITY_EDITOR,
  INDENT_CONTENT_COMMAND,
  KEY_TAB_COMMAND,
  OUTDENT_CONTENT_COMMAND,
  createEditor,
  mergeRegister,
  type EditorThemeClasses,
  type Klass,
  type LexicalEditor,
  type LexicalNode,
} from "lexical";

import { findCodeLanguage, registerCodeLanguageAliases } from "./code_languages";
import { AttachmentNode } from "./nodes/attachment";
import { GalleryNode } from "./nodes/gallery";
import { UnknownNode, UploadMarkerNode } from "./nodes/internal";
import { FootnoteDefinitionNode, FootnoteReferenceNode } from "./nodes/footnote";
import { ImageNode } from "./nodes/image";
import { MentionNode } from "./nodes/mention";
import { UNKNOWN_TYPE, UPLOAD_MARKER_TYPE } from "./protocol";

// Every import above has run, so the editor's Prism and its grammars are
// loaded: the aliases join them, and the host page gets its own `Prism` back.
const readerPrism = (globalThis as unknown as {
  Prism: { languages: Record<string, unknown>; highlight: (text: string, grammar: unknown, language: string) => string };
}).Prism;
registerCodeLanguageAliases(readerPrism);
restoreHostPrism();

/** Color a server-rendered Kotoba document using the editor's Prism grammars. */
export function highlightRenderedContent(root: ParentNode = document): void {
  for (const code of root.querySelectorAll<HTMLElement>(".kotoba-content pre code")) {
    const languageClass = [...code.classList].find((name) => name.startsWith("language-"));
    if (!languageClass) continue;
    const language = findCodeLanguage(languageClass.slice("language-".length));
    if (!language || language.id === "plain") continue;
    const grammar = readerPrism.languages[language.id];
    if (!grammar) continue;
    code.innerHTML = readerPrism.highlight(code.textContent ?? "", grammar, language.id);
  }
}

/**
 * Prism's tokenizer, with no default language: a code block with no
 * language is plain text (Lexical would highlight it as JavaScript), as the
 * server renders it.
 */
const TOKENIZER = { ...PrismTokenizer, defaultLanguage: null };

/**
 * Highlights the code blocks. Only this module loads @lexical/code-prism:
 * it must load after ./prism, which the first import of this module is.
 */
export function registerCodeBlocks(editor: LexicalEditor): () => void {
  return registerCodeHighlighting(editor, TOKENIZER);
}

/** The node classes that every Kotoba editor has. */
export const BUILT_IN_NODES: readonly Klass<LexicalNode>[] = [
  HeadingNode,
  QuoteNode,
  ListNode,
  ListItemNode,
  LinkNode,
  AutoLinkNode,
  CodeNode,
  CodeHighlightNode,
  HorizontalRuleNode,
  TableNode,
  TableRowNode,
  TableCellNode,
  AttachmentNode,
  GalleryNode,
  MentionNode,
  ImageNode,
  FootnoteReferenceNode,
  FootnoteDefinitionNode,
  UploadMarkerNode,
  UnknownNode,
];

/** The node types that Lexical registers on every editor. */
export const CORE_TYPES = ["root", "paragraph", "text", "linebreak", "tab"];

export const THEME: EditorThemeClasses = {
  paragraph: "kotoba-paragraph",
  quote: "kotoba-quote",
  heading: {
    h1: "kotoba-h1",
    h2: "kotoba-h2",
    h3: "kotoba-h3",
    h4: "kotoba-h4",
    h5: "kotoba-h5",
    h6: "kotoba-h6",
  },
  list: {
    ul: "kotoba-ul",
    ol: "kotoba-ol",
    checklist: "kotoba-check",
    listitem: "kotoba-li",
    listitemChecked: "kotoba-li-checked",
    listitemUnchecked: "kotoba-li-unchecked",
    nested: { listitem: "kotoba-li-nested" },
  },
  link: "kotoba-link",
  table: "kotoba-table",
  tableRow: "kotoba-table-row",
  tableCell: "kotoba-table-cell",
  tableCellHeader: "kotoba-table-header",
  tableCellSelected: "kotoba-table-cell-selected",
  tableSelection: "kotoba-table-selection",
  tableScrollableWrapper: "kotoba-table-scroll",
  hr: "kotoba-hr",
  hrSelected: "kotoba-selected",
  code: "kotoba-code",
  codeHighlight: {
    atrule: "kotoba-token-keyword",
    attr: "kotoba-token-attr",
    "attr-name": "kotoba-token-attr",
    "attr-value": "kotoba-token-string",
    boolean: "kotoba-token-constant",
    builtin: "kotoba-token-function",
    cdata: "kotoba-token-comment",
    char: "kotoba-token-string",
    class: "kotoba-token-function",
    "class-name": "kotoba-token-function",
    comment: "kotoba-token-comment",
    constant: "kotoba-token-constant",
    deleted: "kotoba-token-deleted",
    doctype: "kotoba-token-comment",
    entity: "kotoba-token-operator",
    function: "kotoba-token-function",
    important: "kotoba-token-keyword",
    inserted: "kotoba-token-inserted",
    keyword: "kotoba-token-keyword",
    module: "kotoba-token-function",
    namespace: "kotoba-token-variable",
    number: "kotoba-token-constant",
    operator: "kotoba-token-operator",
    prolog: "kotoba-token-comment",
    property: "kotoba-token-attr",
    punctuation: "kotoba-token-punctuation",
    regex: "kotoba-token-string",
    selector: "kotoba-token-attr",
    string: "kotoba-token-string",
    symbol: "kotoba-token-constant",
    tag: "kotoba-token-keyword",
    url: "kotoba-token-string",
    variable: "kotoba-token-variable",
  },
  text: {
    bold: "kotoba-bold",
    italic: "kotoba-italic",
    strikethrough: "kotoba-strike",
    underline: "kotoba-underline",
    underlineStrikethrough: "kotoba-underline kotoba-strike",
    code: "kotoba-inline-code",
    highlight: "kotoba-highlight",
    subscript: "kotoba-sub",
    superscript: "kotoba-sup",
    lowercase: "kotoba-lowercase",
    uppercase: "kotoba-uppercase",
    capitalize: "kotoba-capitalize",
  },
};

// Headings h1–h4 only, as the toolbar offers (`#####` stays text).
const HEADING_1_TO_4: ElementTransformer = { ...HEADING, regExp: /^(#{1,4})\s/ };

const HORIZONTAL_RULE: ElementTransformer = {
  dependencies: [HorizontalRuleNode],
  export: (node) => ($isHorizontalRuleNode(node) ? "---" : null),
  regExp: /^(---|\*\*\*|___)\s?$/,
  replace: (parentNode, _children, _match, isImport) => {
    const rule = $createHorizontalRuleNode();
    if (isImport || parentNode.getNextSibling() !== null) {
      parentNode.replace(rule);
    } else {
      parentNode.insertBefore(rule);
    }
    rule.selectNext();
  },
  type: "element",
};

/** The markdown shortcuts: Lexical's built-in transformers, plus check lists and rules. */
export const MARKDOWN_TRANSFORMERS: Transformer[] = [
  HEADING_1_TO_4,
  QUOTE,
  CHECK_LIST,
  UNORDERED_LIST,
  ORDERED_LIST,
  HORIZONTAL_RULE,
  CODE,
  ...TEXT_FORMAT_TRANSFORMERS,
  ...TEXT_MATCH_TRANSFORMERS,
];

export interface EditorOptions {
  namespace: string;
  /** The app's node classes (node modules and extensions). */
  nodes: readonly Klass<LexicalNode>[];
  /** The built-in node classes of the editor's features. The default is every one. */
  builtInNodes?: readonly Klass<LexicalNode>[];
  editable: boolean;
}

/**
 * Creates an editor with the built-in nodes of its features and the app's
 * nodes. An app node cannot have the type of a built-in node, even of a
 * feature that the editor does not have (the server reserves them all).
 */
export function createKotobaEditor(options: EditorOptions): LexicalEditor {
  const builtInTypes = new Set(BUILT_IN_NODES.map((klass) => klass.getType()));
  const appNodes = options.nodes.filter((klass) => {
    let type: string;
    try {
      type = klass.getType();
    } catch (error) {
      console.error("Kotoba: an app node class has a getType() that fails; it is not registered", error);
      return false;
    }
    if (typeof type !== "string" || type === "") {
      console.error("Kotoba: an app node class has no type; it is not registered");
      return false;
    }
    if (builtInTypes.has(type) || CORE_TYPES.includes(type)) {
      console.error(`Kotoba: the node type "${type}" is built in; the app node is not registered`);
      return false;
    }
    return true;
  });

  const editor = createEditor({
    namespace: options.namespace,
    nodes: [...(options.builtInNodes ?? BUILT_IN_NODES), ...appNodes],
    theme: THEME,
    editable: options.editable,
    onError: (error) => console.error("Kotoba:", error),
  });
  // A wide table scrolls in its own box, so the page does not.
  setScrollableTablesActive(editor, true);
  return editor;
}

/**
 * The node types that a document can have. The internal node types (upload
 * markers, unknown nodes) are left out: a document or an `insert_node` that
 * has one is treated as an unknown node.
 */
export function registeredTypes(editor: LexicalEditor): Set<string> {
  const types = new Set(editor._nodes.keys());
  types.delete(UPLOAD_MARKER_TYPE);
  types.delete(UNKNOWN_TYPE);
  return types;
}

/** The deepest list nesting that Tab makes. */
export const MAX_LIST_INDENT = 6;

/**
 * Tab indents a list item and Shift+Tab outdents it, wherever the caret is
 * in the item. Everywhere else Tab is left to the browser, so it moves the
 * focus out of the editor, and so does Shift+Tab in a list item that is not
 * indented. Code blocks handle Tab themselves (it inserts a tab), at a
 * higher priority.
 */
export function registerListTab(editor: LexicalEditor): () => void {
  return editor.registerCommand(
    KEY_TAB_COMMAND,
    (event: KeyboardEvent) => {
      const selection = $getSelection();
      if (!$isRangeSelection(selection)) return false;

      // Every selected block must be in a list item: a selection from a list
      // into a paragraph is left to the browser.
      const items = new Set<ListItemNode>();
      for (const node of [selection.anchor.getNode(), ...selection.getNodes()]) {
        const item = $getNearestNodeOfType(node, ListItemNode);
        if (item === null) return false;
        items.add(item);
      }
      const indents = [...items].map((item) => item.getIndent());

      if (event.shiftKey && Math.min(...indents) === 0) return false;

      event.preventDefault();
      if (event.shiftKey) return editor.dispatchCommand(OUTDENT_CONTENT_COMMAND, undefined);
      if (Math.max(...indents) >= MAX_LIST_INDENT) return true;
      return editor.dispatchCommand(INDENT_CONTENT_COMMAND, undefined);
    },
    COMMAND_PRIORITY_EDITOR,
  );
}

/**
 * Tables as the server keeps them (see `Kotoba.Nodes.Table`): no table in a
 * table, no merged cells (a pasted table with merged cells is split into
 * plain cells) and no cell colours. In a cell, Tab and Shift+Tab move to
 * the next and the previous cell, and from the last cell Tab moves after
 * the table; Escape then Tab leaves the editor, as in a list.
 */
export function registerTables(editor: LexicalEditor): () => void {
  return mergeRegister(
    registerTablePlugin(editor, { hasNestedTables: signal(false) }),
    registerTableSelectionObserver(editor, true),
    registerTableCellUnmergeTransform(editor),
    editor.registerNodeTransform(TableCellNode, (cell) => {
      if (cell.getBackgroundColor() !== null) cell.setBackgroundColor(null);
    }),
  );
}
