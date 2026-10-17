// The `image` node: an image from a URL, in the text, as Markdown has it
// (`![alt](url "title")`). The JSON keys mirror `Kotoba.Nodes.Image`:
// `url`, `alt` and `title`. An image that a person uploads is an
// `attachment`; this one is a URL that the document links to.

import {
  $applyNodeReplacement,
  type LexicalNode,
  type NodeKey,
  type SerializedLexicalNode,
  type SerializedPartial,
  type Spread,
} from "lexical";

import { KotobaDecoratorNode } from "./decorator";

export interface ImagePayload {
  url: string;
  alt: string;
  title?: string;
}

export type SerializedImageNode = Spread<ImagePayload, SerializedLexicalNode>;

export class ImageNode extends KotobaDecoratorNode {
  __image: ImagePayload;

  static getType(): string {
    return "image";
  }

  static clone(node: ImageNode): ImageNode {
    return new ImageNode(node.__image, node.__key);
  }

  static importJSON(json: SerializedPartial<SerializedImageNode>): ImageNode {
    const title = typeof json.title === "string" && json.title !== "" ? json.title : undefined;
    return $createImageNode({ url: String(json.url ?? ""), alt: String(json.alt ?? ""), title });
  }

  constructor(image: ImagePayload, key?: NodeKey) {
    super(key);
    this.__image = { ...image };
  }

  exportJSON(): SerializedImageNode {
    const { url, alt, title } = this.getLatest().__image;
    return { type: "image", version: 1, url, alt, ...(title === undefined ? {} : { title }) };
  }

  getImage(): ImagePayload {
    return { ...this.getLatest().__image };
  }

  getTextContent(): string {
    return this.getLatest().__image.alt;
  }

  isInline(): boolean {
    return true;
  }

  className(): string {
    return "kotoba-image";
  }

  render(): HTMLElement {
    const { url, alt, title } = this.__image;
    const image = document.createElement("img");
    image.src = url;
    image.alt = alt;
    if (title !== undefined) image.title = title;
    image.loading = "lazy";
    image.draggable = false;
    return image;
  }
}

export function $createImageNode(image: ImagePayload): ImageNode {
  return $applyNodeReplacement(new ImageNode(image));
}

export function $isImageNode(node: LexicalNode | null | undefined): node is ImageNode {
  return node instanceof ImageNode;
}
