# The Kotoba development server: `mix dev`, then http://localhost:4099.
#
# One Phoenix endpoint with the editor on a few LiveViews, the built bundle
# from priv/static, the local storage adapter under tmp/uploads, and an app
# node (`KotobaDev.Nodes.Tag`, made with `mix kotoba.gen.node`). The browser
# tests in e2e/ run against it.
#
# The node modules of dev/assets are built into tmp/dev/nodes and served at
# /assets/nodes; they never go to priv/static, which holds only the files of
# the package.
#
# The bundle and the node modules rebuild and the page reloads on a change.
# `dev/lib` is loaded once when the server starts: restart `mix dev` after a
# change there.
#
# Environment:
#
#   * PORT - the HTTP port (4099).
#   * KOTOBA_DEV_WATCH - "false" starts no esbuild watchers and no live
#     reload, for the browser tests; the bundle must be built first.

Code.require_file("dev/lib/kotoba_dev/nodes/tag.ex", __DIR__)
Code.require_file("dev/lib/kotoba_dev/nodes/callout.ex", __DIR__)

port = "PORT" |> System.get_env("4099") |> String.to_integer()
watch? = System.get_env("KOTOBA_DEV_WATCH") != "false"
uploads = Path.expand("tmp/uploads", __DIR__)

Application.put_env(:phoenix, :json_library, JSON)
Logger.configure(level: :info)
Application.put_env(:kotoba, :nodes, [KotobaDev.Nodes.Tag, KotobaDev.Nodes.Callout])
Application.put_env(:kotoba, :allowed_link_schemes, ~w(http https mailto tel))
Application.put_env(:kotoba, :storage, Kotoba.Storage.Local)
Application.put_env(:kotoba, Kotoba.Storage.Local, root: uploads, url_prefix: "/uploads/kotoba")

Application.put_env(:kotoba, KotobaDev.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  check_origin: false,
  code_reloader: watch?,
  debug_errors: true,
  http: [ip: {127, 0, 0, 1}, port: port],
  live_view: [signing_salt: "kotoba-dev-live-view-salt"],
  pubsub_server: KotobaDev.PubSub,
  render_errors: [formats: [html: KotobaDev.ErrorHTML], layout: false],
  secret_key_base: String.duplicate("kotoba-development-secret-", 3),
  server: true,
  url: [host: "localhost"],
  watchers:
    if(watch?,
      do: [
        kotoba_esm: {Esbuild, :install_and_run, [:kotoba_esm, ~w(--watch)]},
        kotoba_dev_nodes: {Esbuild, :install_and_run, [:kotoba_dev_nodes, ~w(--watch)]}
      ],
      else: []
    ),
  live_reload: [
    patterns: [
      ~r"priv/static/.*\.(js|css)$",
      ~r"tmp/dev/nodes/.*\.js$",
      ~r"lib/kotoba/.*\.ex$"
    ]
  ]
)

defmodule KotobaDev.People do
  @moduledoc "A fixed list of people for the `@` prompt."

  @people [
    %{id: 1, label: "Ada Lovelace", hint: "Analyst"},
    %{id: 2, label: "Alan Turing", hint: "Mathematician"},
    %{id: 3, label: "Grace Hopper", hint: "Admiral"},
    %{id: 4, label: "Katherine Johnson", hint: "Mathematician"},
    %{id: 5, label: "Margaret Hamilton", hint: "Engineer"},
    %{id: 6, label: "Barbara Liskov", hint: "Computer scientist"}
  ]

  def search(query) do
    query = String.downcase(query)
    Enum.filter(@people, &String.contains?(String.downcase(&1.label), query))
  end

  @doc "The `!` prompt: a search that always fails, as a database that is down."
  def broken(_query), do: raise("the search is down")

  @doc "The `~` prompt: a search that takes a second, in a task (`async: true`)."
  def slow(query) do
    Process.sleep(1_000)
    search(query)
  end
end

defmodule KotobaDev.Assist do
  @moduledoc """
  A fake language model for the Assist menu of the editor page: it answers
  each action with a fixed text, in chunks of four characters, one every
  40 ms, with no API key. The Markdown of an answer is cut anywhere, `**`
  included. "Fail" streams a little, then cancels.
  """

  @actions [
    rewrite: "Rewrite",
    summarize: "Summarize",
    continue: "Continue writing",
    fail: "Fail"
  ]

  def actions, do: @actions

  @doc "The answer, and the stream options, of an action."
  def answer("rewrite", text),
    do: {"A **clearer** version: #{text}", at: :selection, label: "Rewrite"}

  def answer("summarize", text),
    do:
      {"**Summary:** #{text |> String.split() |> Enum.take(3) |> Enum.join(" ")}…",
       at: :after, label: "Summary"}

  def answer("continue", _text),
    do:
      {"## What comes next\n\n- One more point\n- And a _last_ one",
       at: :after, label: "Continue writing"}

  def answer("fail", _text), do: {"This answer will not", at: :selection, label: "Fail"}

  @doc "Starts the stream of an answer, for the editor `id`; `opts` replace the answer's stream options."
  def start(socket, id, ref, action, text, opts \\ []) do
    {answer, answer_opts} = answer(action, text)
    Process.send_after(self(), {:assist_chunk, id, ref, action, answer}, 40)

    socket
    |> Kotoba.Live.stream_start(id, ref, Keyword.merge(answer_opts, opts))
    |> Phoenix.Component.update(:assist_refs, &MapSet.put(&1, ref))
  end

  @doc "Sends the next chunk, or ends the stream (a \"fail\" stream is cancelled after two chunks)."
  def next(socket, id, ref, action, rest) do
    cond do
      ref not in socket.assigns.assist_refs ->
        socket

      rest == "" ->
        socket |> Kotoba.Live.stream_end(id, ref) |> stop(ref)

      action == "fail" and String.length(rest) < 12 ->
        socket |> Kotoba.Live.stream_cancel(id, ref) |> stop(ref)

      true ->
        {chunk, rest} = String.split_at(rest, 4)
        Process.send_after(self(), {:assist_chunk, id, ref, action, rest}, 40)
        Kotoba.Live.stream_chunk(socket, id, ref, chunk)
    end
  end

  @doc "Stops a stream: its next chunks are dropped."
  def stop(socket, ref),
    do: Phoenix.Component.update(socket, :assist_refs, &MapSet.delete(&1, ref))
