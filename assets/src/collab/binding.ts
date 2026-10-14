import type { LexicalNode, PointType, SerializedLexicalNode } from "lexical";
import type { CollaborationHost } from "../collaboration";
import { apply, atomLocation, findAtom, children, clone, equal, spans, textAttrs, visibleAtoms, uuid, TEXT_TYPES, type Attrs, type Atom, type Operation, type State, type WireNode } from "./model";

export const COLLAB_TAG = "kotoba-collab";
interface NodeRef { id: string; atoms?: string[] }
export interface Anchor { node: string; before: string | null; offset?: number }
export interface SharedSelection { anchor: Anchor; focus: Anchor }
export interface Change { forward: Operation[]; inverse: Operation[] }
interface ViewNode { id: string; data: Attrs; element: boolean; key: string; children: ViewNode[]; characters?: { text: string; attrs: Attrs; id?: string }[]; source?: string[] }

/** Incremental adapter: Lexical keys are local; the model's identities persist. */
export class Binding {
  private readonly host: CollaborationHost;
  private refs = new Map<string, NodeRef>();
  private keys = new Map<string, string>();
  private rendering = false;
  private current: State | null = null;

  constructor(host: CollaborationHost) { this.host = host; }

  selection(): SharedSelection | null {
    let selection: SharedSelection | null = null;
    this.host.editor.getEditorState().read(() => {
      const current = this.host.api.lexical.$getSelection();
      if (this.host.api.lexical.$isRangeSelection(current)) {
        const anchor = this.anchor(current.anchor);
        const focus = this.anchor(current.focus);
        if (anchor && focus) selection = { anchor, focus };
      }
    });
    return selection;
  }

  private anchor(point: PointType): Anchor | null {
    const ref = this.refs.get(point.key);
    if (!ref || !this.current) return null;
    if (!ref.atoms) return { node: ref.id, before: null, offset: point.offset };
    let offset = 0;
    let before: string | null = null;
    for (const atom of visibleAtoms(this.current, ref.id).filter(atom => ref.atoms!.includes(atom.id))) {
      if (offset + atom.text.length > point.offset) break;
      offset += atom.text.length;
      before = atom.id;
    }
    // A run can start in the middle of a logical buffer.
    if (before === null && ref.atoms.length > 0) {
      const all = visibleAtoms(this.current, ref.id);
      const index = all.findIndex(atom => atom.id === ref.atoms![0]);
      before = all[index - 1]?.id ?? null;
    }
    return { node: ref.id, before };
  }

