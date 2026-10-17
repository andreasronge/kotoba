// The `Kotoba` LiveView hook.
//
// Register it with the LiveSocket:
//
//     import { Kotoba } from "kotoba"
//     const liveSocket = new LiveSocket("/live", Socket, { hooks: { Kotoba } })
//
// The hook element (with `phx-hook="Kotoba"`, an `id` and
// `phx-update="ignore"`) has these data attributes:
//
//   * `data-input` - the id of the hidden input that holds the document.
//   * `data-readonly` - present (and not "false") for a read-only editor.
//   * `data-placeholder` - the text to show when the editor is empty.
//   * `data-nodes` - comma-separated URLs of app node modules.
//   * `data-features` - comma-separated built-in features of the editor
//     (see features.ts); every feature when there is none.
//   * `data-extensions` - comma-separated URLs of app extension modules
//     (see extensions.ts).
//   * `data-prompts` - JSON: trigger character → prompt name.
//   * `data-prompt-labels` - JSON: prompt name → the accessible name of its
//     menu, for the prompts that have a label.
//   * `data-prompt-config` - JSON: prompt name → its options (spaces,
//     minLength, maxLength, insert, nodeType, items), see prompts.ts.
//   * `data-code-languages` - comma-separated ids of the languages of the
//     code language picker (every language when there is none).
//   * `data-upload` - the id of the LiveView file input.
//   * `data-change` - "true" to push `kotoba:change`; any other value (or
//     none) pushes nothing. A LiveView patch can change it.
//   * `data-debounce` - milliseconds between `kotoba:change` pushes (300).
//   * `data-link-schemes` - comma-separated allowed link schemes
//     ("http,https,mailto"); the same list as the server's sanitizer.
//   * `data-selection-menu` - "true" for the selection menu with its default
//     commands, or comma-separated commands (see selection_menu.ts). An
//     `[data-kotoba-selection-menu]` element in the hook element is the
//     app's own menu, and needs no attribute.
//   * `data-assist` - JSON: the actions of the Assist menu (`[{id, label}]`,
//     `[]` for none). With it, the editor pushes `kotoba:assist` and
//     `kotoba:suggestion` (see suggestions.ts).
//
// The hook pushes (every message has `v: 1` and the hook element's `id`):
//
//   * `kotoba:change` `{v, id, doc}` - the document envelope, debounced,
//     only when `data-change` is "true".
//   * `kotoba:prompt` `{v, id, prompt, query}` - a prompt query.
//   * `kotoba:assist` `{v, id, ref, action, text}` - a request for a
//     suggestion, only with `data-assist`.
//   * `kotoba:suggestion` `{v, id, ref, action}` - the person accepted,
//     rejected or stopped a suggestion (`action` is "accept", "reject" or
//     "stop"), only with `data-assist`.
//
// It handles these server events (a payload with an `id` other than the
// hook element's id is for another editor, and is ignored):
//
//   * `set_content` `{doc}` - replaces the document.
//   * `insert_node` `{node, ref?}` - inserts a node in place of the upload
//     marker of the LiveView upload entry `ref` (with no `ref`, of the oldest
//     upload marker), else at the selection.
//   * `remove_marker` `{ref}` - removes the upload marker of the LiveView
//     upload entry `ref` (an upload that failed).
//   * `set_readonly` `{readonly}`
//   * `focus` `{}`
//   * `kotoba:prompt_results` `{prompt, query?, items: [{id, label, hint?, text?, attrs?}], error?}`
//   * `kotoba:stream` `{ref, op, ...}` - a suggestion: `op` is "start"
//     (with `at`, `format` and `label`), "chunk" (with `text`), "end" or
//     "cancel".
//
// A change of `data-readonly` in a LiveView patch also sets the read-only
// state, and a change of `data-change` turns the pushes on or off.
//
// The hidden input holds the current document: the hook writes it on every
// change and again after each LiveView patch, and puts it in the form data
// of phx-change and phx-submit. The value that the server renders into the
// input is read once, when the editor mounts.

