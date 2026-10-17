# Rendering

A `Kotoba.Content` holds the document and, cached, its HTML and its plain
text. This guide shows how to show the content in a page, how to render a
document as HTML, text or Markdown elsewhere (an email, a search index, a
feed), how to style the HTML, and how to make content without the editor.

## In a page

```heex
<.kotoba_content content={@post.body} class="prose" />
```

`Kotoba.Components.kotoba_content/1` renders the content in a
`div.kotoba-content`, with the `class` and the other attributes that you
give. `nil` renders an empty `div`.

It uses the cached HTML, which `Kotoba.Content` made when it cast the
content, so a page does not render the document again. It renders again
when you give a `policy` other than `:default`, when you give `nodes`, or
when the cache is from another version of Kotoba:

```heex
<%!-- A comment from a person that the app does not trust --%>
<.kotoba_content content={@comment.body} policy={:untrusted} />

<%!-- App nodes that are not in `config :kotoba, nodes:` --%>
<.kotoba_content content={@post.body} nodes={[MyApp.Nodes.Chart]} />
```

The HTML is always safe: Kotoba escapes every string and never passes raw
HTML through, and each node passes the checks of `Kotoba.Sanitizer`
before it renders. See the [Security](security.md) guide.

### The policies

* `:default`: links are anchors (with `rel="noopener nofollow"`), and
  attachments are figures with their image or a download link.
* `:untrusted`: links render as their text, with no anchor, and
  attachments as their file name, with no image and no link.

## The HTML

| Content | HTML |
| --- | --- |
| paragraph, heading, quote | `p`, `h1` to `h4`, `blockquote` |
| lists | `ul`, `ol` (with `start`), `li` |
| check list | `ul.kotoba-check`, with `li.kotoba-checked` and `li.kotoba-unchecked` |
| formats | `strong`, `em`, `u`, `s`, `mark`, `sub`, `sup`, `code` |
| text color, highlight color | `span.kotoba-color-<name>`, `mark.kotoba-highlight-<name>` |
| case formats | `span.kotoba-lowercase`, `span.kotoba-uppercase`, `span.kotoba-capitalize` |
| code block | `pre` with `code.language-<language>` |
| line break, rule | `br`, `hr` |
| table | `div.kotoba-table-scroll` with a `table.kotoba-table`: `thead` for a header row, `tbody`, `th scope="col"`/`scope="row"`, `colspan` and `rowspan` |
| link | `a` with `href` and `rel="noopener nofollow"` |
| attachment | `figure.kotoba-attachment` with an `img`, and a `figcaption`; a PDF (`figure.kotoba-attachment-pdf`) has an `object` (or a link to it with the `preview` image), a video (`figure.kotoba-attachment-video`) a `video` with controls; other files a download link |
| gallery | `div.kotoba-gallery` with the `figure` of each attachment (a grid in `kotoba.css`) |
| mention | `span.kotoba-mention` with `data-kind` and `data-id` |
| an app node | what its `render_html/2` gives (see [Custom nodes](custom_nodes.md)) |
| a node that fails a check, or of an unknown type | an empty `span.kotoba-unknown` with `data-type` |

`Kotoba.Renderer` has the full table.

## Style the HTML

`kotoba.css` gives the rendered HTML a readable baseline. It styles
headings, paragraphs, lists, quotes, links, inline code and code blocks,
as well as the structures that need their own layout:

* tables: borders, padding, header cells, and the sideways scroll;
* check lists: a box, checked or not, in front of each item;
* mentions and attachments;
* the text colors and highlights of the palette (see
  [Theming](theming.md));
* the case formats.

Each rule of the baseline has the weight of one class
(`.kotoba-content :where(a)`): it wins over element resets such as
`a { color: inherit }` or Tailwind's preflight, and a rule of your app
with a class (`.article .kotoba-content a`) wins over it. With Tailwind,
the typography plugin is an option; import `kotoba.css` in a layer so
that the plugin's utilities come after it:

```css
@import "../../deps/kotoba/priv/static/kotoba.css" layer(components);
```