  /** Read edits as semantic transactions, with origin-aware inverse operations. */
  capture(state: State): Change | null {
    if (this.rendering) return null;
    let change: Change | null = null;
    this.host.editor.getEditorState().read(() => {
      const root = this.host.api.lexical.$getRoot();
      const view = this.readElement(root, new Set(), state.root);
      this.identifyCharacters(view, state);
      let working = clone(state);
      const forward: Operation[] = [];
      const inverse: Operation[] = [];
      const desired = new Set<string>();
      const emit = (op: Operation, undo: Operation): void => {
        working = apply(working, [op]);
        forward.push(op);
        inverse.unshift(undo);
      };

      const visit = (view: ViewNode, parent: string | null, after: string | null): void => {
        desired.add(view.id);
        const old = working.nodes[view.id];
        if (!old && parent !== null) {
          const tag = uuid();
          emit({ op: "insert_node", id: view.id, parent, after, data: view.data, element: view.element }, { op: "node_visibility", id: view.id, deleted: true, tag, if_empty: view.element || view.data.type === "text" });
        } else if (old && parent !== null) {
          const siblings = children(working, parent);
          const previous = siblings[siblings.indexOf(view.id) - 1] ?? null;
          if (old.parent !== parent || previous !== after) {
            const oldSiblings = old.parent ? children(working, old.parent) : [];
            const oldAfter = oldSiblings[oldSiblings.indexOf(view.id) - 1] ?? null;
            const stamp = uuid();
            emit({ op: "move_node", id: view.id, parent, after, stamp }, { op: "move_node", id: view.id, parent: old.parent!, after: oldAfter, expected_move: stamp, stamp: uuid() });
          }
        }
        const data = working.nodes[view.id].data;
        const values: Attrs = {};
        const previous: Attrs = {};
        for (const [key, value] of Object.entries(view.data)) {
          if (["type", "version"].includes(key) || equal(data[key], value)) continue;
          values[key] = value;
          previous[key] = data[key] ?? null;
        }
        if (Object.keys(values).length > 0) {
          const stamp = uuid();
          emit({ op: "set_attrs", id: view.id, values, stamp }, { op: "set_attrs", id: view.id, values: previous, expected_versions: Object.fromEntries(Object.keys(values).map(key => [key, stamp])), stamp: uuid() });
        }
        if (!view.characters) {
          let anchor: string | null = null;
          for (const child of view.children) { visit(child, view.id, anchor); anchor = child.id; }
        }
      };

      visit(view, null, null);
      const textViews: ViewNode[] = [];
      const collect = (node: ViewNode): void => { if (node.characters) textViews.push(node); else node.children.forEach(collect); };
      collect(view);
      const desiredAtoms = new Set(textViews.flatMap(node => node.characters!.map(character => character.id!)));
      for (const text of textViews) this.diffText(() => working, text, emit);
      for (const [buffer, atoms] of Object.entries(state.texts)) {
        const removed = atoms.filter(atom => !atom.deleted && !atom.moved_to && !desiredAtoms.has(atom.id)).map(atom => atom.id);
        if (removed.length) {
          const tag = uuid();
          emit({ op: "text_visibility", id: buffer, atoms: removed, deleted: true, tag }, { op: "text_visibility", id: buffer, atoms: removed, deleted: false, tag });
        }
      }
      // Moves happen before deletions, so moved descendants stay alive.
      for (const [id, node] of Object.entries(working.nodes)) {
        if (id === state.root || node.deleted || desired.has(id) || !node.parent || !desired.has(node.parent)) continue;
        const tag = uuid();
        emit({ op: "node_visibility", id, deleted: true, tag }, { op: "node_visibility", id, deleted: false, tag });
      }
      this.current = working;
      this.mapView(view, working);
      if (forward.length > 0) change = { forward, inverse };
    });
    return change;
  }

  private readElement(node: LexicalNode, used: Set<string>, id?: string): ViewNode {
    const json = node.exportJSON() as unknown as WireNode;
    const persistent = id ?? this.refs.get(node.getKey())?.id ?? uuid();
    used.add(persistent);
    const data = { ...json };
    delete data.children;
    const view: ViewNode = { id: persistent, data, element: this.host.api.lexical.$isElementNode(node), key: node.getKey(), children: [] };
    if (!this.host.api.lexical.$isElementNode(node)) return view;
    const list = node.getChildren().filter(child => child.getType() !== "kotoba-upload");
    for (let index = 0; index < list.length; index++) {
      const child = list[index];
      if (!TEXT_TYPES.has(child.getType())) { view.children.push(this.readElement(child, used)); continue; }
      const group: LexicalNode[] = [child];
      while (index + 1 < list.length && TEXT_TYPES.has(list[index + 1].getType())) group.push(list[++index]);
      const refs = group.map(text => this.refs.get(text.getKey())).filter((value): value is NodeRef => value !== undefined);
      const ref = refs.find(value => !used.has(value.id));
      const textView: ViewNode = { id: ref?.id ?? uuid(), data: { type: "text", version: 1 }, element: false, key: child.getKey(), children: [], characters: [], source: [...new Set(refs.flatMap(value => value.atoms ?? []))] };
      used.add(textView.id);
      for (const text of group) {
        const json = text.exportJSON() as unknown as WireNode;
        const attrs = textAttrs(json);
        for (const character of Array.from(String(json.text ?? ""))) textView.characters!.push({ text: character, attrs });
        textView.children.push({ id: textView.id, data: json, element: false, key: text.getKey(), children: [], characters: Array.from(String(json.text ?? "")).map(character => ({ text: character, attrs })) });
      }
      view.children.push(textView);
    }
    return view;
  }

