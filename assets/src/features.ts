// The built-in features of the editor. Each one is an extension (see
// extensions.ts): `data-features` chooses the ones of an editor, and a
// feature that is off has no node, no toolbar button, no Markdown shortcut
// and no keyboard shortcut. Pasted content of a feature that is off comes in
// as plain paragraphs and text, and a stored node of such a feature loads as
// an unknown node (kept, and saved with no change).
//
// `Kotoba.Features` has the same list on the server (a test compares them).

import { $isCodeNode, CodeHighlightNode, CodeNode } from "@lexical/code-core";
import {
  $createHorizontalRuleNode,
  HorizontalRuleNode,
  INSERT_HORIZONTAL_RULE_COMMAND,
  namedSignals,
} from "@lexical/extension";
import { createEmptyHistoryState, registerHistory } from "@lexical/history";
import {
  AutoLinkNode,
  LinkNode,
  autoLinkEmailMatcher,
  autoLinkUrlMatcher,
  registerAutoLink,
  registerLink,
} from "@lexical/link";
import { ListItemNode, ListNode, registerCheckList, registerList } from "@lexical/list";
import { CHECK_LIST, type Transformer } from "@lexical/markdown";
import { HeadingNode, QuoteNode, registerRichText } from "@lexical/rich-text";
import { TableCellNode, TableNode, TableRowNode } from "@lexical/table";
import { $insertNodeToNearestRoot, $unwrapNode } from "@lexical/utils";
import {
  $createTextNode,
  $getSelection,
  $isRangeSelection,
  COMMAND_PRIORITY_CRITICAL,
  COMMAND_PRIORITY_EDITOR,
  COMMAND_PRIORITY_LOW,
  CONTROL_OR_META,
  FORMAT_TEXT_COMMAND,
  KEY_DOWN_COMMAND,
  TextNode,
  isExactShortcutMatch,
  mergeRegister,
  type Klass,
  type LexicalEditor,
  type LexicalNode,
  type TextFormatType,
} from "lexical";

import { MARKDOWN_TRANSFORMERS, registerCodeBlocks, registerListTab, registerTables } from "./editor";
import { $normalizeColors } from "./colors";
import type { KotobaExtension } from "./extensions";
import { isAbsoluteLinkUrl, isAllowedLinkUrl } from "./links";
import { registerGallery } from "./gallery";
import { AttachmentNode } from "./nodes/attachment";
import { GalleryNode } from "./nodes/gallery";
import { registerDecorators } from "./nodes/decorator";
import { UnknownNode, UploadMarkerNode } from "./nodes/internal";
import { FootnoteDefinitionNode, FootnoteReferenceNode } from "./nodes/footnote";
import { $isImageNode, ImageNode } from "./nodes/image";
import { MentionNode } from "./nodes/mention";

/** The built-in features, in the order of `Kotoba.Features`. */
export const FEATURES = [
  "bold",
  "italic",
  "underline",
  "strikethrough",
  "highlight",
  "subscript",
  "superscript",
  "inline_code",
  "links",
  "headings",
  "quotes",
  "lists",
  "check_lists",
  "code_blocks",
  "horizontal_rules",
  "tables",
  "attachments",
  "mentions",
  "images",
  "footnotes",
] as const;

export type Feature = (typeof FEATURES)[number];

/** A feature that needs another one. */
const REQUIRES: Partial<Record<Feature, Feature>> = { check_lists: "lists" };

/** The text format of each format feature. */
export const FEATURE_FORMATS: Partial<Record<Feature, TextFormatType>> = {
  bold: "bold",
  italic: "italic",
  underline: "underline",
  strikethrough: "strikethrough",
  highlight: "highlight",
  subscript: "subscript",
  superscript: "superscript",
  inline_code: "code",
};

/** The node classes of each feature. */
export const FEATURE_NODES: Partial<Record<Feature, readonly Klass<LexicalNode>[]>> = {
  links: [LinkNode, AutoLinkNode],
  headings: [HeadingNode],
  quotes: [QuoteNode],
  lists: [ListNode, ListItemNode],
  code_blocks: [CodeNode, CodeHighlightNode],
  horizontal_rules: [HorizontalRuleNode],
  tables: [TableNode, TableRowNode, TableCellNode],
  attachments: [AttachmentNode, GalleryNode, UploadMarkerNode],
  mentions: [MentionNode],
  images: [ImageNode],
  footnotes: [FootnoteReferenceNode, FootnoteDefinitionNode],
};