import {
  $getRoot,
  $isParagraphNode,
  $parseSerializedNode,
  BLUR_COMMAND,
  CLEAR_HISTORY_COMMAND,
  COMMAND_PRIORITY_LOW,
  type EditorState,
  type LexicalEditor,
  type SerializedEditorState,
  type SerializedLexicalNode,
} from "lexical";

import { BUILT_IN_NODES, CORE_TYPES, createKotobaEditor, registeredTypes } from "./editor";
import { registerMarkdownPaste } from "./markdown_paste";
import {
  composeExtensions,
  extensionControls,
  loadExtensions,
  markdownTransformers,
  registerExtensions,
  EXTENSION_API,
  type KotobaExtension,
} from "./extensions";
import { type Feature, builtInExtensions, parseFeatures } from "./features";
import { createColorMenu, type ColorMenu } from "./colors";
import { createLinkForm, type LinkForm } from "./link";
import { parseLinkSchemes } from "./links";
import { loadNodes } from "./nodes/custom";
import { type CodeLanguage, parseCodeLanguages } from "./code_languages";
import { createPrompts, parseConfigs, parseLabels, parseTriggers, type PromptConfig, type Prompts } from "./prompts";
import {
  PROTOCOL_VERSION,
  isObject,
  prepareRoot,
  readRoot,
  toEnvelope,
  type DocumentEnvelope,
  type JSONNode,
} from "./protocol";
import { createSuggestions, type AssistAction, type Suggestions } from "./suggestions";
import { buildCommandBar, createToolbar, type Toolbar } from "./toolbar";
import { SELECTION_MENU_COMMANDS, attachLinkCard, attachSelectionMenu, type Floating } from "./selection_menu";
import { createUploads, type Uploads } from "./uploads";
import { attachCollaboration, readCollabCredentials, type Collaboration, type CollabCredentials } from "./collaboration";

/**
 * The part of a LiveView hook that Kotoba uses. LiveView calls the hook's
 * callbacks with `this` bound to an object with these members.
 */
export interface LiveViewHook {
  el: HTMLElement;
  pushEvent(event: string, payload: object, reply?: (payload: unknown) => void): unknown;
  pushEventTo(target: string | HTMLElement, event: string, payload: object, reply?: (payload: unknown) => void): unknown;
  handleEvent(event: string, callback: (payload: unknown) => void): unknown;
  removeHandleEvent(ref: unknown): void;
}

interface KotobaHook extends LiveViewHook {
  kotoba?: Instance;
}

export interface Config {
  input: HTMLInputElement | null;
  readonly: boolean;
  placeholder: string;
  nodes: string[];
  features: Set<Feature>;
  extensions: string[];
  prompts: Map<string, string>;
  promptLabels: Map<string, string>;
  promptConfigs: Map<string, PromptConfig>;
  codeLanguages: readonly CodeLanguage[];
  upload: HTMLInputElement | null;
  change: boolean;
  debounce: number;
  linkSchemes: string[];
  /** The commands of the selection menu, or `null` for an editor with no selection menu. */
  selectionMenu: string[] | null;
  /** The Assist menu's actions, or `null` for an editor with no assist. */
  assist: AssistAction[] | null;
  collab: CollabCredentials | null;
  /** The id of the element of the server's half of pasted Markdown, or `null`. */
  markdown: string | null;
  /** `"collapse"` leaves the blank lines a person typed out of the saved document. */
  blankLines: "keep" | "collapse";
}

/** Reads the hook's configuration from the data attributes of its element. */
export function readConfig(el: HTMLElement): Config {
  const data = el.dataset;
  const debounce = Number.parseInt(data.debounce ?? "", 10);

  return {
    input: inputById(data.input),
    readonly: data.readonly !== undefined && data.readonly !== "false",
    placeholder: data.placeholder ?? "",
    nodes: urls(data.nodes),
    features: parseFeatures(data.features),
    extensions: urls(data.extensions),
    prompts: parseTriggers(data.prompts),
    promptLabels: parseLabels(data.promptLabels),
    promptConfigs: parseConfigs(data.promptConfig),
    codeLanguages: parseCodeLanguages(data.codeLanguages),
    upload: inputById(data.upload),
    change: data.change === "true",
    debounce: Number.isFinite(debounce) && debounce >= 0 ? debounce : 300,
    linkSchemes: parseLinkSchemes(data.linkSchemes),
    selectionMenu: parseSelectionMenu(data.selectionMenu),
    assist: parseAssist(data.assist),
    collab: readCollabCredentials(data.collab),
    markdown: data.markdown ?? null,
    blankLines: data.blankLines === "collapse" ? "collapse" : "keep",
  };
}