end

defmodule KotobaDev.Prompts do
  @moduledoc """
  The prompts of the editor page:

    * `@` people, whose query can have spaces ("Ada Lovelace");
    * `!` a search that always fails;
    * `:` emoji, a local list that inserts text;
    * `+` tags, an async search that inserts a Tag node;
    * `~` people again, from a search of a second, in a task.
  """

  @emoji [
    %{id: "tada", label: "tada", hint: "🎉", text: "🎉"},
    %{id: "heart", label: "heart", hint: "❤️", text: "❤️"},
    %{id: "thumbsup", label: "thumbs up", hint: "👍", text: "👍"},
    %{id: "rocket", label: "rocket", hint: "🚀", text: "🚀"},
    %{id: "eyes", label: "eyes", hint: "👀", text: "👀"}
  ]

  @tags ~w(urgent bug design later)

  def list do
    [
      {"@", :people, [search: &KotobaDev.People.search/1, spaces: true]},
      {"!", :broken, &KotobaDev.People.broken/1},
      {":", :emoji, [items: @emoji, insert: :text, label: "Emoji"]},
      {"+", :tags, [search: &tags/1, insert: {:node, "dev-tag"}, async: true, label: "Tags"]},
      {"~", :slow, [search: &KotobaDev.People.slow/1, async: true, min_length: 1]}
    ]
  end

  defp tags(query) do
    for tag <- @tags, String.starts_with?(tag, String.downcase(query)) do
      %{id: tag, label: tag, attrs: %{label: tag}}
    end
  end
end

defmodule KotobaDev.Sample do
  @moduledoc "The sample document of the Load sample buttons."

  # With `code: true`, a code block in "ex", an alias: the editor shows
  # Elixir and keeps "ex". Only the second editor's sample has it: the editor
  # highlights a loaded code block in an update of its own, which the main
  # editor's "not pushed back" test would count.
  def document(title \\ "Sample", opts \\ []) do
    %{
      "kotoba" => 1,
      "lexical" => "0.51",
      "root" =>
        root([
          element("heading", [text(title)], %{"tag" => "h2"}),
          paragraph([
            text("Loaded from the "),
            text("server", 1),
            text(" with a "),
            %{"type" => "dev-tag", "version" => 1, "label" => "sample"},
            text(" tag and "),
            %{
              "type" => "mention",
              "version" => 1,
              "kind" => "people",
              "id" => "1",
              "label" => "Ada Lovelace"
            },
            text(".")
          ]),
          element(
            "list",
            [element("listitem", [text("One")], %{"value" => 1, "checked" => nil})],
            %{"listType" => "bullet", "start" => 1, "tag" => "ul"}
          ),
          if(opts[:code],
            do: element("code", [text("defmodule Sample do end")], %{"language" => "ex"})
          ),
          element(
            "table",
            [
              element("tablerow", [cell("Language", 1), cell("Year", 1)], %{}),
              element("tablerow", [cell("Elixir", 0), cell("2012", 0)], %{})
            ],
            %{}
          )
        ])
    }
  end

  defp root(children),
    do: %{
      "type" => "root",
      "version" => 1,
      "direction" => nil,
      "format" => "",
      "indent" => 0,
      "children" => Enum.reject(children, &is_nil/1)
    }

  defp paragraph(children),
    do: element("paragraph", children, %{"textFormat" => 0, "textStyle" => ""})

  # A table cell: headerState 1 in the header row, 0 elsewhere.
  defp cell(value, header_state),
    do:
      element("tablecell", [paragraph([text(value)])], %{
        "headerState" => header_state,
        "colSpan" => 1,
        "rowSpan" => 1,
        "backgroundColor" => nil
      })

  defp element(type, children, extra) do
    Map.merge(
      %{
        "type" => type,
        "version" => 1,
        "direction" => nil,
        "format" => "",
        "indent" => 0,
        "children" => children
      },
      extra
    )
  end

  defp text(text, format \\ 0),
    do: %{
      "type" => "text",
      "version" => 1,
      "detail" => 0,
      "format" => format,
      "mode" => "normal",
      "style" => "",
      "text" => text
    }
end