  private identifyCharacters(view: ViewNode, state: State): void {
    const groups: ViewNode[] = [];
    const collect = (node: ViewNode): void => { if (node.characters) groups.push(node); else node.children.forEach(collect); };
    collect(view);
    const used = new Set<string>();
    const match = (old: Atom[], next: NonNullable<ViewNode["characters"]>): void => {
      let prefix = 0;
      while (prefix < old.length && prefix < next.length && old[prefix].text === next[prefix].text) {
        next[prefix].id = old[prefix].id; used.add(old[prefix].id); prefix++;
      }
      let suffix = 0;
      while (suffix < old.length - prefix && suffix < next.length - prefix && old[old.length - suffix - 1].text === next[next.length - suffix - 1].text) {
        const atom = old[old.length - suffix - 1];
        next[next.length - suffix - 1].id = atom.id; used.add(atom.id); suffix++;
      }
    };
    for (const group of groups) {
      const old = (group.source ?? []).map(id => findAtom(state, id)).filter((atom): atom is Atom => !!atom && !atom.deleted && !used.has(atom.id));
      match(old, group.characters!);
    }
    // Splits and wrappers create new Lexical keys. Match their remaining text
    // against unclaimed identities in document order before allocating IDs.
    const old: Atom[] = [];
    const walk = (id: string): void => { for (const child of children(state, id)) { if (state.texts[child]) old.push(...visibleAtoms(state, child).filter(atom => !used.has(atom.id))); else walk(child); } };
    walk(state.root);
    const remaining = groups.flatMap(group => group.characters!.filter(character => !character.id));
    match(old, remaining);
    remaining.forEach(character => { character.id ??= uuid(); });
  }

  private diffText(getState: () => State, view: ViewNode, emit: (op: Operation, undo: Operation) => void): void {
    let after: string | null = null;
    const patches = new Map<string, { atoms: string[]; values: Attrs; previous: Attrs }>();
    for (let index = 0; index < view.characters!.length; index++) {
      const character = view.characters![index];
      const id = character.id!;
      let state = getState();
      let atom = findAtom(state, id);
      if (!atom) {
        const inserted: Atom[] = [];
        do {
          const next = view.characters![index];
          inserted.push({ id: next.id!, text: next.text, attrs: clone(next.attrs), deleted: false, deletions: [], versions: {} });
          if (index + 1 >= view.characters!.length || findAtom(state, view.characters![index + 1].id!)) break;
          index++;
        } while (true);
        const anchor = after ? findAtom(state, after) : visibleAtoms(state, view.id)[0];
        const op: Operation = { op: "insert_text", id: view.id, after, atoms: inserted };
        if (anchor) { op.inherit = anchor.id; op.base_attrs = anchor.attrs; }
        emit(op, { op: "text_visibility", id: view.id, atoms: inserted.map(atom => atom.id), deleted: true, tag: uuid() });
        after = inserted[inserted.length - 1].id;
        continue;
      }
      const source = atomLocation(state, id)!;
      const sourceAtoms = visibleAtoms(state, source);
      const previous = sourceAtoms[sourceAtoms.findIndex(value => value.id === id) - 1]?.id ?? null;
      if (source !== view.id || previous !== after) {
        const stamp = uuid();
        const moving = [id];
        if (source !== view.id) {
          const sourceIndex = sourceAtoms.findIndex(value => value.id === id);
          for (let cursor = index + 1; cursor < view.characters!.length; cursor++) {
            const candidate = view.characters![cursor].id!;
            if (sourceAtoms[sourceIndex + cursor - index]?.id !== candidate) break;
            moving.push(candidate);
          }
        }
        emit({ op: "move_text", id: view.id, after, atoms: moving, stamp }, { op: "move_text", id: source, after: previous, atoms: moving, expected_moves: Object.fromEntries(moving.map(id => [id, stamp])), stamp: uuid() });
        state = getState();
        atom = findAtom(state, id)!;
      }
      const values: Attrs = {};
      const prior: Attrs = {};
      for (const [key, value] of Object.entries(character.attrs)) {
        if (equal(atom.attrs[key], value)) continue;
        values[key] = value;
        prior[key] = atom.attrs[key] ?? null;
      }
      if (Object.keys(values).length) {
        const key = JSON.stringify([values, prior]);
        const patch = patches.get(key) ?? { atoms: [], values, previous: prior };
        patch.atoms.push(id);
        patches.set(key, patch);
      }
      after = id;
    }
    for (const patch of patches.values()) {
      const stamp = uuid();
      emit({ op: "set_text_attrs", id: view.id, atoms: patch.atoms, values: patch.values, stamp }, { op: "set_text_attrs", id: view.id, atoms: patch.atoms, values: patch.previous, expected_versions: Object.fromEntries(Object.keys(patch.values).map(key => [key, stamp])), stamp: uuid() });
    }
  }