/** Reads `data-selection-menu`: "true" for the default commands, or a list of commands. */
export function parseSelectionMenu(value: string | undefined): string[] | null {
  if (value === undefined || value === "false") return null;
  if (value === "" || value === "true") return [...SELECTION_MENU_COMMANDS];
  const commands = urls(value);
  return commands.length > 0 ? commands : null;
}

/** Reads `data-assist`: a JSON list of `{id, label}` actions. No attribute gives `null`. */
export function parseAssist(json: string | undefined): AssistAction[] | null {
  if (json === undefined) return null;
  let data: unknown;
  try {
    data = JSON.parse(json === "" ? "[]" : json);
  } catch {
    console.error("Kotoba: data-assist is not valid JSON");
    return null;
  }
  if (!Array.isArray(data)) return [];
  return data.flatMap((action) =>
    isObject(action) && typeof action.id === "string" && action.id !== "" && typeof action.label === "string"
      ? [{ id: action.id, label: action.label }]
      : [],
  );
}

function urls(value: string | undefined): string[] {
  return (value ?? "")
    .split(",")
    .map((url) => url.trim())
    .filter((url) => url !== "");
}

function inputById(id: string | undefined): HTMLInputElement | null {
  if (id === undefined || id === "") return null;
  const element = document.getElementById(id);
  return element instanceof HTMLInputElement ? element : null;
}

const EMPTY_ROOT: JSONNode = {
  type: "root",
  version: 1,
  direction: null,
  format: "",
  indent: 0,
  children: [
    {
      type: "paragraph",
      version: 1,
      direction: null,
      format: "",
      indent: 0,
      textFormat: 0,
      textStyle: "",
      children: [],
    },
  ],
};

// The JSON nodes are checked by Lexical when it parses them.
function asState(root: JSONNode): SerializedEditorState {
  return { root } as unknown as SerializedEditorState;
}

/** An update with this tag came from the server; it is not pushed back. */
const REMOTE_TAG = "kotoba-remote";

let instances = 0;

class Instance {
  private readonly hook: KotobaHook;
  private readonly config: Config;
  private readonly el: HTMLElement;
  private readonly id: string;
  private readonly live: HTMLElement;
  private readonly cleanups: (() => void)[] = [];
  private readonly handlers: unknown[] = [];

  private editor: LexicalEditor | null = null;
  private editable: HTMLElement | null = null;
  private placeholder: HTMLElement | null = null;
  private toolbar: Toolbar | null = null;
  private selectionToolbar: Toolbar | null = null;
  private floating: Floating[] = [];
  private link: LinkForm | null = null;
  private colors: ColorMenu | null = null;
  private prompts: Prompts | null = null;
  private uploads: Uploads | null = null;
  private suggestions: Suggestions | null = null;
  private collaboration: Collaboration | null = null;
  private appReadonly = false;

  private json = "";
  private pushed = "";
  private timer: ReturnType<typeof setTimeout> | undefined;
  private destroyed = false;
  private loaded = false;
  private readonlyAttribute: string | undefined;
  private change: boolean;
  private readonly ready: Promise<void>;

