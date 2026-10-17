# Editing features

This guide is the tour of what the editor does, and how to choose it for
each field: the built-in features, their toolbar buttons, keyboard and
Markdown shortcuts, colors, links, code blocks, tables, and the toolbar
itself. To see them all at once, run the development server of this
repository (`mix dev`, see the README).

## The features

Each built-in feature is a part of the editor that a field can have or
not (`Kotoba.Features`):

| Feature | What it is | Toolbar | Keyboard | Markdown |
| --- | --- | --- | --- | --- |
| `bold` | bold text | Bold | `Cmd/Ctrl+B` | `**text**`, `__text__` |
| `italic` | italic text | Italic | `Cmd/Ctrl+I` | `*text*`, `_text_` |
| `underline` | underlined text | Underline | `Cmd/Ctrl+U` | |
| `strikethrough` | struck text | Strikethrough | | `~~text~~` |
| `highlight` | highlights and text colors | Highlight (the palette) | `Cmd/Ctrl+Shift+H` | `==text==` |
| `subscript` | subscript text | (an app's toolbar) | `Cmd/Ctrl+,` | |
| `superscript` | superscript text | (an app's toolbar) | `Cmd/Ctrl+.` | |
| `inline_code` | code in a line | Inline code | | `` `code` `` |
| `links` | links and autolinks | Link | `Cmd/Ctrl+K` | `[text](url)` |
| `headings` | headings 1 to 4 | Heading 1 to 4 | | `# ` to `#### ` |
| `quotes` | block quotes | Quote | | `> ` |
| `lists` | bulleted and numbered lists | Bulleted list, Numbered list | Tab, Shift+Tab | `- `, `* `, `+ `, `1. ` |
| `check_lists` | check lists (needs `lists`) | Check list | Space on a focused box | `[ ] `, `[x] `, `- [ ] ` |
| `code_blocks` | code blocks, highlighted, with a language picker | Code block, Code language | Tab inserts a tab | ` ``` `, ` ```elixir ` |
| `horizontal_rules` | horizontal rules | Horizontal rule | | `---`, `***`, `___` |
| `tables` | tables | Table, and the Table group | Tab, Shift+Tab | |
| `attachments` | files, images and galleries (with `uploads`) | Attach a file, and the Image group | drop, paste; `Alt+Left`, `Alt+Right` in a gallery | |
| `mentions` | prompts and mentions (with `prompts`) | | the trigger | |
| `images` | images from a URL, in the text | | | `![alt](url)` (pasted) |
| `footnotes` | footnotes and their references | | | `[^1]` and `[^1]: text` (pasted) |

Pasted Markdown is not a feature: plain text that reads as Markdown (a
README, a note from a Markdown app) comes in as rich text, read on the
server as `Kotoba.Content.from_markdown/2` reads it, with the features of
the editor. `<.kotoba>` renders the server's half, so the app adds no
code; `paste_markdown={false}` turns it off. Images and footnotes come
from pasted Markdown and from the server; the editor has no button for
them yet.

Suggestions are not a feature: an editor with `assist` has an Assist
button, and any editor shows the text that the server streams with
`Kotoba.Live.stream_start/4` (see [Suggestions](suggestions.md)). A
suggestion has only the editor's features.

`Cmd` is the key on a Mac, `Ctrl` elsewhere. A Markdown shortcut acts as
you type it: `## ` at the start of a line makes a heading, and
`**bold**` becomes bold when you type the last `*`. `***text***` makes
bold and italic text.

Paragraphs, line breaks (`Shift+Enter`), tabs, undo (`Cmd/Ctrl+Z`) and
redo (`Cmd/Ctrl+Shift+Z`) are always there. The case formats
(`lowercase`, `uppercase`, `capitalize`) are not features: the editor
keeps them when they come in a pasted text or a stored document.

## Choose the features of a field

With no `features`, an editor has every feature. Give a list for fewer:

```heex
<.kotoba field={@form[:comment]} id="comment" features={~w(bold italic links lists mentions)} />
<.kotoba field={@form[:body]} id="body" />
```

A feature that is off is not in the editor at all:

* its buttons are not in the default toolbar, and are hidden in a custom
  one;
* its Markdown shortcut types the text, and its keyboard shortcut does
  nothing;
* pasted content of it comes in as plain paragraphs and text: a pasted
  table, heading or code block is paragraphs, and a pasted format is
  dropped;
* a stored node of it loads as an unknown node: the editor shows its type
  in a placeholder, and saves it with no change.

`attachments` needs `uploads` too (see the [Uploads](uploads.md) guide),
and `mentions` needs `prompts` (see [Prompts and mentions](prompts.md)).

### Check them on the server

The editor keeps out what it does not have, but a request can post any
document. Check the field in its changeset:

```elixir
def changeset(comment, attrs) do
  comment
  |> cast(attrs, [:body])
  |> Kotoba.Content.validate_features(:body, ~w(bold italic links lists mentions)a)
end
```

A document with another feature gets the error
`"has content that is not allowed: tables"` (with `validation: :features`
and the names in the error's keys). `Kotoba.Features.used/1` and
`Kotoba.Features.check/2` read the features of a `Kotoba.Document`. App
nodes are not features: the check allows them.

## Text formats and colors

The Text group of the default toolbar has Bold, Italic, Underline,
Strikethrough, Highlight and Inline code. A format button has
`aria-pressed`, and the live region says "Bold on" or "Bold off".

Subscript and superscript are features with their keyboard shortcuts, but
have no button in the default toolbar. An app's toolbar can have them
(`command="subscript"`, `command="superscript"`, see below). Turning one on
turns the other off.

The Highlight button opens the color palette: seven text colors, seven
highlights (red, orange, yellow, green, blue, purple and gray) and
"Remove color". `Cmd/Ctrl+Shift+H` and `==text==` give the default
highlight, yellow. Text colors are part of the `highlight` feature.

The document stores a color as its name, never as a CSS value, and the
HTML has classes: `span.kotoba-color-red` and
`mark.kotoba-highlight-green` (the default highlight is a plain `mark`).
`kotoba.css` gives each name a color that reads on light and dark
backgrounds; the [Theming](theming.md) guide shows how to set your own.
`Kotoba.Nodes.Text.colors/1` reads the colors of a text node, and
`Kotoba.Nodes.Text.palette/0` gives the names.

## Links

The Link button or `Cmd/Ctrl+K` opens a small form for the URL of the
selected text. Enter applies it, an empty URL removes the link, and
Escape closes the form. Pasting a URL over selected text makes a link, and
the editor links the URLs and email addresses that you type (autolinks).

A link can be relative (`/docs`, `#part`) or have an allowed scheme:
`http`, `https` and `mailto` by default. To allow others:

```elixir
config :kotoba, allowed_link_schemes: ~w(http https mailto tel)
```

A link with another scheme becomes its text, in the editor and in the
HTML. The HTML of a link has `rel="noopener nofollow"`.

## Lists and check lists

Tab indents a list item and Shift+Tab outdents it (in an item that is not
indented, Shift+Tab leaves the editor). In a check list, a click on the
box, or Space when the box has the focus, checks the item. The HTML of a
check list is `ul.kotoba-check`, with `li.kotoba-checked` and
`li.kotoba-unchecked` items, which `kotoba.css` draws with a box.

## Code blocks

In a code block, the toolbar shows the code language picker. It offers
plain text and the 28 languages of `Kotoba.CodeLanguages`, and the editor
highlights the code as you type. ` ```elixir ` at the start of a line
makes a code block in that language. To offer fewer languages, give their
ids or aliases:

```heex
<.kotoba field={@form[:body]} id="post-body" code_languages={~w(elixir erlang sql bash)} />
```

A name that is not a language, and an empty list, raise `ArgumentError`.
The list chooses what the picker offers, not what the editor keeps: a
pasted or stored block in another language keeps its language, is
highlighted when the editor knows it, and shows in the picker.

The HTML of a code block is `pre` with `code.language-<language>`, and
no highlighting. To highlight rendered code, use a highlighter of your own
on the page, for example Prism with a Prism theme: the editor's own copy of
Prism does not touch the page's `window.Prism` (see the
[Theming](theming.md) guide).

## Galleries

Images uploaded together make a gallery, a grid of images. Select an image
(a click, or the arrow keys from the text next to it) for the Image group
of the toolbar: Gallery groups the image with the images next to it, or
ungroups its gallery, and Move image left and Move image right (or
`Alt+Left` and `Alt+Right`) reorder it. See the [Uploads](uploads.md)
guide.

## Tables

The Table button inserts a table of three rows and three columns, with a
header row. In a table, the Table group of the toolbar has Insert row
above, Insert row below, Insert column before, Insert column after,
Header row, Header column, Delete row, Delete column and Delete table. Tab
and Shift+Tab move between the cells; Alt+F10 goes to the toolbar.

A pasted HTML table becomes a table. The editor has no command to merge
cells, but it keeps the merged cells of a pasted or stored table
(`colspan`, `rowspan`).

The HTML is a `table.kotoba-table` in a `div.kotoba-table-scroll` (which
scrolls a wide table sideways), with a `thead` for a header row and
`th scope="col"` or `th scope="row"` for header cells. `kotoba.css` styles
it. The Markdown of a table is a GitHub Flavored Markdown table, with the
limits in the [Known limits](limits.md) guide.

## The toolbar

The default toolbar has the buttons of the editor's features, in groups:
Text (formats and Link), Blocks (headings and Quote), Lists, Insert (Code
block, Horizontal rule, Table, Attach a file), Assist (with `assist`), the
extensions' buttons, and History (Undo, Redo). The Code group (the language picker) shows in a
code block, the Table group in a table, and the Image group (Gallery, Move
image left, Move image right) when an image is selected. The toolbar is one tab stop,
with the arrow keys between the buttons (see the
[Accessibility](accessibility.md) guide).

### A custom toolbar

To choose the buttons, their order or their icons, give a `toolbar` slot
with `Kotoba.Components.kotoba_toolbar/1`:

```heex
<.kotoba field={@form[:body]} id="post-body">
  <:toolbar>
    <.kotoba_toolbar>
      <:button command="bold"><.icon name="hero-bold" /></:button>
      <:button command="italic"><.icon name="hero-italic" /></:button>
      <:button command="link" label="Add a link"><.icon name="hero-link" /></:button>
      <:button command="subscript" label="Subscript" class="my-button">x₂</:button>
      <:button command="undo"><.icon name="hero-arrow-uturn-left" /></:button>
    </.kotoba_toolbar>
  </:toolbar>
</.kotoba>
```

Each `button` slot has a `command`, an optional `label` (the accessible
name and the title; the command's own label by default) and an optional
`class`. With no slots, `commands` gives text buttons for a list of
commands:

```heex
<.kotoba_toolbar commands={~w(bold italic underline highlight subscript superscript undo redo)} />
```

`Kotoba.Components.toolbar_commands/0` lists the commands: `bold`,
`italic`, `underline`, `strikethrough`, `highlight`, `code`,
`subscript`, `superscript`, `link`, `h1` to `h4`, `quote`, `bullet`,
`number`, `check`, `code-block`, `rule`, `table`, `upload`, `assist`,
`code-language`, the `table-*` commands, `gallery`, `image-previous`,
`image-next`, `undo` and `redo`. An
extension's control is `<extension>:<command>` (see the
[Extensions](extensions.md) guide). Another command raises
`ArgumentError`.

* The editor adds `role="toolbar"`, the roving tabindex, `aria-pressed`
  and `aria-disabled`; `label` names the toolbar ("Formatting" by
  default), and `class` adds classes.
* The buttons of a feature that the editor does not have are hidden.
* The `table-*` buttons are hidden when the selection is not in a table,
  and `gallery`, `image-previous` and `image-next` when no image is
  selected.
* `code-language` renders a `<select>`, the code language picker: the
  editor fills it, and shows it in a code block.
* `highlight` opens the color palette.
* `assist` opens the Assist menu, and is hidden in an editor with no
  actions.

A toolbar can also be outside the editor, anywhere on the page, with
`for` set to the editor's id:

```heex
<.kotoba_toolbar for="post-body" commands={~w(bold italic link)} />
<.kotoba field={@form[:body]} id="post-body" />
```

## The selection menu

A menu can float over the selected text, as in Notion, Medium or Tiptap's
bubble menu. Turn it on with `selection_menu`:

```heex
<.kotoba field={@form[:body]} id="post-body" selection_menu />
```

The default menu has Bold, Italic, Underline, Strikethrough, Inline code,
Highlight and Link. A list chooses the commands, in order; they are the
toolbar's commands, and an extension's control is
`<extension>:<command>`:

```heex
<.kotoba field={@form[:body]} selection_menu={~w(bold italic link h2 quote callout:toggle)} />
```

The menu shows above a selection of text, or below it when there is no
room above (in the editor or in the window). It waits for the mouse button
to come up, so it does not follow a drag. It does not show for a caret, in
a code block, in a read-only editor, or while the link form, the palette
or a prompt menu is open. Its buttons work as the toolbar's buttons:
`aria-pressed` follows the selection, and the buttons of a feature that
the editor does not have are left out.

* Alt+F10 moves the focus to the menu (to the toolbar when no menu
  shows); the arrow keys move between its buttons.
* Escape closes it until the selection changes.

### An app's own menu

For the app's own icons, labels or classes, give a `selection` slot with
`Kotoba.Components.kotoba_selection_menu/1`. It takes `button` slots, as
`kotoba_toolbar/1` does:

```heex
<.kotoba field={@form[:body]} id="post-body">
  <:selection>
    <.kotoba_selection_menu class="my-menu">
      <:button command="bold"><.icon name="hero-bold" class="size-4" /></:button>
      <:button command="italic"><.icon name="hero-italic" class="size-4" /></:button>
      <:button command="link" label="Add a link"><.icon name="hero-link" class="size-4" /></:button>
    </.kotoba_selection_menu>
  </:selection>
</.kotoba>
```

### Style the menu

The menu is a `div.kotoba-selection-menu` with `data-placement="top"` or
`"bottom"`; its buttons are `.kotoba-toolbar-button`, in
`.kotoba-toolbar-group` elements. These custom properties theme it and the
link card, and each one falls back to the editor's own property:

| Property | Default |
| --- | --- |
| `--kotoba-floating-background` | `--kotoba-background` |
| `--kotoba-floating-text` | `--kotoba-text` |
| `--kotoba-floating-border` | `--kotoba-border` |
| `--kotoba-floating-hover` | `--kotoba-surface` |
| `--kotoba-floating-shadow` | `--kotoba-shadow` |
| `--kotoba-floating-radius` | `--kotoba-radius` |

For example, a dark menu over a light editor:

```css
.kotoba-selection-menu,
.kotoba-link-card {
  --kotoba-floating-background: #1f2023;
  --kotoba-floating-text: #f4f4f5;
  --kotoba-floating-border: #34353a;
  --kotoba-floating-hover: #34353a;
  --kotoba-floating-radius: 10px;
}

.kotoba-selection-menu .kotoba-toolbar-button[aria-pressed="true"] {
  background: #e8590c;
  color: white;
}
```

The menu shows with a short animation, which is off with
`prefers-reduced-motion`.

## The link card

When the caret is in a link, a card shows under it: the URL, which opens
in a new tab, and Edit link (the link form) and Remove link buttons. An
automatic link (a URL typed in the text) has only the URL. Alt+F10 moves
the focus to the card, and Escape closes it until the caret moves.
Cmd/Ctrl+click on a link in the editor opens it in a new tab. The card is
a `div.kotoba-link-card`, themed with the same properties as the
selection menu.

## More

* [Prompts and mentions](prompts.md): `@` menus, emoji, tags.
* [Suggestions](suggestions.md): text streamed from the server.
* [Uploads](uploads.md): files and images in the document.
* [Custom nodes](custom_nodes.md) and [Extensions](extensions.md): your
  own nodes, commands, buttons and shortcuts.
* [Rendering](rendering.md): the HTML, text and Markdown of a document.