defmodule KotobaDev.Layouts do
  @moduledoc """
  The root layout: the style sheets, the import map and the LiveSocket.
  `?theme=sumi` also loads kotoba-sumi.css.
  """
  use Phoenix.Component

  def root(assigns) do
    assigns = assign(assigns, :sumi, assigns.conn.params["theme"] == "sumi")

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Kotoba development</title>
        <link rel="stylesheet" href="/assets/kotoba.css" />
        <link :if={@sumi} rel="stylesheet" href="/assets/kotoba-sumi.css" />
        <style>
          body { font-family: system-ui, sans-serif; margin: 0; background: #fafaf9; color: #1c1917; }
          body.sumi { background: var(--kotoba-background); color: var(--kotoba-text); }
          main { max-width: 48rem; margin: 0 auto; padding: 2rem 1rem; }
          nav a { margin-right: 1rem; }
          .label { display: block; font-weight: 600; margin: 1rem 0 0.5rem; }
          .row { display: flex; flex-wrap: wrap; gap: 0.5rem; margin: 1rem 0; }
          dl { display: grid; grid-template-columns: max-content 1fr; gap: 0.25rem 1rem; }
          pre { white-space: pre-wrap; word-break: break-all; font-size: 0.75rem; }
          .stored { border-top: 1px solid #d6d3d1; margin-top: 2rem; }
        </style>
        <script type="importmap">
          {
            "imports": {
              "phoenix": "/vendor/phoenix/phoenix.mjs",
              "phoenix_live_view": "/vendor/phoenix_live_view/phoenix_live_view.esm.js",
              "kotoba": "/assets/kotoba.esm.js",
              "kotoba/collab": "/assets/kotoba-collab.esm.js"
            }
          }
        </script>
        <script type="module">
          import { Socket } from "phoenix"
          import { LiveSocket } from "phoenix_live_view"
          import { Kotoba, registerCollaboration } from "kotoba"
          import { enableCollaboration } from "kotoba/collab"
          enableCollaboration(registerCollaboration)

          const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
          const liveSocket = new LiveSocket("/live", Socket, {
            hooks: { Kotoba },
            params: { _csrf_token: csrfToken }
          })
          liveSocket.connect()
          window.liveSocket = liveSocket
        </script>
      </head>
      <body class={@sumi && "sumi"}>
        <main>
          <nav>
            <a href="/">Editor</a><a href="/two">Two editors</a><a href="/nodes">Nodes</a><a href="/collab">Collaboration</a><a href="/?theme=sumi">Sumi theme</a>
          </nav>
          {@inner_content}
        </main>
      </body>
    </html>
    """
  end
end

defmodule KotobaDev.EditorLive do
  @moduledoc """
  The editor in a form, with the prompts of `KotobaDev.Prompts`, uploads
  and the Tag node. The `!` prompt always fails, so the menu says "Results
  did not load". The
  buttons under the form send each server event. After Submit, the stored
  content renders below.

  Query params: `sample` starts with the sample document; `change` starts
  with "Push changes" on (the editor's `change` attribute, so it pushes
  `kotoba:change`); `uploads=reverse`
  stores the finished uploads in reverse order, so that the attachments
  reach the editor in the opposite order of their markers.

  "Hold uploads" keeps the finished uploads pending (not stored) until
  Release. "Reject next upload" makes the next upload that Release stores
  fail, so the server removes its marker.
  """
  use Phoenix.LiveView

  import Kotoba.Components

  alias Kotoba.{Attachments, Storage}

  @editor "post_body_editor"

  defp prompts, do: KotobaDev.Prompts.list()

  @impl true
  def mount(params, _session, socket) do
    body = if params["sample"], do: KotobaDev.Sample.document("Initial")

    {:ok,
     socket
     |> assign(
       form: to_form(%{"body" => body}, as: :post),
       stored: nil,
       readonly: false,
       invalid: false,
       changes: 0,
       push_changes: params["change"] != nil,
       menu: params["menu"],
       blank_lines: if(params["blank_lines"] == "collapse", do: :collapse, else: :keep),
       validated: 0,
       validated_text: "",
       reverse: params["uploads"] == "reverse",
       hold: false,
       reject_next: false,
       assist_refs: MapSet.new(),
       suggestions: []
     )
     |> allow_upload(:body,
       accept: ~w(.png .jpg .jpeg .gif .webp .pdf .mp4 .webm),
       max_entries: 4,
       max_file_size: 5_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Kotoba</h1>
    <.form for={@form} id="post-form" phx-change="validate" phx-submit="save">
      <label id="body-label" class="label">Body</label>
      <.kotoba
        field={@form[:body]}
        label_id="body-label"
        placeholder="Write something…"
        prompts={prompts()}
        uploads={@uploads.body}
        readonly={@readonly}
        change={@push_changes}
        aria-invalid={@invalid}
        aria-describedby={if @invalid, do: "body-error"}
        nodes={[{KotobaDev.Nodes.Tag, "/assets/nodes/tag.js"}]}
        assist={KotobaDev.Assist.actions()}
        selection_menu={@menu == "default"}
        blank_lines={@blank_lines}
      >
        <:selection :if={@menu == "custom"}>
          <.kotoba_selection_menu id="custom-menu" class="custom-menu" label="Quick format">
            <:button command="bold">B</:button>
            <:button command="h2" label="Heading">H</:button>
          </.kotoba_selection_menu>
        </:selection>
      </.kotoba>
      <p :if={@invalid} id="body-error">Say something</p>
      <div class="row">
        <button type="submit" id="submit">Submit</button>
      </div>
    </.form>

    <div class="row" role="group" aria-label="Server events">
      <button type="button" id="load-sample" phx-click="load_sample">Load sample</button>
      <button :if={@stored} type="button" id="load-stored" phx-click="load_stored">
        Load stored
      </button>
      <button
        type="button"
        id="toggle-readonly"
        phx-click="toggle_readonly"
        aria-pressed={to_string(@readonly)}
      >
        Readonly
      </button>
      <button
        type="button"
        id="toggle-invalid"
        phx-click="toggle_invalid"
        aria-pressed={to_string(@invalid)}
      >
        Invalid
      </button>
      <button type="button" id="push-lock" phx-click="set_readonly" phx-value-readonly="true">
        Lock (push)
      </button>
      <button type="button" id="push-unlock" phx-click="set_readonly" phx-value-readonly="false">
        Unlock (push)
      </button>
      <button type="button" id="push-focus" phx-click="focus">Focus editor</button>
      <button type="button" id="insert-tag" phx-click="insert_tag">Insert tag</button>
      <button type="button" id="stream-summary" phx-click="stream_summary">Stream a summary</button>
    </div>
    <p id="suggestion-events">{Enum.join(@suggestions, " ")}</p>

    <div class="row" role="group" aria-label="Changes">
      <label>
        <input
          type="checkbox"
          id="push-changes"
          phx-click="toggle_changes"
          checked={@push_changes}
        /> Push changes
      </label>
    </div>

    <div class="row" role="group" aria-label="Uploads">
      <label>
        <input type="checkbox" id="hold-uploads" phx-click="toggle_hold" checked={@hold} />
        Hold uploads
      </label>
      <label>
        <input type="checkbox" id="reject-next" phx-click="toggle_reject" checked={@reject_next} />
        Reject next upload
      </label>
      <button type="button" id="release-uploads" phx-click="release">Release</button>
    </div>

    <p :if={message = Phoenix.Flash.get(@flash, :error)} id="flash-error" role="alert">
      {message}
    </p>

    <dl>
      <dt>Pushed changes (kotoba:change)</dt>
      <dd id="change-count">{@changes}</dd>
      <dt>Form changes</dt>
      <dd id="validate-count">{@validated}</dd>
      <dt>Finished uploads, not stored</dt>
      <dd id="held-count">{Enum.count(@uploads.body.entries, & &1.done?)}</dd>
      <dt>Text in the last form change</dt>
      <dd id="validated-text">{@validated_text}</dd>
    </dl>

    <section :if={@stored} id="stored" class="stored">
      <h2>Stored</h2>
      <.kotoba_content content={@stored} id="stored-content" />
      <h3>Text</h3>
      <pre id="stored-text">{@stored.text}</pre>
      <h3>Document</h3>
      <pre id="stored-json">{JSON.encode!(@stored.doc)}</pre>
    </section>
    """
  end

  @impl true
  def handle_event("validate", params, socket) do
    socket =
      socket
      |> update(:validated, &(&1 + 1))
      |> assign(validated_text: posted_text(params))

    {:noreply,
     if(socket.assigns.reverse or socket.assigns.hold, do: socket, else: consume(socket))}
  end

  def handle_event("save", %{"post" => %{"body" => body}}, socket) do
    case Kotoba.Content.cast(body) do
      {:ok, content} -> {:noreply, socket |> clear_flash() |> assign(stored: content)}
      :error -> {:noreply, put_flash(socket, :error, "The document is not valid")}
    end
  end

  def handle_event("kotoba:change", %{"id" => @editor}, socket),
    do: {:noreply, update(socket, :changes, &(&1 + 1))}

  def handle_event("kotoba:prompt", params, socket),
    do: {:noreply, Kotoba.Live.handle_prompt(socket, params, prompts())}

  def handle_event("toggle_changes", _params, socket),
    do: {:noreply, update(socket, :push_changes, &(not &1))}

  def handle_event("load_sample", _params, socket),
    do: {:noreply, Kotoba.Live.push_content(socket, @editor, KotobaDev.Sample.document())}

  # The stored document back in the editor, as a page that edits a saved
  # record loads it.
  def handle_event("load_stored", _params, socket),
    do: {:noreply, Kotoba.Live.push_content(socket, @editor, socket.assigns.stored)}

  def handle_event("toggle_readonly", _params, socket),
    do: {:noreply, update(socket, :readonly, &(not &1))}

  def handle_event("toggle_invalid", _params, socket),
    do: {:noreply, update(socket, :invalid, &(not &1))}

  def handle_event("set_readonly", %{"readonly" => value}, socket),
    do: {:noreply, Kotoba.Live.set_readonly(socket, @editor, value == "true")}

  def handle_event("focus", _params, socket),
    do: {:noreply, Kotoba.Live.focus(socket, @editor)}

  def handle_event("toggle_hold", _params, socket),
    do: {:noreply, update(socket, :hold, &(not &1))}

  def handle_event("toggle_reject", _params, socket),
    do: {:noreply, update(socket, :reject_next, &(not &1))}

  def handle_event("release", _params, socket),
    do: {:noreply, socket |> assign(hold: false) |> release()}

  def handle_event("insert_tag", _params, socket),
    do:
      {:noreply, Kotoba.Live.insert_node(socket, @editor, %KotobaDev.Nodes.Tag{label: "urgent"})}

  # A suggestion that the person asked for with the Assist menu.
  def handle_event("kotoba:assist", %{"ref" => ref, "action" => action, "text" => text}, socket),
    do: {:noreply, KotobaDev.Assist.start(socket, @editor, ref, action, text)}

  # A suggestion that the server starts by itself, at the end.
  def handle_event("stream_summary", _params, socket) do
    ref = Kotoba.Live.stream_ref()

    socket =
      KotobaDev.Assist.start(socket, @editor, ref, "continue", "", at: :end, label: "Summary")

    {:noreply, socket}
  end

  # The person accepted, rejected or stopped a suggestion: a stopped one
  # sends no more chunks.
  def handle_event("kotoba:suggestion", %{"ref" => ref, "action" => action}, socket) do
    socket = update(socket, :suggestions, &(&1 ++ [action]))
    {:noreply, if(action == "accept", do: socket, else: KotobaDev.Assist.stop(socket, ref))}
  end

  # The phx-change carries the document too (the hook's formdata listener).
  defp posted_text(%{"post" => %{"body" => body}}) do
    case Kotoba.Content.cast(body) do
      {:ok, content} -> content.text
      :error -> ""
    end
  end

  defp posted_text(_params), do: ""

  @impl true
  def handle_async({:kotoba_prompt, _id, _prompt, _query} = name, result, socket),
    do: {:noreply, Kotoba.Live.handle_prompt_async(socket, name, result)}

  @impl true
  def handle_info({:assist_chunk, id, ref, action, rest}, socket),
    do: {:noreply, KotobaDev.Assist.next(socket, id, ref, action, rest)}

  defp handle_progress(:body, %{done?: true}, socket) do
    cond do
      socket.assigns.hold -> {:noreply, socket}
      socket.assigns.reverse -> {:noreply, consume_reversed(socket)}
      true -> {:noreply, consume(socket)}
    end
  end

  defp handle_progress(:body, _entry, socket), do: {:noreply, socket}

  defp consume(socket), do: Kotoba.Live.consume_uploads(socket, :body, @editor)

  # Stores the held uploads in the order of their entries. With "Reject next
  # upload", the key function gives no key for the first of them, so it is
  # not stored and its marker is removed (`Kotoba.Live.consume_uploads/4`).
  defp release(socket) do
    reject =
      with true <- socket.assigns.reject_next,
           %{ref: ref} <- Enum.find(socket.assigns.uploads.body.entries, & &1.done?),
           do: ref

    key = fn entry, type -> if entry.ref != reject, do: Storage.key(entry.client_name, type) end

    socket
    |> assign(reject_next: socket.assigns.reject_next and reject == nil)
    |> Kotoba.Live.consume_uploads(:body, @editor, key: key)
  end

  # Waits for every entry, then stores them last first. Each attachment
  # carries its entry's ref, so it still takes the place of its own marker.
  defp consume_reversed(socket) do
    entries = socket.assigns.uploads.body.entries

    if entries != [] and Enum.all?(entries, & &1.done?) do
      entries
      |> Enum.reverse()
      |> Enum.reduce(socket, fn entry, socket ->
        node = consume_uploaded_entry(socket, entry, &{:ok, store(&1.path, entry)})
        Kotoba.Live.insert_node(socket, @editor, node, ref: entry.ref)
      end)
    else
      socket
    end
  end

  defp store(path, entry) do
    name = Attachments.clean_name(entry.client_name)
    {:ok, description} = Attachments.describe(path, entry.client_type)
    key = Storage.key(name, description.content_type)
    meta = %{name: name, content_type: description.content_type, bytes: description.bytes}
    {:ok, url} = Storage.Local.put(key, path, meta)
    Attachments.node(description, key: key, url: url, name: name)
  end
end

defmodule KotobaDev.PanelComponent do
  @moduledoc """
  A LiveComponent with its own editor. The editor has
  `phx-target={@myself}`, so its events come here and not to the LiveView.
  """
  use Phoenix.LiveComponent

  import Kotoba.Components

  @editor "b_editor"

  # A label names the prompt's menu: "People in the workshop", not
  # "people suggestions".
  @prompts [people: {&KotobaDev.People.search/1, label: "People in the workshop"}]

  defp prompts, do: @prompts

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, form: to_form(%{"body" => nil}, as: :b), changes: 0)}

  @impl true
  def render(assigns) do
    ~H"""
    <section id="panel">
      <.form for={@form} id="b-form" phx-target={@myself} phx-change="validate">
        <label id="b-label" class="label">Second editor (in a LiveComponent)</label>
        <.kotoba
          field={@form[:body]}
          id="b_editor"
          label_id="b-label"
          prompts={prompts()}
          code_languages={~w(elixir erlang sql)}
          change
          phx-target={@myself}
        />
      </.form>
      <div class="row">
        <button type="button" id="load-b" phx-click="load" phx-target={@myself}>
          Load the second editor
        </button>
      </div>
      <dl>
        <dt>Changes in the component</dt>
        <dd id="panel-changes">{@changes}</dd>
      </dl>
    </section>
    """
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("kotoba:change", %{"id" => @editor}, socket),
    do: {:noreply, update(socket, :changes, &(&1 + 1))}

  def handle_event("kotoba:prompt", params, socket),
    do: {:noreply, Kotoba.Live.handle_prompt(socket, params, @prompts)}

  def handle_event("load", _params, socket),
    do:
      {:noreply,
       Kotoba.Live.push_content(socket, @editor, KotobaDev.Sample.document("Second", code: true))}