  private mapView(view: ViewNode, state: State): void {
    const refs = new Map<string, NodeRef>();
    const keys = new Map<string, string>();
    const walk = (node: ViewNode): void => {
      if (node.characters) {
        const atoms = visibleAtoms(state, node.id);
        let offset = 0;
        for (const run of node.children) {
          const ids = atoms.slice(offset, offset + run.characters!.length).map(atom => atom.id);
          refs.set(run.key, { id: node.id, atoms: ids });
          offset += run.characters!.length;
        }
      } else {
        refs.set(node.key, { id: node.id });
        keys.set(node.id, node.key);
        node.children.forEach(walk);
      }
    };
    walk(view);
    this.refs = refs;
    this.keys = keys;
  }

  render(state: State, preserveSelection = true): void {
    const selection = preserveSelection ? this.selection() : null;
    const api = this.host.api.lexical;
    this.rendering = true;
    // An editor without focus keeps its selection in the model only: setting the DOM
    // selection would take the focus (and the caret) from another editor of the page.
    const focused = this.host.editable.contains(document.activeElement);
    const nextRefs = new Map<string, NodeRef>();
    const nextKeys = new Map<string, string>();
    this.host.editor.update(() => {
      const root = api.$getRoot();
      const reconcile = (id: string, existing?: LexicalNode): LexicalNode => {
        const model = state.nodes[id];
        let node = existing ?? (this.keys.has(id) ? api.$getNodeByKey(this.keys.get(id)!) : null);
        const json = { ...model.data, type: String(model.data.type), ...(model.element ? { children: [] } : {}) } as WireNode;
        if (!node || node.getType() !== json.type) node = api.$parseSerializedNode(json as unknown as SerializedLexicalNode);
        else if (!equal(node.exportJSON() && this.withoutChildren(node.exportJSON() as unknown as Attrs), model.data)) {
          // Built-in elements implement updateFromJSON; app decorators may only implement importJSON.
          if (api.$isElementNode(node)) node.updateFromJSON(json as never);
          else node = api.$parseSerializedNode(json as unknown as SerializedLexicalNode);
        }
        nextRefs.set(node.getKey(), { id });
        nextKeys.set(id, node.getKey());
        if (api.$isElementNode(node)) {
          const desired: LexicalNode[] = [];
          for (const child of children(state, id)) {
            if (state.texts[child]) {
              for (const span of spans(state, child)) {
                const old = [...this.refs].find(([key, ref]) => ref.atoms?.some(atom => span.atoms.some(value => value.id === atom)) && !nextRefs.has(key));
                let text = old ? api.$getNodeByKey(old[0]) : null;
                if (!text || text.getType() !== span.json.type || !api.$isTextNode(text)) text = api.$parseSerializedNode(span.json as unknown as SerializedLexicalNode);
                else text.updateFromJSON(span.json as never);
                nextRefs.set(text.getKey(), { id: child, atoms: span.atoms.map(atom => atom.id) });
                desired.push(text);
              }
            } else desired.push(reconcile(child));
          }
          // An upload marker is local and stays attached until its owner completes it.
          const markers = node.getChildren().filter(child => child.getType() === "kotoba-upload");
          const current = node.getChildren();
          if (current.length !== desired.length + markers.length || desired.some((child, index) => current[index]?.getKey() !== child.getKey())) node.splice(0, node.getChildrenSize(), [...desired, ...markers]);
        }
        return node;
      };
      reconcile(state.root, root);
      this.refs = nextRefs;
      this.keys = nextKeys;
      this.current = state;
      if (selection) {
        const anchor = this.point(selection.anchor);
        const focus = this.point(selection.focus);
        if (anchor && focus) {
          const range = api.$createRangeSelection();
          range.anchor.set(anchor.key, anchor.offset, anchor.type);
          range.focus.set(focus.key, focus.offset, focus.type);
          api.$setSelection(range);
        }
      }
    }, { tag: focused ? COLLAB_TAG : [COLLAB_TAG, "skip-dom-selection"], discrete: true });
    this.rendering = false;
  }

  private withoutChildren(data: Attrs): Attrs { const attrs = { ...data }; delete attrs.children; return attrs; }