```heex
<.kotoba_content content={@post.body} class="prose dark:prose-invert" />
```

A rendered code block has its language in the class (`language-elixir`).
The server returns plain code text; for syntax colors in a browser, import
`highlightRenderedContent` from `kotoba` and call it after the page loads
or LiveView replaces the rendered document. It uses the Prism grammars
already bundled with the editor and does not change the page's own
`window.Prism`:

```js
import { highlightRenderedContent } from "kotoba"
window.addEventListener("DOMContentLoaded", () => highlightRenderedContent())
window.addEventListener("phx:page-loading-stop", () => highlightRenderedContent())
```

## HTML, text and Markdown anywhere

`Kotoba.Content` has the HTML (`content.html`, a string) and the plain
text (`content.text`, the blocks one per line). Use the text for a search
index, a preview or a notification:

```elixir
String.slice(post.body.text, 0, 140)
```

`Kotoba.Renderer` renders a `Kotoba.Document` again, for another policy
or for Markdown:

```elixir
{:ok, doc} = Kotoba.Document.parse(post.body.doc)

doc |> Kotoba.Renderer.to_html(policy: :untrusted) |> Phoenix.HTML.safe_to_string()
Kotoba.Renderer.to_text(doc)
Kotoba.Renderer.to_markdown(doc)
```

`to_markdown/2` writes headings, lists and check lists, quotes, code
blocks, bold, italic, strikethrough, inline code, links, images, rules,
tables with their column alignment, and footnotes (GitHub Flavored
Markdown) as Markdown, and escapes the text, so that
`Kotoba.Content.from_markdown/2` reads it back to the same document. Other
formats (underline, highlights, colors, subscript, superscript) and
mentions give their text. An app node gives what its
`render_markdown/2` gives.

A blank line that a person typed (an empty paragraph between blocks)
keeps its height in HTML and is `&nbsp;` in Markdown. To leave blank lines
out, render with `blank_lines: :collapse`, or give the editor
`blank_lines={:collapse}`, which leaves them out of the saved document.

For an email, render the HTML with the `:untrusted` policy when the
content comes from people outside the app, and inline the styles that the
email needs: an email client does not load `kotoba.css`.

## Read a document

`Kotoba.Document.parse/2` gives the document's nodes, as structs
(`Kotoba.Nodes`):

```elixir
{:ok, doc} = Kotoba.Document.parse(post.body.doc)

Kotoba.Document.mentions(doc)     # every Kotoba.Nodes.Mention
Kotoba.Document.attachments(doc)  # every Kotoba.Nodes.Attachment
Kotoba.Document.empty?(doc)       # no text, no attachment, no other node
Kotoba.Features.used(doc)         # the features it uses
```

`Kotoba.Document.reduce/3` walks every node, for anything else.

## Content without the editor

* `Kotoba.Content.cast/1` takes the JSON that the editor posts, a
  document envelope, a bare Lexical root node, or a `Kotoba.Content`.
* `Kotoba.Content.from_markdown/2` makes content from Markdown:
  CommonMark and GitHub Flavored Markdown (tables, task lists,
  strikethrough, autolinks, footnotes), read by MDEx. Raw HTML is text. A
  list item holds inline content: an item with several paragraphs has
  line breaks, and a code block, a quote or a table in an item comes after
  the list. `features:` gives the features of a field: a construct whose
  feature is off becomes its closest form. It is handy for seeds, tests
  and imports, and the editor uses it for pasted Markdown.
* `Kotoba.Content.empty/0` is an empty document.

```elixir
Repo.insert!(%Post{title: "Hello", body: Kotoba.Content.from_markdown("# Hello\n\nFirst **post**.")})
```

## After a change of the registry

The cached HTML stays as it was rendered. After a change of your node
registry (`config :kotoba, nodes:`), of a node's `render_html/2`, or of
`config :kotoba, allowed_link_schemes:`, render the stored rows again with
`Kotoba.Content.rerender/2`. See the [Known limits](limits.md) guide.