end

defmodule KotobaDev.TwoEditorsLive do
  @moduledoc """
  Two editors on one page: one in the LiveView, one in a LiveComponent.
  Every push names its editor, so the other editor ignores it.
  """
  use Phoenix.LiveView

  import Kotoba.Components

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, form: to_form(%{"body" => nil}, as: :a), change_ids: [])}

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Two editors</h1>
    <.form for={@form} id="a-form" phx-change="validate">
      <label id="a-label" class="label">First editor</label>
      <.kotoba field={@form[:body]} id="a_editor" label_id="a-label" change />
    </.form>
    <div class="row">
      <button type="button" id="load-a" phx-click="load">Load the first editor</button>
    </div>
    <dl>
      <dt>Changes in the LiveView</dt>
      <dd id="parent-changes">{Enum.join(Enum.uniq(@change_ids), ",")}</dd>
    </dl>
    <.live_component module={KotobaDev.PanelComponent} id="panel" />
    """
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("kotoba:change", %{"id" => id}, socket),
    do: {:noreply, update(socket, :change_ids, &(&1 ++ [id]))}

  def handle_event("load", _params, socket),
    do:
      {:noreply, Kotoba.Live.push_content(socket, "a_editor", KotobaDev.Sample.document("First"))}
end

defmodule KotobaDev.NodesLive do
  @moduledoc """
  An editor with app node modules that the editor must refuse:
  `?case=missing` names a module that does not exist, `?case=builtin` a
  module whose node has the type of a built-in node.
  """
  use Phoenix.LiveView

  import Kotoba.Components

  @modules %{
    "missing" => "/assets/nodes/missing.js",
    "builtin" => "/assets/nodes/mention_clash.js"
  }

  @impl true
  def mount(params, _session, socket) do
    url = Map.get(@modules, params["case"], "/assets/nodes/tag.js")
    {:ok, assign(socket, form: to_form(%{"body" => nil}, as: :nodes), url: url)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Node modules</h1>
    <p>Module: <code id="module-url">{@url}</code></p>
    <.form for={@form} id="nodes-form">
      <label id="nodes-label" class="label">Body</label>
      <.kotoba field={@form[:body]} label_id="nodes-label" nodes={[@url]} />
    </.form>
    """
  end