  constructor(hook: KotobaHook) {
    this.hook = hook;
    this.el = hook.el;
    this.config = readConfig(hook.el);
    this.appReadonly = this.config.readonly;
    this.readonlyAttribute = hook.el.dataset.readonly;
    this.change = this.config.change;
    instances += 1;
    this.id = hook.el.id || `kotoba-${instances}`;

    this.el.classList.add("kotoba");
    this.live = document.createElement("div");
    this.live.className = "kotoba-live";
    this.live.setAttribute("aria-live", "polite");
    this.live.setAttribute("role", "status");

    // Server events are registered at once, so that none is lost while the
    // app node modules load; each one waits for the editor.
    this.on("set_content", (payload) => this.setContent(payload.doc));
    this.on("insert_node", (payload) =>
      this.insertNode(payload.node, typeof payload.ref === "string" ? payload.ref : undefined),
    );
    this.on("remove_marker", (payload) => {
      if (typeof payload.ref === "string") this.uploads?.remove(payload.ref);
    });
    this.on("set_readonly", (payload) => this.setReadonly(payload.readonly === true));
    this.on("focus", () => this.editor?.focus());
    this.on("kotoba:stream", (payload) => this.stream(payload));
    this.on("kotoba:prompt_results", (payload) => {
      if (typeof payload.prompt === "string")
        this.prompts?.receive(payload.prompt, payload.items, payload.query, payload.error);
    });

    this.ready = this.mount().catch((error: unknown) => {
      console.error("Kotoba: the editor could not mount", error);
      if (this.config.collab) { this.applyReadonly(true); this.announce("The shared editor could not connect."); }
    });
  }

  private on(event: string, handler: (payload: Record<string, unknown>) => void): void {
    const ref = this.hook.handleEvent(event, (payload: unknown) => {
      if (!isObject(payload)) return;
      if (payload.id !== undefined && payload.id !== this.id) return;
      void this.ready.then(() => {
        if (!this.destroyed && this.editor !== null) handler(payload);
      });
    });
    this.handlers.push(ref);
  }

