/*! Kotoba — icons from Lucide (https://lucide.dev), ISC licence. See NOTICE. */

// The Kotoba editor bundle: the LiveView hook and the built-in node classes.

export { Kotoba } from "./hook";
export { highlightRenderedContent } from "./editor";
export { registerCollaboration } from "./collaboration";
export type { Collaboration, CollabCredentials } from "./collaboration";
export { AttachmentNode } from "./nodes/attachment";
export { GalleryNode } from "./nodes/gallery";
export { MentionNode } from "./nodes/mention";
export { ImageNode } from "./nodes/image";
export { FootnoteDefinitionNode, FootnoteReferenceNode } from "./nodes/footnote";
// The types of an extension module (see the Extensions guide).
export type { ExtensionAPI, ExtensionContext, KotobaExtension, ToolbarControl } from "./extensions";