end

defmodule KotobaDev.ExtensionsLive do
  @moduledoc """
  Features and extensions. The comment editor has four features and the
  example extension (a callout); its changeset refuses a document with
  another feature. The notes editor has every feature and no extension.
  The formats editor has the text formats, in a toolbar of the app that
  has subscript and superscript.
  `?case=broken` adds an extension whose register throws and one that does
  not load: the editor still mounts, with the callout.
  """
  use Phoenix.LiveView

  import Kotoba.Components

  @features ~w(bold italic links lists)
  @callout "/assets/nodes/callout.js"
  @broken ["/assets/nodes/broken_extension.js", "/assets/nodes/missing_extension.js"]

  @impl true
  def mount(params, _session, socket) do
    extensions = if params["case"] == "broken", do: @broken ++ [@callout], else: [@callout]

    {:ok,
     assign(socket,
       form: to_form(%{"body" => nil}, as: :comment),
       notes: to_form(%{"body" => nil}, as: :notes),
       formats: to_form(%{"body" => nil}, as: :formats),
       extensions: extensions,
       shown: true,
       error: nil,
       saved: nil
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Features and extensions</h1>
    <.form :if={@shown} for={@form} id="comment-form" phx-change="validate" phx-submit="save">
      <label id="comment-label" class="label">Comment</label>
      <.kotoba
        field={@form[:body]}
        id="comment_editor"
        label_id="comment-label"
        features={features()}
        extensions={@extensions}
      />
      <p :if={@error} id="comment-error">{@error}</p>
      <p :if={@saved} id="comment-saved">{@saved}</p>
      <button type="submit" id="comment-submit">Save</button>
    </.form>
    <div class="row">
      <button type="button" id="toggle-comment" phx-click="toggle">Toggle the comment editor</button>
      <button type="button" id="load-comment" phx-click="load">Load the sample</button>
    </div>
    <.form for={@notes} id="notes-form">
      <label id="notes-label" class="label">Notes</label>
      <.kotoba field={@notes[:body]} id="notes_editor" label_id="notes-label" />
    </.form>
    <.form for={@formats} id="formats-form">
      <label id="formats-label" class="label">Formats</label>
      <.kotoba
        field={@formats[:body]}
        id="formats_editor"
        label_id="formats-label"
        features={~w(bold italic underline strikethrough highlight subscript superscript)}
      >
        <:toolbar>
          <.kotoba_toolbar commands={
            ~w(bold italic underline strikethrough highlight subscript superscript code undo)
          } />
        </:toolbar>
      </.kotoba>
    </.form>
    """
  end

  defp features, do: @features

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"comment" => %{"body" => body}}, socket) do
    changeset =
      {%{}, %{body: Kotoba.Content}}
      |> Ecto.Changeset.cast(%{"body" => body}, [:body])
      |> Kotoba.Content.validate_features(:body, @features)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, %{body: content}} ->
        {:noreply, assign(socket, error: nil, saved: content && content.text)}

      {:error, changeset} ->
        [{:body, {message, keys}} | _] = changeset.errors

        {:noreply,
         assign(socket, saved: nil, error: String.replace(message, "%{names}", keys[:names]))}
    end
  end

  def handle_event("toggle", _params, socket), do: {:noreply, update(socket, :shown, &(not &1))}

  def handle_event("load", _params, socket),
    do:
      {:noreply, Kotoba.Live.push_content(socket, "comment_editor", KotobaDev.Sample.document())}
end

defmodule KotobaDev.CollabChannel do
  use Kotoba.Collab.Channel, supervisor: KotobaDev.CollabSupervisor
  # Demo only. Production authorization must consult the application's ACL
  # using the verified token identity assigned during channel join.
  def authorize(_socket, _document, _action), do: :ok
end

defmodule KotobaDev.CollabSocket do
  use Phoenix.Socket
  channel("kotoba:*", KotobaDev.CollabChannel)
  def connect(_params, socket, _connect_info), do: {:ok, socket}
  def id(_socket), do: nil
end

defmodule KotobaDev.CollabLive do
  use Phoenix.LiveView
  import Kotoba.Components

  def mount(params, _session, socket) do
    id = Map.get(params, "document", "demo")
    name = Map.get(params, "name", "Ada")
    user = %{id: name, name: name, color: if(name == "Ada", do: "#2563eb", else: "#be185d")}
    role = if params["role"] == "read", do: :read, else: :write
    collab = Kotoba.Collab.token(socket, id, user: user, role: role)

    {:ok,
     assign(socket,
       document_id: id,
       user: user,
       role: role,
       collab: collab,
       form: to_form(%{"body" => nil}, as: :shared),
       saved: nil
     )}
  end

  def render(assigns) do
    ~H"""
    <h1>Shared document</h1>
    <p>Open this document in another tab with a different <code>?name=</code> to collaborate.</p>
    <.form for={@form} id="collab-form" phx-submit="save">
      <.kotoba field={@form[:body]} id="shared_editor" label="Shared document" collab={@collab} nodes={["/assets/nodes/tag.js"]} />
      <button type="submit" id="collab-save">Publish accepted revision</button>
    </.form>
    <button id="collab-insert" phx-click="insert">Insert tag</button>
    <.kotoba_content :if={@saved} content={@saved} id="collab-saved" />
    <p :if={@saved} id="collab-saved-text">{@saved.text}</p>
    """
  end

  def handle_event("kotoba:collab_token", %{"document_id" => id}, socket) do
    if id == socket.assigns.document_id do
      credentials =
        Kotoba.Collab.token(socket, id, user: socket.assigns.user, role: socket.assigns.role)

      {:reply, credentials, socket}
    else
      {:reply, %{}, socket}
    end
  end

  def handle_event("save", %{"kotoba_collab" => %{"shared_editor" => json}}, socket) do
    with {:ok, revision} <- JSON.decode(json),
         {:ok, content} <-
           Kotoba.Collab.content(KotobaDev.CollabSupervisor, socket.assigns.document_id, revision) do
      {:noreply, assign(socket, saved: content)}
    else
      _ -> {:noreply, put_flash(socket, :error, "The revision is unavailable")}
    end
  end

  def handle_event("insert", _params, socket),
    do:
      {:noreply,
       Kotoba.Live.insert_node(socket, "shared_editor", %KotobaDev.Nodes.Tag{label: "shared"})}
end

defmodule KotobaDev.ManyCollabLive do
  @moduledoc false
  # Many shared editors on one page, as in a document of many text blocks:
  # /collab/many?document=ID&count=20&name=Ada. ?repeat=1 adds a last editor of
  # the first editor's document.
  use Phoenix.LiveView
  import Kotoba.Components

  # Nested (KotobaDev.NestedCollabLive): the page's query comes in the session.
  def mount(:not_mounted_at_router, %{"params" => params}, socket), do: mount(params, %{}, socket)

  def mount(params, _session, socket) do
    prefix = Map.get(params, "document", "many")
    count = params |> Map.get("count", "3") |> String.to_integer() |> max(1) |> min(120)
    name = Map.get(params, "name", "Ada")
    user = %{id: name, name: name}
    ids = Enum.map(1..count, &"#{prefix}-#{&1}")
    # Each editor is {document id, number}; the number makes its DOM id.
    editors = Enum.with_index(ids, 1)
    editors = if params["repeat"], do: editors ++ [{hd(ids), count + 1}], else: editors

    {:ok,
     assign(socket,
       prefix: prefix,
       editors: editors,
       next: length(editors) + 1,
       user: user,
       collab: Map.new(ids, &{&1, Kotoba.Collab.token(socket, &1, user: user)}),
       form: to_form(%{}, as: :many)
     )}
  end

  def render(assigns) do
    ~H"""
    <h1>Many shared editors</h1>
    <button id="many-remove" phx-click="remove">Remove the last editor</button>
    <button id="many-add" phx-click="add">Add an editor</button>
    <.form for={@form} id="many-form">
      <div :for={{id, index} <- @editors} style="min-height: 60vh">
        <.kotoba field={@form["body_#{index}"]} id={"editor_#{index}"} label={"Block #{index}"} collab={@collab[id]} />
      </div>
    </.form>
    """
  end

  def handle_event("kotoba:collab_token", %{"document_id" => id}, socket) do
    if Map.has_key?(socket.assigns.collab, id) do
      {:reply, Kotoba.Collab.token(socket, id, user: socket.assigns.user), socket}
    else
      {:reply, %{}, socket}
    end
  end

  def handle_event("remove", _params, socket),
    do: {:noreply, assign(socket, editors: Enum.drop(socket.assigns.editors, -1))}

  def handle_event("add", _params, socket) do
    # A document no editor of the page has had.
    n = socket.assigns.next
    id = "#{socket.assigns.prefix}-#{n}"

    {:noreply,
     assign(socket,
       editors: socket.assigns.editors ++ [{id, n}],
       next: n + 1,
       collab:
         Map.put(
           socket.assigns.collab,
           id,
           Kotoba.Collab.token(socket, id, user: socket.assigns.user)
         )
     )}
  end
end

defmodule KotobaDev.NestedCollabLive do
  @moduledoc false
  # The many-editors page as a nested LiveView, under a page with a shared
  # editor of its own: /collab/nested?document=ID&count=3&name=Ada.
  use Phoenix.LiveView
  import Kotoba.Components

  def mount(params, _session, socket) do
    prefix = Map.get(params, "document", "nested")
    name = Map.get(params, "name", "Ada")
    id = "#{prefix}-parent"
    user = %{id: name, name: name}

    {:ok,
     assign(socket,
       params: params,
       document_id: id,
       user: user,
       collab: Kotoba.Collab.token(socket, id, user: user),
       form: to_form(%{}, as: :parent)
     )}
  end

  def render(assigns) do
    ~H"""
    <h1>Nested shared editors</h1>
    <.kotoba field={@form[:body]} id="parent_editor" label="Parent" collab={@collab} />
    {live_render(@socket, KotobaDev.ManyCollabLive, id: "nested", session: %{"params" => @params})}
    """
  end

  def handle_event("kotoba:collab_token", %{"document_id" => id}, socket) do
    if id == socket.assigns.document_id,
      do: {:reply, Kotoba.Collab.token(socket, id, user: socket.assigns.user), socket},
      else: {:reply, %{}, socket}
  end
end

defmodule KotobaDev.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {KotobaDev.Layouts, :root})
  end

  scope "/" do
    pipe_through(:browser)

    live("/", KotobaDev.EditorLive)
    live("/two", KotobaDev.TwoEditorsLive)
    live("/nodes", KotobaDev.NodesLive)
    live("/extensions", KotobaDev.ExtensionsLive)
    live("/collab", KotobaDev.CollabLive)
    live("/collab/many", KotobaDev.ManyCollabLive)
    live("/collab/nested", KotobaDev.NestedCollabLive)
  end
end

defmodule KotobaDev.ErrorHTML do
  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule KotobaDev.Endpoint do
  use Phoenix.Endpoint, otp_app: :kotoba

  @session [store: :cookie, key: "_kotoba_dev", signing_salt: "kotoba-dev"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]])
  socket("/kotoba/socket", KotobaDev.CollabSocket, websocket: [max_frame_size: 1_000_000])

  if System.get_env("KOTOBA_DEV_WATCH") != "false" do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  # The node modules, then the editor bundle and its style sheets.
  plug(Plug.Static, at: "/assets/nodes", from: Path.expand("tmp/dev/nodes", __DIR__))
  plug(Plug.Static, at: "/assets", from: Path.expand("priv/static", __DIR__))
  plug(Plug.Static, at: "/vendor/phoenix", from: {:phoenix, "priv/static"})
  plug(Plug.Static, at: "/vendor/phoenix_live_view", from: {:phoenix_live_view, "priv/static"})

  # The uploaded files, from tmp/uploads.
  plug(Kotoba.Storage.Local.Plug)

  plug(Plug.Parsers, parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: JSON)
  plug(Plug.Session, @session)
  plug(KotobaDev.Router)
end

# The script's process ends after this file, so the server runs in a task
# that stays alive; `mix run --no-halt` keeps the VM up.
Task.async(fn ->
  if watch?, do: {:ok, _apps} = Application.ensure_all_started(:esbuild)
  File.mkdir_p!(uploads)

  {:ok, _pid} =
    Supervisor.start_link(
      [
        {Phoenix.PubSub, name: KotobaDev.PubSub},
        {Kotoba.Collab.Store.Memory, name: KotobaDev.CollabStore},
        {Kotoba.Collab.Supervisor,
         name: KotobaDev.CollabSupervisor,
         store: {Kotoba.Collab.Store.Memory, KotobaDev.CollabStore}},
        KotobaDev.Endpoint
      ],
      strategy: :one_for_one
    )

  IO.puts("Kotoba development server: http://localhost:#{port}")
  Process.sleep(:infinity)
end)