function isFeature(value: string): value is Feature {
  return (FEATURES as readonly string[]).includes(value);
}

/**
 * Reads `data-features`: comma-separated feature names. No attribute gives
 * every feature. An unknown name, or a feature without the one it needs,
 * is left out with a log.
 */
export function parseFeatures(value: string | undefined): Set<Feature> {
  if (value === undefined) return new Set(FEATURES);

  const named = new Set<Feature>();
  for (const name of value.split(",").map((part) => part.trim()).filter((part) => part !== "")) {
    if (isFeature(name)) named.add(name);
    else console.error(`Kotoba: "${name}" is not a feature of the editor`);
  }
  for (const feature of [...named]) {
    const required = REQUIRES[feature];
    if (required !== undefined && !named.has(required)) {
      console.error(`Kotoba: the feature "${feature}" needs "${required}"; it is left out`);
      named.delete(feature);
    }
  }
  return named;
}

/** Keeps a Markdown shortcut when its node types and its text formats are on. */
function keepsTransformer(transformer: Transformer, features: ReadonlySet<Feature>): boolean {
  const nodes = new Set(FEATURES.filter((feature) => features.has(feature)).flatMap((feature) => FEATURE_NODES[feature] ?? []));
  const dependencies = "dependencies" in transformer ? transformer.dependencies : [];
  if (!dependencies.every((klass) => nodes.has(klass))) return false;

  if (transformer.type === "text-format") {
    return transformer.format.every((format) => {
      const feature = (Object.keys(FEATURE_FORMATS) as Feature[]).find((key) => FEATURE_FORMATS[key] === format);
      return feature === undefined || features.has(feature);
    });
  }
  // The check list shortcut needs the list nodes, as the bullet one does,
  // and it is a feature of its own.
  if (transformer === CHECK_LIST) return features.has("check_lists");
  return true;
}

/**
 * A keyboard shortcut that toggles a text format: Cmd (Ctrl elsewhere) and
 * the key, with Shift when `shift`. Lexical has the ones of bold, italic
 * and underline.
 */
function registerFormatShortcut(
  editor: LexicalEditor,
  format: TextFormatType,
  key: string,
  shift = false,
): () => void {
  return editor.registerCommand(
    KEY_DOWN_COMMAND,
    (event: KeyboardEvent) => {
      if (!isExactShortcutMatch(event, key, { ...CONTROL_OR_META, shiftKey: shift })) return false;
      event.preventDefault();
      return editor.dispatchCommand(FORMAT_TEXT_COMMAND, format);
    },
    // Above Lexical's own key handler, which takes every key.
    COMMAND_PRIORITY_LOW,
  );
}

export interface FeatureOptions {
  /** The allowed link schemes, as `Kotoba.Sanitizer` has them. */
  linkSchemes: readonly string[];
  history?: boolean;
}

/**
 * The extensions of the built-in features that are on, after the core: rich
 * text, history, decorators, the Markdown shortcuts of the features that
 * are on, and a guard that keeps the text formats that are off out (from a
 * keyboard shortcut or a paste).
 */