  private point(anchor: Anchor): { key: string; offset: number; type: "text" | "element" } | null {
    if (!this.current) return null;
    const location = atomLocation(this.current, anchor.before) ?? anchor.node;
    if (!this.current.nodes[location] || this.current.nodes[location].deleted) return null;
    if (anchor.offset !== undefined) {
      const key = this.keys.get(anchor.node);
      const node = key ? this.host.api.lexical.$getNodeByKey(key) : null;
      return node && this.host.api.lexical.$isElementNode(node) ? { key: node.getKey(), offset: Math.min(anchor.offset, node.getChildrenSize()), type: "element" } : null;
    }
    const all = (this.current.texts[location] ?? []).filter(atom => !atom.moved_to);
    const index = anchor.before === null ? -1 : all.findIndex(atom => atom.id === anchor.before);
    let previous: Atom | undefined;
    for (let cursor = index; cursor >= 0; cursor--) if (!all[cursor].deleted) { previous = all[cursor]; break; }
    const entries = [...this.refs].filter(([, ref]) => ref.id === location && ref.atoms);
    const entry = previous ? entries.find(([, ref]) => ref.atoms!.includes(previous!.id)) : entries[0];
    if (!entry) {
      const parent = this.current.nodes[anchor.node].parent;
      const key = parent ? this.keys.get(parent) : null;
      return key ? { key, offset: 0, type: "element" } : null;
    }
    let offset = 0;
    if (previous) for (const atom of visibleAtoms(this.current, location).filter(atom => entry[1].atoms!.includes(atom.id))) {
      offset += atom.text.length;
      if (atom.id === previous.id) break;
    }
    return { key: entry[0], offset, type: "text" };
  }

  /** Maps awareness anchors to DOM points for the cursor layer. */
  domPoint(anchor: Anchor): { node: Node; offset: number } | null {
    let point: ReturnType<Binding["point"]> = null;
    this.host.editor.getEditorState().read(() => { point = this.point(anchor); });
    const resolved = point as { key: string; offset: number; type: "text" | "element" } | null;
    if (!resolved) return null;
    const element = this.host.editor.getElementByKey(resolved.key);
    if (!element) return null;
    if (resolved.type === "element") return { node: element, offset: Math.min(resolved.offset, element.childNodes.length) };
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    let remaining = resolved.offset;
    let text = walker.nextNode();
    while (text) {
      if (remaining <= (text.textContent?.length ?? 0)) return { node: text, offset: remaining };
      remaining -= text.textContent?.length ?? 0;
      text = walker.nextNode();
    }
    return null;
  }
}

/** Redo reuses identities; it restores inserted nodes/characters rather than reinserting them. */
export function redo(change: Change): Operation[] {
  return change.forward.map(op => {
    if (op.op === "insert_node") {
      const undo = change.inverse.find(inverse => inverse.op === "node_visibility" && inverse.id === op.id);
      return { op: "node_visibility", id: op.id, deleted: false, tag: undo && undo.op === "node_visibility" ? undo.tag : "" };
    }
    if (op.op === "insert_text") {
      const undo = change.inverse.find(inverse => inverse.op === "text_visibility" && inverse.id === op.id && inverse.atoms.some(atom => op.atoms.some(inserted => inserted.id === atom)));
      return { op: "text_visibility", id: op.id, atoms: op.atoms.map(atom => atom.id), deleted: false, tag: undo && undo.op === "text_visibility" ? undo.tag : "" };
    }
    const result = clone(op);
    if (result.op === "set_attrs" || result.op === "set_text_attrs") {
      const inverse = change.inverse.find(inverse => inverse.op === result.op && inverse.id === result.id && (result.op !== "set_text_attrs" || (inverse.op === "set_text_attrs" && equal(inverse.atoms, result.atoms))) && "values" in inverse && Object.keys(inverse.values).some(key => Object.hasOwn(result.values, key)));
      if (inverse && "stamp" in inverse && inverse.stamp) result.expected_versions = Object.fromEntries(Object.keys(result.values).map(key => [key, inverse.stamp!]));
    }
    if (result.op === "move_text") {
      const inverse = change.inverse.find(inverse => inverse.op === "move_text" && equal(inverse.atoms, result.atoms));
      if (inverse?.op === "move_text") result.expected_moves = Object.fromEntries(result.atoms.map(id => [id, inverse.stamp]));
    }
    if (result.op === "move_node") {
      const inverse = change.inverse.find(inverse => inverse.op === "move_node" && inverse.id === result.id);
      if (inverse?.op === "move_node" && inverse.stamp) result.expected_move = inverse.stamp;
    }
    return result;
  });
}
