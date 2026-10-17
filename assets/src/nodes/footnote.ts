// The footnote nodes, as Markdown has them: a reference in the text
// (`[^label]`, type `footnotereference`) and the text of the footnote
// (`[^label]: ...`, type `footnotedefinition`). The JSON keys mirror
// `Kotoba.Nodes.FootnoteReference` and `Kotoba.Nodes.FootnoteDefinition`.
//
// A footnote holds blocks, as a table cell does: it is a shadow root, so
// Enter makes a paragraph in it. It is valid only under the root.

import {
  $applyNodeReplacement,
  $createParagraphNode,
  ElementNode,
  type EditorConfig,
  type LexicalNode,
  type NodeKey,
  type RangeSelection,
  type SerializedElementNode,
  type SerializedLexicalNode,
  type SerializedPartial,
  type Spread,
} from "lexical";

import { KotobaDecoratorNode, element } from "./decorator";

export type SerializedFootnoteReferenceNode = Spread<{ label: string }, SerializedLexicalNode>;

export class FootnoteReferenceNode extends KotobaDecoratorNode {
  __label: string;

  static getType(): string {
    return "footnotereference";
  }

  static clone(node: FootnoteReferenceNode): FootnoteReferenceNode {
    return new FootnoteReferenceNode(node.__label, node.__key);
  }

  static importJSON(json: SerializedPartial<SerializedFootnoteReferenceNode>): FootnoteReferenceNode {
    return $createFootnoteReferenceNode(String(json.label ?? ""));
  }

  constructor(label: string, key?: NodeKey) {
    super(key);
    this.__label = label;
  }

  exportJSON(): SerializedFootnoteReferenceNode {
    return { type: "footnotereference", version: 1, label: this.getLatest().__label };
  }

  getLabel(): string {
    return this.getLatest().__label;
  }

  getTextContent(): string {
    return `[^${this.getLatest().__label}]`;
  }

  isInline(): boolean {
    return true;
  }

  className(): string {
    return "kotoba-footnote-ref";
  }

  render(): HTMLElement {
    return element("sup", "kotoba-footnote-label", this.__label);
  }
}

export type SerializedFootnoteDefinitionNode = Spread<{ label: string }, SerializedElementNode>;

export class FootnoteDefinitionNode extends ElementNode {
  __label: string;

  static getType(): string {
    return "footnotedefinition";
  }

  static clone(node: FootnoteDefinitionNode): FootnoteDefinitionNode {
    return new FootnoteDefinitionNode(node.__label, node.__key);
  }

  static importJSON(json: SerializedPartial<SerializedFootnoteDefinitionNode>): FootnoteDefinitionNode {
    return $createFootnoteDefinitionNode(String(json.label ?? "")).updateFromJSON(json);
  }

  constructor(label: string, key?: NodeKey) {
    super(key);
    this.__label = label;
  }

  exportJSON(): SerializedFootnoteDefinitionNode {
    return { ...super.exportJSON(), type: "footnotedefinition", version: 1, label: this.getLatest().__label };
  }

  getLabel(): string {
    return this.getLatest().__label;
  }

  createDOM(_config: EditorConfig): HTMLElement {
    const dom = document.createElement("div");
    dom.className = "kotoba-footnote";
    dom.dataset.label = this.__label;
    return dom;
  }

  updateDOM(prev: FootnoteDefinitionNode, dom: HTMLElement): boolean {
    if (prev.__label !== this.__label) dom.dataset.label = this.__label;
    return false;
  }

  isShadowRoot(): boolean {
    return true;
  }

  canBeEmpty(): boolean {
    return false;
  }

  insertNewAfter(_selection: RangeSelection, restoreSelection = true): LexicalNode {
    const paragraph = $createParagraphNode();
    this.insertAfter(paragraph, restoreSelection);
    return paragraph;
  }
}

export function $createFootnoteReferenceNode(label: string): FootnoteReferenceNode {
  return $applyNodeReplacement(new FootnoteReferenceNode(label));
}

export function $isFootnoteReferenceNode(node: LexicalNode | null | undefined): node is FootnoteReferenceNode {
  return node instanceof FootnoteReferenceNode;
}

export function $createFootnoteDefinitionNode(label: string): FootnoteDefinitionNode {
  return $applyNodeReplacement(new FootnoteDefinitionNode(label));
}

export function $isFootnoteDefinitionNode(node: LexicalNode | null | undefined): node is FootnoteDefinitionNode {
  return node instanceof FootnoteDefinitionNode;
}