export function builtInExtensions(features: ReadonlySet<Feature>, options: FeatureOptions): KotobaExtension[] {
  const offFormats = (Object.keys(FEATURE_FORMATS) as Feature[])
    .filter((feature) => !features.has(feature))
    .map((feature) => FEATURE_FORMATS[feature] as TextFormatType);

  const core: KotobaExtension = {
    name: "core",
    nodes: [UnknownNode],
    markdown: MARKDOWN_TRANSFORMERS.filter((transformer) => keepsTransformer(transformer, features)),
    register: (editor) =>
      mergeRegister(
        registerRichText(editor),
        options.history === false ? () => {} : registerHistory(editor, createEmptyHistoryState(), 300),
        registerDecorators(editor),
        editor.registerCommand(
          FORMAT_TEXT_COMMAND,
          (format) => offFormats.includes(format),
          COMMAND_PRIORITY_CRITICAL,
        ),
        editor.registerNodeTransform(TextNode, (node) => {
          for (const format of offFormats) if (node.hasFormat(format)) node.toggleFormat(format);
          $normalizeColors(node, features.has("highlight"));
        }),
      ),
  };

  const extensions: Record<Feature, KotobaExtension> = {
    bold: { name: "bold" },
    italic: { name: "italic" },
    underline: { name: "underline" },
    strikethrough: { name: "strikethrough" },
    highlight: { name: "highlight", register: (editor) => registerFormatShortcut(editor, "highlight", "h", true) },
    subscript: { name: "subscript", register: (editor) => registerFormatShortcut(editor, "subscript", ",") },
    superscript: { name: "superscript", register: (editor) => registerFormatShortcut(editor, "superscript", ".") },
    inline_code: { name: "inline_code" },
    links: {
      name: "links",
      nodes: FEATURE_NODES.links,
      register: (editor) => {
        const { linkSchemes } = options;
        // A link from a markdown shortcut, pasted HTML or the server that
        // the server would not keep becomes its text.
        const $unwrapUnsafeLink = (node: LinkNode): void => {
          if (!isAllowedLinkUrl(node.getURL(), linkSchemes)) $unwrapNode(node);
        };
        return mergeRegister(
          registerLink(
            editor,
            namedSignals({ validateUrl: (url: string) => isAbsoluteLinkUrl(url, linkSchemes), attributes: undefined }),
          ),
          registerAutoLink(editor, {
            changeHandlers: [],
            excludeParents: [(parent) => $isCodeNode(parent)],
            matchers: [autoLinkUrlMatcher, autoLinkEmailMatcher],
          }),
          editor.registerNodeTransform(LinkNode, $unwrapUnsafeLink),
          editor.registerNodeTransform(AutoLinkNode, $unwrapUnsafeLink),
        );
      },
    },
    headings: { name: "headings", nodes: FEATURE_NODES.headings },
    quotes: { name: "quotes", nodes: FEATURE_NODES.quotes },
    lists: {
      name: "lists",
      nodes: FEATURE_NODES.lists,
      register: (editor) => mergeRegister(registerList(editor), registerListTab(editor)),
    },
    check_lists: { name: "check_lists", register: (editor) => registerCheckList(editor) },
    code_blocks: {
      name: "code_blocks",
      nodes: FEATURE_NODES.code_blocks,
      register: (editor) => registerCodeBlocks(editor),
    },
    horizontal_rules: {
      name: "horizontal_rules",
      nodes: FEATURE_NODES.horizontal_rules,
      register: (editor) =>
        editor.registerCommand(
          INSERT_HORIZONTAL_RULE_COMMAND,
          () => {
            if (!$isRangeSelection($getSelection())) return false;
            $insertNodeToNearestRoot($createHorizontalRuleNode());
            return true;
          },
          COMMAND_PRIORITY_EDITOR,
        ),
    },
    tables: { name: "tables", nodes: FEATURE_NODES.tables, register: (editor) => registerTables(editor) },
    attachments: {
      name: "attachments",
      nodes: FEATURE_NODES.attachments,
      register: (editor, context) => registerGallery(editor, { announce: (message) => context.announce(message) }),
    },
    mentions: { name: "mentions", nodes: FEATURE_NODES.mentions },
    images: {
      name: "images",
      nodes: FEATURE_NODES.images,
      // An image from pasted content or the server whose URL the server
      // would not keep becomes its alternative text.
      register: (editor) =>
        editor.registerNodeTransform(ImageNode, (node) => {
          if ($isImageNode(node) && !isAllowedLinkUrl(node.getImage().url, options.linkSchemes)) {
            node.replace($createTextNode(node.getImage().alt));
          }
        }),
    },
    footnotes: { name: "footnotes", nodes: FEATURE_NODES.footnotes },
  };

  return [core, ...FEATURES.filter((feature) => features.has(feature)).map((feature) => extensions[feature])];
}