  private async mount(): Promise<void> {
    const [appNodes, appExtensions] = await Promise.all([
      loadNodes(this.config.nodes),
      loadExtensions(this.config.extensions),
    ]);
    if (this.destroyed) return;

    const { features } = this.config;
    // The built-in features, then the app's extensions. An extension node
    // cannot take the type of a built-in node (of any feature) or of a node
    // module's node.
    const builtIns = builtInExtensions(features, { linkSchemes: this.config.linkSchemes, history: this.config.collab === null });
    const reserved = new Set<string>([...CORE_TYPES, ...BUILT_IN_NODES.map((klass) => klass.getType())]);
    const builtIn = composeExtensions(builtIns, new Set(CORE_TYPES));
    const moduleTypes = appNodes.flatMap((klass) => {
      try {
        return [klass.getType()];
      } catch {
        return [];
      }
    });
    const app = composeExtensions(appExtensions, new Set([...reserved, ...moduleTypes]));
    let extensions: KotobaExtension[] = [...builtIn.extensions, ...app.extensions];

    const options = { namespace: this.id, editable: !this.config.readonly && this.config.collab === null, builtInNodes: builtIn.nodes };
    let editor: LexicalEditor;
    try {
      editor = createKotobaEditor({ ...options, nodes: [...appNodes, ...app.nodes] });
    } catch (error) {
      console.error("Kotoba: the app nodes could not be registered; the editor has the built-in nodes only", error);
      editor = createKotobaEditor({ ...options, nodes: [] });
      extensions = builtIn.extensions;
    }
    this.editor = editor;

    const surface = document.createElement("div");
    surface.className = "kotoba-surface";

    const editable = this.el.querySelector<HTMLElement>("[data-kotoba-editable]") ?? document.createElement("div");
    editable.classList.add("kotoba-editable");
    editable.contentEditable = String(options.editable);
    editable.setAttribute("role", "textbox");
    editable.setAttribute("aria-multiline", "true");
    editable.spellcheck = true;
    copyLabel(this.el, editable);
    syncAria(this.el, editable);
    if (!options.editable) editable.setAttribute("aria-readonly", "true");
    if (this.config.placeholder !== "") editable.setAttribute("aria-placeholder", this.config.placeholder);
    this.editable = editable;

    const placeholder = document.createElement("div");
    placeholder.className = "kotoba-placeholder";
    placeholder.setAttribute("aria-hidden", "true");
    placeholder.textContent = this.config.placeholder;
    this.placeholder = placeholder;

    surface.append(editable, placeholder);
    this.el.append(surface, this.live);

    this.cleanups.push(
      registerExtensions(editor, extensions, {
        id: this.id,
        element: this.el,
        announce: this.announce,
        push: (event, payload) => this.push(event, { ...payload, v: PROTOCOL_VERSION, id: this.id }),
        assist: (action, detail) => this.suggestions?.request(action, detail) ?? null,
      }),
    );

    const markdown = this.config.markdown;
    if (markdown !== null && !this.config.readonly) {
      this.cleanups.push(
        registerMarkdownPaste(editor, {
          request: (text, reply) =>
            this.hook.pushEventTo(`#${CSS.escape(markdown)}`, "kotoba:markdown", { v: PROTOCOL_VERSION, markdown: text }, reply),
          announce: this.announce,
        }),
      );
    }

    // Suggestions show in a panel under the editable area, rendered with the
    // editor's nodes, and read with its Markdown shortcuts.
    const assist = this.config.assist;
    this.suggestions = createSuggestions(editor, {
      host: surface,
      namespace: this.id,
      nodes: [...appNodes, ...app.nodes].filter((klass) => editor.hasNodes([klass])),
      builtInNodes: builtIn.nodes,
      transformers: markdownTransformers(editor, extensions),
      actions: assist ?? [],
      push:
        assist === null ? null : (event, payload) => this.push(event, { ...payload, v: PROTOCOL_VERSION, id: this.id }),
      announce: this.announce,
    });

    if (features.has("links")) {
      this.link = createLinkForm(editor, {
        host: surface,
        linkSchemes: this.config.linkSchemes,
        idPrefix: this.id,
        announce: this.announce,
      });
    }
    if (features.has("highlight")) this.colors = createColorMenu(editor, { host: surface, announce: this.announce });
    this.uploads = createUploads(editor, {
      host: this.el,
      target: features.has("attachments") ? this.config.upload : null,
      announce: this.announce,
    });

    const existing =
      this.el.querySelector<HTMLElement>("[data-kotoba-toolbar]") ??
      (this.el.id ? document.querySelector<HTMLElement>(`[data-kotoba-toolbar="${CSS.escape(this.el.id)}"]`) : null);

    this.toolbar = createToolbar(editor, {
      existing,
      host: this.el,
      label: "Formatting",
      uploads: this.uploads.enabled,
      onLink: () => this.link?.open(),
      onUpload: () => this.uploads?.open(),
      onColors: this.colors === null ? undefined : (button) => this.colors?.open(button),
      onAssist: assist !== null && assist.length > 0 ? (button) => this.suggestions?.openMenu(button) : undefined,
      announce: this.announce,
      codeLanguages: this.config.codeLanguages,
      features,
      controls: extensionControls(app.extensions.filter((extension) => extensions.includes(extension))),
    });
    this.toolbar.setDisabled(!options.editable);

    // The selection menu: the app's element, or the commands of
    // `data-selection-menu`. It is a second toolbar, with the same commands.
    const appMenu = this.el.querySelector<HTMLElement>("[data-kotoba-selection-menu]");
    const controls = extensionControls(app.extensions.filter((extension) => extensions.includes(extension)));
    if (appMenu !== null || this.config.selectionMenu !== null) {
      const menu =
        appMenu ??
        buildCommandBar(this.config.selectionMenu ?? [], {
          uploads: this.uploads.enabled,
          assist: assist !== null && assist.length > 0,
          features,
          controls,
        });
      this.selectionToolbar = createToolbar(editor, {
        existing: menu,
        host: surface,
        label: menu.getAttribute("aria-label") ?? "Selection formatting",
        uploads: this.uploads.enabled,
        onLink: () => this.link?.open(),
        onUpload: () => this.uploads?.open(),
        onColors: this.colors === null ? undefined : (button) => this.colors?.open(button),
        onAssist: assist !== null && assist.length > 0 ? (button) => this.suggestions?.openMenu(button) : undefined,
        announce: this.announce,
        codeLanguages: this.config.codeLanguages,
        features,
        controls,
        className: "kotoba-selection-menu",
        focusShortcut: false,
      });
      this.selectionToolbar.setDisabled(!options.editable);
      this.floating.push(attachSelectionMenu(editor, menu, this.selectionToolbar, { host: surface, root: this.el }));
    }
    if (this.link !== null) {
      this.floating.push(
        attachLinkCard(editor, {
          host: surface,
          root: this.el,
          idPrefix: this.id,
          linkSchemes: this.config.linkSchemes,
          onEdit: () => this.link?.open(),
          announce: this.announce,
        }),
      );
    }

    if (this.config.prompts.size > 0 && features.has("mentions")) {
      this.prompts = createPrompts(editor, {
        host: surface,
        editable,
        idPrefix: this.id,
        triggers: this.config.prompts,
        labels: this.config.promptLabels,
        configs: this.config.promptConfigs,
        request: (prompt, query) => this.push("kotoba:prompt", { v: PROTOCOL_VERSION, id: this.id, prompt, query }),
        announce: this.announce,
      });
    }

    this.cleanups.push(
      editor.registerUpdateListener(({ editorState, dirtyElements, dirtyLeaves, tags }) => {
        // `setRootElement` commits the empty state before the document is
        // loaded; it must not reach the hidden input or the server.
        if (!this.loaded) return;
        this.updatePlaceholder();
        const remote = tags.has(REMOTE_TAG) || tags.has("kotoba-collab");
        if (!remote && dirtyElements.size === 0 && dirtyLeaves.size === 0) return;

        this.json = JSON.stringify(toEnvelope(editorState, { collapseBlankLines: this.config.blankLines === "collapse" }));
        if (this.config.input !== null) this.config.input.value = this.json;

        if (remote) {
          this.pushed = this.json;
        } else {
          this.schedulePush();
        }
      }),
      // Vanilla Lexical does not set contenteditable itself.
      editor.registerEditableListener((isEditable) => {
        editable.contentEditable = String(isEditable);
        if (isEditable) editable.removeAttribute("aria-readonly");
        else editable.setAttribute("aria-readonly", "true");
      }),
      editor.registerCommand(
        BLUR_COMMAND,
        () => {
          this.flush();
          return false;
        },
        COMMAND_PRIORITY_LOW,
      ),
    );

    this.watchForm();
    this.watchPatches();
    const initial = this.config.input?.value ?? "";
    editor.setRootElement(editable);
    this.loaded = true;
    if (this.config.collab) {
      this.collaboration = await attachCollaboration({
        editor, api: EXTENSION_API, element: this.el, surface, editable,
        credentials: this.config.collab, initialReadonly: this.config.readonly,
        readDocument: () => toEnvelope(editor.getEditorState()),
        announce: this.announce,
        setReadonly: (value) => this.applyReadonly(value || this.appReadonly),
        refreshCredentials: () => new Promise((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error("Collaboration credentials could not be renewed")), 10_000);
          const reply = (payload: unknown): void => {
            clearTimeout(timer);
            try {
              const credentials = readCollabCredentials(JSON.stringify(payload));
              if (credentials) resolve(credentials); else reject(new Error("Access changed"));
            } catch { reject(new Error("Access changed")); }
          };
          const target = this.el.getAttribute("phx-target");
          const payload = { v: 1, id: this.id, document_id: this.config.collab!.document_id };
          if (target) this.hook.pushEventTo(target, "kotoba:collab_token", payload, reply);
          else this.hook.pushEvent("kotoba:collab_token", payload, reply);
        }),
      });
      if (this.destroyed) this.collaboration.dispose();
    } else this.load(initial);
  }

  // Reads a document into the editor (the first document, or one from
  // `set_content`). An empty or invalid document gives an empty editor. The
  // undo history starts after it, so Cmd/Ctrl+Z cannot undo the load.
  private load(value: unknown): void {
    const editor = this.editor;
    if (editor === null) return;

    const root = readRoot(value);
    let state: EditorState | null = null;

    if (root !== null) {
      try {
        state = editor.parseEditorState(asState(prepareRoot(root, registeredTypes(editor))));
      } catch (error) {
        console.error("Kotoba: the document could not be read", error);
      }
    }

    if (state === null || state.isEmpty()) {
      state = editor.parseEditorState(asState(EMPTY_ROOT));
    }

    // Without a change of the document, the first load writes the hidden
    // input but does not push `kotoba:change`.
    editor.setEditorState(state, { tag: REMOTE_TAG });
    editor.dispatchCommand(CLEAR_HISTORY_COMMAND, undefined);
    this.uploads?.reset();
    this.prompts?.close();
  }

  private setContent(doc: unknown): void {
    if (this.config.collab) {
      this.announce("Use Kotoba.Collab.transact to change a shared document.");
      return;
    }
    // A suggestion's place may not be in the new document.
    this.suggestions?.discard();
    this.load(doc);
  }

  private stream(payload: Record<string, unknown>): void {
    const { ref, op } = payload;
    if (typeof ref !== "string" || this.suggestions === null) return;
    if (op === "start") this.suggestions.start(ref, payload);
    else if (op === "chunk" && typeof payload.text === "string") this.suggestions.chunk(ref, payload.text);
    else if (op === "end") this.suggestions.end(ref);
    else if (op === "cancel") this.suggestions.cancel(ref);
  }

  private insertNode(json: unknown, ref: string | undefined): void {
    const editor = this.editor;
    if (editor === null || !isObject(json) || typeof json.type !== "string") {
      console.error("Kotoba: insert_node needs a node with a type", json);
      return;
    }
    if (!registeredTypes(editor).has(json.type)) {
      console.error(`Kotoba: insert_node has a node of an unknown type "${json.type}"`);
      return;
    }

    editor.update(() => {
      const node = $parseSerializedNode({ version: 1, ...json } as unknown as SerializedLexicalNode);
      this.uploads?.$insert(node, ref);
    });
  }

  private setReadonly(readonly: boolean): void {
    this.appReadonly = readonly;
    this.applyReadonly(readonly || this.collaboration?.readonly === true);
  }

  private applyReadonly(readonly: boolean): void {
    const { editor, editable } = this;
    if (editor === null || editable === null) return;
    editable.contentEditable = String(!readonly);
    if (readonly) editable.setAttribute("aria-readonly", "true"); else editable.removeAttribute("aria-readonly");
    editor.setEditable(!readonly);
    this.toolbar?.setDisabled(readonly);
    this.selectionToolbar?.setDisabled(readonly);
    if (readonly) this.prompts?.close();
  }

  // LiveView patches the data attributes of a `phx-update="ignore"` element
  // and then calls `updated()`. A new `data-readonly` value sets the state; the
  // same value again does not undo a `set_readonly` push. `data-change` turns
  // the `kotoba:change` pushes on or off.
  syncAttributes(): void {
    if (this.editable !== null) syncAria(this.el, this.editable);
    this.setChange(this.el.dataset.change === "true");
    const value = this.el.dataset.readonly;
    if (value === this.readonlyAttribute) return;
    this.readonlyAttribute = value;
    void this.ready.then(() => {
      if (!this.destroyed) this.setReadonly(value !== undefined && value !== "false");
    });
  }

  private updatePlaceholder(): void {
    const { editor, placeholder } = this;
    if (editor === null || placeholder === null) return;
    const empty = editor.getEditorState().read(() => {
      const root = $getRoot();
      const first = root.getFirstChild();
      return (
        root.getChildrenSize() === 0 ||
        (root.getChildrenSize() === 1 && $isParagraphNode(first) && first.getChildrenSize() === 0)
      );
    });
    placeholder.hidden = !empty || this.config.placeholder === "";
  }

  private setChange(change: boolean): void {
    if (change === this.change) return;
    this.change = change;
    if (!change) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
  }

  private schedulePush(): void {
    if (!this.change) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.flush(), this.config.debounce);
  }

  private flush(): void {
    clearTimeout(this.timer);
    this.timer = undefined;
    if (!this.change || this.destroyed || this.json === "" || this.json === this.pushed) return;
    this.pushed = this.json;
    this.push("kotoba:change", {
      v: PROTOCOL_VERSION,
      id: this.id,
      doc: JSON.parse(this.json) as DocumentEnvelope,
    });
  }

  private push(event: string, payload: object): void {
    const target = this.el.getAttribute("phx-target");
    if (target !== null && target !== "") this.hook.pushEventTo(target, event, payload);
    else this.hook.pushEvent(event, payload);
  }

  // LiveView builds the form data for phx-change and phx-submit with
  // `new FormData(form)`. The `formdata` event puts the current document in
  // it, even when a patch from the server has reset the hidden input.
  private watchForm(): void {
    const input = this.config.input;
    const form = input?.form;
    if (input === null || !form) return;

    const onFormData = (event: FormDataEvent): void => {
      if (this.json !== "" && input.name !== "") event.formData.set(input.name, this.json);
    };
    const onSubmit = (): void => {
      if (this.json !== "") input.value = this.json;
    };

    form.addEventListener("formdata", onFormData);
    form.addEventListener("submit", onSubmit, true);
    this.cleanups.push(() => {
      form.removeEventListener("formdata", onFormData);
      form.removeEventListener("submit", onSubmit, true);
    });
  }

  // A LiveView patch of the form sets the hidden input back to the value
  // that the server rendered. LiveView dispatches `phx:update` on the
  // document after each patch; the input then gets the current document
  // again. (The server replaces the document with `set_content`, not
  // through the input.)
  //
  // The `formdata` listener of `watchForm` is the guaranteed path: every
  // phx-change, phx-submit, form recovery and native submit builds its data
  // with `new FormData(form)`. `phx:update` is not a documented LiveView
  // event; it serves only code that reads `input.value` directly.
  private watchPatches(): void {
    const input = this.config.input;
    if (input === null) return;

    const onPatch = (): void => {
      if (this.json !== "" && input.value !== this.json) input.value = this.json;
    };

    document.addEventListener("phx:update", onPatch);
    this.cleanups.push(() => document.removeEventListener("phx:update", onPatch));
  }

  private readonly announce = (message: string): void => {
    this.live.textContent = "";
    window.setTimeout(() => {
      this.live.textContent = message;
    }, 50);
  };

  destroy(): void {
    this.destroyed = true;
    this.collaboration?.dispose();
    clearTimeout(this.timer);
    for (const ref of this.handlers) this.hook.removeHandleEvent(ref);
    this.prompts?.dispose();
    this.suggestions?.dispose();
    for (const floating of this.floating) floating.dispose();
    const menu = this.selectionToolbar?.element;
    this.selectionToolbar?.dispose();
    // The menu that the hook built; the app's own element stays.
    if (menu !== undefined && !menu.hasAttribute("data-kotoba-selection-menu")) menu.remove();
    this.toolbar?.dispose();
    this.link?.dispose();
    this.colors?.dispose();
    this.uploads?.dispose();
    for (const cleanup of this.cleanups.reverse()) cleanup();
    this.editor?.setRootElement(null);
    this.editor = null;
  }
}

