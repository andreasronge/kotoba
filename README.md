# Kotoba

![Kotoba — Rich text for Phoenix](https://raw.githubusercontent.com/hattoriai/kotoba/main/media/banner.png)

Kotoba (言葉, "words") is rich text for Phoenix. It gives your app:

* a rich-text editor for LiveView forms, built on
  [Lexical](https://lexical.dev): bold, italic, underline, strikethrough,
  highlight, subscript, superscript and inline code, headings, quotes,
  lists and check lists, links, code blocks highlighted in 28 languages,
  tables, file attachments, mentions, and your own nodes;
* `Kotoba.Content`, an Ecto type that stores the document with a cached
  HTML and text rendering;
* the features of each editor (`features={~w(bold links lists)}`) and
  extensions, the app's own nodes, commands, toolbar buttons and Markdown
  shortcuts;
* safe rendering to HTML, text and Markdown, with no raw HTML anywhere.

The editor is a prebuilt JavaScript bundle in the Hex package. Your app
does not run Node.js for it: you add the hook and one style sheet.

## Try it: Notebook

![The Kotoba editor in Notebook: a toolbar, a second writer's live cursor, the selection menu over selected text, and a highlighted code block](https://raw.githubusercontent.com/hattoriai/kotoba/main/media/notebook-editor.png)

[Notebook](https://github.com/hattoriai/notebook) is a complete Phoenix
app made with Kotoba: shared pages with live collaboration, a selection
menu with the app's own icons, mentions, galleries, PDFs, a custom
callout node, and a reader view of the rendered content. Clone it, run
`mix setup` and `mix phx.server`, and sign in as Hattori Hanzo (its
README has the details) to try every feature in your browser.

## What the editor does

| | |
| --- | --- |
| Text | bold, italic, underline, strikethrough, inline code, subscript, superscript; a palette of text colors and highlights |
| Blocks | headings, quotes, bulleted, numbered and check lists, horizontal rules |
| Code | code blocks highlighted as you type in 28 languages, with a language picker |
| Tables | insert, rows and columns, header rows and columns, pasted tables |
| Links | a link form, paste a URL over text, autolinks, allowed schemes; a link card to open, edit or remove the link at the caret |
| Selection menu | a menu over the selected text, with the toolbar's commands or the app's own buttons, themed with CSS properties |
| Files | drop, paste or pick images and files; image galleries, reordered from the keyboard; PDFs in the browser's viewer, MP4 and WebM videos; LiveView uploads, a storage adapter with byte ranges |
| Prompts | `@` mentions, emoji, tags: server searches (async too) or local lists, with queries that have spaces |
| Suggestions | text streamed from the server (a language model), shown as it comes, then accepted as one undo step or rejected; an Assist menu |
| Collaboration | shared documents, participant cursors, read-only viewers, per-author undo, offline draft recovery and accepted revisions for form submission; [setup](guides/collaboration.md) |
| Shortcuts | the usual keyboard shortcuts, and Markdown as you type (`## `, `- `, `**bold**`, ` ``` `) |
| Per field | the features of each editor (`features={~w(bold links lists)}`), checked on the server |
| Your own | nodes (`mix kotoba.gen.node`), extensions with commands, toolbar buttons and shortcuts, custom toolbars |
| Output | cached, safe HTML and plain text; Markdown; a strict policy for untrusted content |
| Theming | CSS custom properties, the Sumi theme, dark mode |
| Accessibility | a labelled textbox, a toolbar with one tab stop, a live region, no keyboard trap |

The [Editing features](guides/features.md) guide is the tour, and the
development server of this repository (`mix dev`, below) shows each of
them.

## Install

Kotoba needs Elixir 1.18 or later (it uses the built-in `JSON` module),
Phoenix 1.7 or 1.8 and Phoenix LiveView 1.1 or later. CI runs the tests
on the current versions, and in a separate `floor` job on the oldest:
Elixir 1.18 (OTP 27), Phoenix 1.7 and LiveView 1.1.

Add `kotoba` to the deps in `mix.exs`:

```elixir
def deps do
  [
    {:kotoba, "~> 0.2"}
  ]
end
```

Then run:

```sh
mix deps.get
mix kotoba.install
```

The installer adds the hook to `assets/js/app.js`, the style sheet to
`assets/css/app.css` and the storage adapter to `config/config.exs`, and
prints what it changed. Give `--dry-run` to see the changes first. It does
not add what a file already has, so you can run it again.

### The manual steps

To make the same changes by hand, import the hook in `assets/js/app.js`
and add it to the hooks of the `LiveSocket`:

```js
import { Kotoba } from "kotoba"

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, Kotoba},
})
```

Import the style sheet in `assets/css/app.css` (and the Sumi theme, if you
want it: Sumi is the design system of Hattori AI, the makers of Kotoba). Put these lines below the other `@import` lines of `app.css`
(the installer puts them there):

```css
@import "../../deps/kotoba/priv/static/kotoba.css";
/* @import "../../deps/kotoba/priv/static/kotoba-sumi.css"; */
```

Name the storage adapter for uploads in `config/config.exs`:

```elixir
config :kotoba, storage: Kotoba.Storage.Local
```

### `NODE_PATH=deps`

`import { Kotoba } from "kotoba"` resolves through the `NODE_PATH` of your
esbuild profile, which must have `deps/`. The Phoenix generators already
set it. If your profile has no `NODE_PATH`, add it in `config/config.exs`:

```elixir
env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
```

## Use

```elixir
schema "posts" do
  field :body, Kotoba.Content
end
```

```heex
<.form for={@form} phx-change="validate" phx-submit="save">
  <label id="post-body-label">Body</label>
  <.kotoba field={@form[:body]} id="post-body" label_id="post-body-label" />
</.form>

<.kotoba_content content={@post.body} />
```

Import the components in the `html_helpers` of your web module:

```elixir
import Kotoba.Components
```

The editor posts the document with the form, as a JSON string that
`Kotoba.Content` casts, so the form's own `phx-change` and `phx-submit`
events have it. `<.kotoba_content>` shows the stored content as safe
HTML.

## Guides

* [Quickstart](guides/quickstart.md): install, the schema, the form and
  the rendered content.
* [Forms and changesets](guides/forms.md): what the form posts, the
  changeset, the LiveView events and the server pushes.
* [Editing features](guides/features.md): the features of an editor, their
  shortcuts, colors, links, code blocks, tables and the toolbar.
* [Rendering](guides/rendering.md): the stored content in a page, HTML,
  text and Markdown, and content without the editor.
* [Uploads](guides/uploads.md): LiveView uploads, the storage adapters and
  how to serve the files.
* [Prompts and mentions](guides/prompts.md): `@` menus, emoji and tags,
  from the LiveView or from a local list.
* [Suggestions](guides/suggestions.md): text streamed from the server,
  the Assist menu, and a language model example.
* [Custom nodes](guides/custom_nodes.md): your own nodes, with
  `mix kotoba.gen.node`.
* [Extensions](guides/extensions.md): your own commands, toolbar buttons
  and Markdown shortcuts.
* [Theming](guides/theming.md): the `--kotoba-*` properties and the Sumi
  theme.
* [Security](guides/security.md): what Kotoba checks, and what your app
  must do.
* [Accessibility](guides/accessibility.md): the roles and the keyboard.
* [Known limits](guides/limits.md).

## Development

The editor source is TypeScript in `assets/`. The built files in
`priv/static` are not in the repository; the Hex package has them.

```sh
mix deps.get
mix kotoba.build    # npm ci in assets/ when necessary, then esbuild
mix dev             # the development server on http://localhost:4099
```

`mix kotoba.build` runs in the `:dev` environment and needs `npm`. It
empties `priv/static` and writes the four files of the package:
`kotoba.esm.js`, `kotoba.cjs.js`, `kotoba.css` and `kotoba-sumi.css`.

`mix dev` runs `dev.exs`: a Phoenix endpoint with the editor in a form,
the prompts (`@` people, `:` emoji, `+` tags, `~` a slow search, `!` a
failing one), uploads to `tmp/uploads`, an app node made with
`mix kotoba.gen.node` (in `dev/`), buttons that send each server event,
editors with fewer features and an example extension at `/extensions`,
and the Sumi theme at `/?theme=sumi`. Set `PORT` for another port. esbuild
watchers rebuild the bundle and the node modules, and the page reloads.
Restart `mix dev` after a change in `dev/lib`.

### Tests

```sh
mix test                   # the ExUnit suite
mix test --include build   # also mix kotoba.build and mix hex.build
mix test.e2e               # the Playwright browser tests
mix precommit              # compile, format, credo --strict and test
mix dialyzer
```

The browser tests in `e2e/` use Playwright, in Chromium, Firefox and
WebKit (the engine of Safari). Install the browsers once:

```sh
cd e2e && npm ci && npx playwright install chromium firefox webkit
```

`mix test.e2e` runs every spec in the three browsers, and `E2E_BROWSERS`
picks some of them. In `e2e/`, Playwright runs one spec (it starts the
development server too):

```sh
E2E_BROWSERS=firefox mix test.e2e
cd e2e && E2E_BROWSERS=chromium,webkit npx playwright test specs/prompts.spec.ts
```

A failed test keeps its trace and a screenshot in `e2e/test-results/`;
open a trace with `npx playwright show-trace <trace.zip>` in `e2e/`. CI
runs one job for each browser, and uploads the results of a failed job as
an artifact.

`mix test.e2e` runs `npm ci` in `e2e/` when `e2e/node_modules` is missing,
builds the bundle, and starts its own development server, without
watchers, on port 4098 (set `E2E_PORT` for another port). A `mix dev` on
port 4099 can keep running.

### Release

`mix release` (in this repository, an alias that replaces Mix's `release`
task) builds the bundle, checks that `priv/static` holds only the
four bundle files (`mix kotoba.release_check`), publishes to Hex, and tags
and pushes `v<version>`.

## License

Kotoba is released under the MIT License. See `LICENSE`.

The built editor includes third-party code under the MIT licence:
[Lexical](https://lexical.dev) (Meta Platforms, Inc. and affiliates),
[PrismJS](https://prismjs.com) (Lea Verou) and
[`@preact/signals-core`](https://github.com/preactjs/signals) (the Preact
team). The toolbar icons are from [Lucide](https://lucide.dev) (ISC
licence); some of them come from Feather (MIT licence). See `NOTICE` for
the full notices.
