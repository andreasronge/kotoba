# Changelog

All notable changes to Kotoba are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Kotoba follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-10-17

Full Markdown. This release has breaking changes, listed under Changed.

### Added

- `Kotoba.Content.from_markdown/2` reads CommonMark and GitHub Flavored
  Markdown with MDEx (comrak, a port of GitHub's cmark-gfm): setext
  headings, `__` emphasis, nested emphasis, entities and escapes,
  reference links, link titles, autolinks, images, `+` bullets and `1)`
  lists, nested lists and check lists, lazy lines, `~~~` and indented code,
  tables with column alignment, and footnotes. Every example of the GFM
  spec (CommonMark included) reads into Kotoba and writes back to Markdown
  that renders the same, but for raw HTML, which is text, and list items
  that hold blocks (see below); a test runs them all.
- `from_markdown/2` takes `features:`: a construct whose feature is off
  becomes its closest form, with no text lost.
- **Pasted Markdown** becomes rich text: plain text that reads as Markdown
  (and no rich HTML) goes to the server, which reads it as
  `from_markdown/2` does, with the editor's features. `<.kotoba>` renders
  the server's half itself (`Kotoba.MarkdownPaste`, a LiveComponent): an
  app adds no code. `paste_markdown={false}` turns it off.
- **Quotes that hold blocks**: paragraphs, lists, code, tables and other
  quotes, with Lexical's own `shadowRoot` opt-in on the quote node.
- **Images from a URL** (`image` node, the `images` feature): Markdown's
  `![alt](url "title")`, in the text. The URL is checked as a link's is,
  and the `:untrusted` policy renders the alternative text.
- **Footnotes** (`footnotereference` and `footnotedefinition` nodes, the
  `footnotes` feature), numbered in the order of their first reference,
  in a list at the end of the rendered HTML.
- **Blank lines**: the empty paragraphs that a person types between
  blocks keep their height in HTML (`<p><br></p>`) and are `&nbsp;` in
  Markdown, which reads back. The `blank_lines: :collapse` render option
  and `<.kotoba blank_lines={:collapse}>` leave them out.
- Table columns keep their alignment (`kotoba-align-*` classes, `:-:` in
  Markdown).

### Changed

- **Breaking:** MDEx is a dependency: a native library, precompiled for
  Linux (glibc 2.35 or later, and musl), macOS, Windows and FreeBSD; on
  another system it builds with Rust.
- **Breaking:** the lines of a Markdown paragraph are one line, as
  CommonMark has them (a line ending with two spaces or `\` is a line
  break). The old reader made each line a line break.
- **Breaking:** a quote read from Markdown is a quote of blocks:
  `<blockquote><p>...</p></blockquote>`.
- **Breaking:** `image`, `footnotereference` and `footnotedefinition` are
  built-in node types: an app node cannot have them.
- **Breaking:** `h5` and `h6` render as themselves (they were `h4`).
- The Markdown of `Kotoba.Renderer.to_markdown/2` nests formats (a format
  opens once over the text that has it), keeps a URL with spaces or
  parentheses in angle brackets, and gives two lists in a row different
  markers, so that it reads back as the same document.
- `Kotoba.Features` has `images` and `footnotes`. An editor with a
  `features` list has them only when the list names them.
- A list item with several paragraphs, or with a code block, a quote or a
  table, reads as an item with line breaks and the blocks after the list:
  a Lexical list item holds inline content only.

## [0.2.2] - 2026-10-17

### Changed

- Kotoba supports Phoenix 1.7 and Phoenix LiveView 1.1 (it needed Phoenix
  1.8 and LiveView 1.2): it requires `~> 1.7.14 or ~> 1.8` and `~> 1.1`.
  Nothing changes for an app on the newer versions. The floor job of CI
  runs the tests on Elixir 1.18 with Phoenix 1.7 and LiveView 1.1.

### Fixed

- A colleague's edit in a shared editor no longer takes the focus and the
  caret from another editor of the page, so what the author types next is
  no longer lost: an editor without focus restores its selection in the
  model only.

## [0.2.1] - 2026-10-08

### Fixed

- A text format button (Bold, Italic, Underline, Strikethrough, Inline
  code, Subscript, Superscript, Highlight without the palette), in the
  toolbar or the selection menu, takes the format off text that has it,
  instead of applying it again; at the caret, it turns the format off for
  the next text. The color palette at a caret in colored text shows its
  colors. ([#36](https://github.com/hattoriai/kotoba/issues/36))

## [0.2.0] - 2026-10-02

### Added

- A selection menu: `<.kotoba selection_menu>` shows a menu over the
  selected text, with the default commands (bold, italic, underline,
  strikethrough, inline code, highlight, link) or the commands of a list;
  `<:selection>` with the new `kotoba_selection_menu/1` gives the app's own
  buttons. Alt+F10 focuses it and Escape closes it. It is themed with the
  new `--kotoba-floating-*` properties (also in `kotoba-sumi.css`).
- A link card: with the caret in a link, a card shows the URL (it opens in
  a new tab) and Edit link and Remove link buttons. Cmd/Ctrl+click opens a
  link of the editor.
- `Kotoba.Content.from_markdown/2` reads quotes, check lists, horizontal
  rules, pipe tables, `*italic*`, `~~strikethrough~~` and `***both***`,
  nested formats (a link in bold), and the first number of a numbered
  list: Kotoba's own Markdown now reads back.
- A readable baseline for `<.kotoba_content>` (headings, paragraphs,
  lists, quotes, links, code), with the weight of one class so that an
  element reset such as `a { color: inherit }` does not undo it, and
  `highlightRenderedContent()` to color rendered code blocks with the
  editor's grammars.

- Optional collaboration: shared documents with participant cursors,
  read-only viewers, per-author undo and redo, local draft recovery after
  reconnect or reload, and form submission of an accepted server revision.
  See the [Collaboration guide](guides/collaboration.md) for setup and storage.
- PDF and video previews (#6, #7). A PDF shows in the browser's viewer (an
  `object` with a download link for a browser that has none), in the
  editor and in the rendered HTML. MP4 and WebM videos are checked from
  their bytes (`video/mp4`, `video/webm`; QuickTime, Matroska and audio-only
  files stay `application/octet-stream`), served inline, and play in a
  `video` with controls, `preload="metadata"` and no autoplay; in the
  editor, a video that does not load shows as a file. An attachment's new
  `preview` (a PDF's first page, a video's poster) comes from the
  `:preview` option of `Kotoba.Live.consume_uploads/4`, and must be a safe
  URL. `Kotoba.Storage.Local.Plug` answers `Range` requests (`206`,
  `416`), which video seeking needs. `Kotoba.Nodes.Attachment.pdf?/1` and
  `video?/1` are new.
- Image galleries (#5): a `gallery` node (`Kotoba.Nodes.Gallery`, part of
  the `attachments` feature, valid only under the root) that holds
  attachments, rendered as a `div.kotoba-gallery` grid. Images uploaded
  together make a gallery, each in the place of its own marker (the order
  stays when uploads finish in another order); an image uploaded with an
  image of a gallery selected joins it. The arrow keys move between the
  images and out of the gallery, `Alt+Left` and `Alt+Right` move an
  image, Backspace and Delete remove one, and the live region says the
  position ("2 of 3: cat.png"). The toolbar's Image group (`gallery`,
  `image-previous`, `image-next`) shows while an image is selected: it
  groups the image with the images next to it, ungroups a gallery, and
  moves an image. A gallery of one image becomes that image.
- Suggestions (#26): text that the server streams into the editor, for
  example the answer of a language model. `Kotoba.Live.stream_start/4`
  (`at: :selection | :caret | :after | :end`, `format: :markdown | :text`,
  `label`), `stream_chunk/4`, `stream_end/3`, `stream_cancel/3` and
  `stream_ref/0`. The text shows in a panel as it streams, rendered from
  the whole text at each chunk (a Markdown format cut by a chunk is never
  half a format), with only the editor's features; Accept
  (`Cmd/Ctrl+Enter`) inserts it as one undo step, Reject (Escape) leaves
  the document and the selection as they were, and Stop keeps what has
  come. The `assist` attribute gives the toolbar an Assist menu of the
  app's actions: an action pushes `kotoba:assist` (`ref`, `action`, the
  selected text), and the editor pushes `kotoba:suggestion` (`accept`,
  `reject`, `stop`). Extensions ask with `context.assist/2`. The dev
  server has a fake model, and the Suggestions guide streams Claude with
  Req.
- Guides: Editing features (every feature, its toolbar button, keyboard
  and Markdown shortcuts, colors, links, code blocks, tables and custom
  toolbars) and Rendering (the HTML of each node, styling, HTML/text/
  Markdown outside a page, content without the editor). The quickstart
  has a complete LiveView, and the README a feature overview.
- Richer prompts (#8). A prompt is a callback, or options: `spaces: true`
  (queries with spaces, "Ada Lovelace", ended by two spaces),
  `min_length`, `max_length` (up to 200), `items:` (a local list that the
  editor filters, with no request), `insert: :text` or
  `insert: {:node, type}` (text or a node of the app, from the item's
  `:text` and `:attrs`), and `async: true` (the search runs in
  `start_async`; `Kotoba.Live.handle_prompt_async/3` pushes its result).
  The menu says "Keep typing to search", "Searching…" and "Results did
  not load" (a search that failed, with `error: true` in the reply, or
  that had no answer after 8 seconds), keeps the answers of its queries,
  and drops an answer to an older query. `Kotoba.Prompts.search/3`,
  `config/1`, `specs/1`, `find_spec/2` and `filter/2` are new.
- A color palette (#4): the Highlight button opens a palette of text
  colors and highlights (red, orange, yellow, green, blue, purple, gray)
  and "Remove color", from the mouse and the keyboard. A color is stored
  as a name in the text node's `style`
  (`color: var(--kotoba-color-red)`), and renders as a class
  (`span.kotoba-color-red`, `mark.kotoba-highlight-green`); any other
  style is dropped in the editor and never rendered.
  `Kotoba.Nodes.Text.colors/1` reads them. The highlight format with no
  color stays the default yellow highlight, so existing documents render
  as before. A text color is part of the `highlight` feature.
- Underline, highlight, subscript and superscript are features, with
  their keyboard shortcuts (`Cmd/Ctrl+U`, `Cmd/Ctrl+Shift+H`,
  `Cmd/Ctrl+,`, `Cmd/Ctrl+.`) and toolbar commands. The default toolbar
  has Underline and Highlight; an app's toolbar can have Subscript and
  Superscript. The `==` Markdown shortcut highlights only in an editor
  with `highlight`. Highlighted text has its own colour,
  `--kotoba-highlight` (a light yellow), not the selection's.

- Features: `<.kotoba features={~w(bold italic links lists)}>` gives an
  editor only those built-in features (`Kotoba.Features`: bold, italic,
  underline, strikethrough, highlight, subscript, superscript,
  inline_code, links, headings, quotes, lists, check_lists,
  code_blocks, horizontal_rules, tables, attachments, mentions). A feature
  that is off has no node, toolbar button, Markdown shortcut or keyboard
  shortcut; pasted content of it comes in as paragraphs and text, and a
  stored node of it is kept as an unknown node. With no list, an editor
  has every feature, as before.
- `Kotoba.Content.validate_features/3` refuses, in a changeset, a document
  with a feature that the field does not have; `Kotoba.Features.used/1`
  and `check/2` read the features of a document.
- Extensions: `<.kotoba extensions={[url]}>` loads JavaScript modules that
  add nodes, `register` (commands, transforms, listeners, with a cleanup),
  Markdown shortcuts and toolbar controls (`<extension>:<command>`, with
  `aria-pressed`, visibility and the live region) to an editor. The
  built-in features are extensions of the same form. A module that fails
  to load or register is logged, and the editor mounts with the rest. See
  the Extensions guide, and the example callout extension of the
  development server.
- `kotoba_toolbar` takes an extension's command in a `button` slot.

- A code language picker: in a code block, the toolbar has a "Code
  language" `<select>` with plain text and 28 languages (Bash, C, C++,
  CSS, Diff, Dockerfile, Elixir, Erlang, Go, GraphQL, HTML, Java,
  JavaScript, JSON, Kotlin, Markdown, Objective-C, PHP, PowerShell,
  Python, Ruby, Rust, SQL, Swift, TOML, TypeScript, XML, YAML). The
  editor bundles the grammars of Dockerfile, Erlang, GraphQL, Kotlin,
  PHP, Ruby, TOML and YAML too, and highlights the aliases (`ex`, `yml`,
  `js`...). A block keeps the language name that it has until the person
  picks one; a name that is no language shows as "(not highlighted)".
- `Kotoba.CodeLanguages`, the table of the languages, their labels and
  their aliases, and the `code_languages` attribute of `<.kotoba>` to
  choose the languages of an editor's picker.
- The `code-language` toolbar command, a `<select>` in a custom toolbar.
- Tables. The Table button inserts a table with a header row. In a table,
  a Table group in the toolbar inserts and deletes rows and columns,
  toggles a header row and a header column, and deletes the table. Tab
  and Shift+Tab move between the cells; Escape then Tab leaves the
  editor, as in a list. Pasted HTML tables become tables (merged cells
  are split and cell colours dropped); a table in a table is not allowed.
- `Kotoba.Nodes.Table`, `Kotoba.Nodes.TableRow` and
  `Kotoba.Nodes.TableCell` read the JSON of `@lexical/table`. The HTML is
  a `table.kotoba-table` in a `div.kotoba-table-scroll`, with a `thead`
  for a header row and `th` with `scope`; the text has a line for each
  row; the Markdown is a GitHub Flavored Markdown table. The sanitizer
  keeps a table under the root, rows in tables and cells in rows. The
  editor's layout keys (column widths, cell colours) round-trip and are
  not rendered.
- Alt+F10 in the editor moves the focus to the toolbar, the way to the
  table controls from a cell.
- `Kotoba.Renderer.text_each/2`, the text counterpart of `markdown_each/2`.
- The toolbar commands `table`, `table-row-before`, `table-row-after`,
  `table-column-before`, `table-column-after`, `table-header-row`,
  `table-header-column`, `table-delete-row`, `table-delete-column` and
  `table-delete`.
- A prompt can have a label, the accessible name of its menu:
  `prompts={[people: {fun, label: "People in the workshop"}]}`. Without
  one, the menu is still named "<prompt> suggestions".
  `Kotoba.Prompts.labels/1` gives the labels, and the component sends
  them to the editor as `data-prompt-labels`.

### Changed

- The editor bundle is about 24 KB larger (8 KB with gzip), for features
  and extensions: `@lexical/utils` and `@lexical/selection` are whole in
  it, for the extensions.
- A code block with no language is plain text in the editor, as in the
  HTML. Lexical highlighted it as JavaScript.
- The editor bundle is about 25 KB larger (7 KB with gzip), for the new
  grammars.
- `table`, `tablerow` and `tablecell` are built-in node types now, so an
  app node cannot have one of these types.
- The editor bundle is about 70 KB larger (20 KB with gzip), for
  `@lexical/table`.

### Fixed

- An empty table cell keeps the height of a line, in the editor and in the
  rendered HTML; it showed as a thin strip.
- `Kotoba.Live.consume_uploads/4` consumes an entry once. LiveView drops
  a consumed entry a message later, so a second call before that (the
  next file done, a form change) consumed it again and crashed the
  LiveView: of several files that finished one after the other, only the
  first was stored.

- A rendered check list (`ul.kotoba-check`) shows a box, checked or not,
  in front of each item, as the editor does; before, `kotoba.css` hid the
  bullets and drew no box.
- The case formats (`lowercase`, `uppercase`, `capitalize`) show in the
  editor and in rendered content (`span.kotoba-uppercase`...).
- `mix kotoba.install` finds the Kotoba package in the project's deps
  directory (`Mix.Project.deps_path/0`), not in `deps/`. In an umbrella
  child or with `MIX_DEPS_PATH`, a Hex dependency is no longer called a
  path dependency, and the style sheet imports and the `NODE_PATH` note
  point at the right directory.

## [0.1.0] - 2026-09-25

The first release.

### Added

- The editor bundle (`priv/static/kotoba.esm.js` and `kotoba.cjs.js`): a
  Lexical 0.51 editor with rich text, history, headings, quotes, lists and
  check lists, links (paste to link, `Cmd/Ctrl+K`, relative URLs and the
  server's allowed schemes), markdown shortcuts, highlighted code blocks,
  horizontal rules, attachments, mentions, a toolbar with Lucide icons, the
  prompt menu, the upload bridge to LiveView uploads, and app node modules.
  The host app does not need Node.js.
- The `Kotoba` LiveView hook. It pushes `kotoba:prompt`, and handles
  `set_content`, `insert_node`, `remove_marker`, `set_readonly`, `focus`
  and `kotoba:prompt_results`. Every message carries the editor id. The
  hidden input and the form data of `phx-change` and `phx-submit` always
  have the current document.
- `kotoba:change` is opt-in: the editor pushes it only with the `change`
  attribute of `<.kotoba>`. A LiveView with an editor needs no
  `kotoba:change` clause unless it sets `change`.
- The editable area follows the field's `aria-invalid` and
  `aria-describedby` on every render (LiveView patches only data
  attributes of the editor element, so the component passes them there).
- Keyboard operation of every command: a toolbar with one tab stop and
  arrow keys, Tab and Shift+Tab in lists, Tab in code blocks, Escape to
  leave the editor, a prompt menu as a `listbox`, and a polite live region.
- `kotoba.css` (structure, themed through `--kotoba-*` properties) and
  `kotoba-sumi.css` (the Sumi theme, with dark and light through
  `data-theme` and `prefers-color-scheme`). A mention has its own
  `--kotoba-mention-text` and `--kotoba-mention-background`; in the Sumi
  theme it is ink on a quiet tint, so it never reads as the blade that a
  Sumi page keeps for what needs attention.
- `Kotoba.Content`: an Ecto type that stores the document with its cached
  HTML and text, with `rerender/2` and `from_markdown/2`.
- `Kotoba.Document`: parses and checks a document, keeps unknown nodes, and
  gives traversal, text, mentions and attachments.
- `Kotoba.Node` (`use Kotoba.Node` with typed fields), the built-in nodes
  under `Kotoba.Nodes`, and the node registry.
- `Kotoba.Renderer`: safe HTML through `Phoenix.HTML`, plain text, and
  Markdown, with `escape_markdown/1` for the Markdown of app nodes.
- `Kotoba.Sanitizer`: structural checks of attributes, nesting and URLs,
  the allowed link schemes (`config :kotoba, allowed_link_schemes:`), and
  the `:default` and `:untrusted` policies.
- `Kotoba.Components`: `<.kotoba>`, `<.kotoba_toolbar>` and
  `<.kotoba_content>`.
- `Kotoba.Live`: `handle_prompt/3`, `consume_uploads/4`, `push_content/3`,
  `insert_node/4`, `set_readonly/3`, `focus/2` and `remove_marker/3`.
- `Kotoba.Prompts`: prompt lists with one-character triggers.
- `Kotoba.Attachments`: keeps only the content types that the bytes of a
  file prove, and cleans file names.
- `Kotoba.Storage` (a behaviour), `Kotoba.Storage.Local` and
  `Kotoba.Storage.Local.Plug` (serves the files with safe headers).
- `mix kotoba.install`, `mix kotoba.gen.node`, and, for work on Kotoba
  itself, `mix kotoba.build` and `mix kotoba.release_check`. The installer
  also sets up an app that has Kotoba as a path dependency: its `app.css`
  imports point at the dependency's directory, and it prints the
  `NODE_PATH` entry that esbuild needs for it.
- `.formatter.exs` exports `field/2` and `field/3` for `import_deps`.
- Guides: quickstart, forms, uploads, prompts, custom nodes, theming,
  security, accessibility and known limits.

[Unreleased]: https://github.com/hattoriai/kotoba/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/hattoriai/kotoba/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/hattoriai/kotoba/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/hattoriai/kotoba/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/hattoriai/kotoba/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hattoriai/kotoba/releases/tag/v0.1.0