// The state of the field, from the data attributes of the hook element
// (LiveView patches only those on a `phx-update="ignore"` element): the
// editable element follows it, and loses an attribute that goes away.
function syncAria(from: HTMLElement, to: HTMLElement): void {
  for (const [key, name] of [
    ["ariaDescribedby", "aria-describedby"],
    ["ariaInvalid", "aria-invalid"],
  ] as const) {
    const value = from.dataset[key];
    if (value === undefined || value === "") to.removeAttribute(name);
    else if (to.getAttribute(name) !== value) to.setAttribute(name, value);
  }
}

// The editable element takes the label of the hook element.
function copyLabel(from: HTMLElement, to: HTMLElement): void {
  for (const name of ["aria-label", "aria-labelledby"]) {
    const value = from.getAttribute(name);
    if (value !== null && !to.hasAttribute(name)) {
      to.setAttribute(name, value);
      from.removeAttribute(name);
    }
  }
}

/** The LiveView hook. */
export const Kotoba = {
  mounted(this: KotobaHook): void {
    this.kotoba = new Instance(this);
  },
  updated(this: KotobaHook): void {
    this.kotoba?.syncAttributes();
  },
  destroyed(this: KotobaHook): void {
    this.kotoba?.destroy();
    this.kotoba = undefined;
  },
};
