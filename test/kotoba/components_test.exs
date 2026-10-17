defmodule Kotoba.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2, sigil_H: 2]
  import Phoenix.LiveViewTest

  alias Kotoba.{Components, Content, TestJSON}

  doctest Kotoba.Components

  # A host builds the form from a changeset (with phoenix_ecto); a map
  # form gives the same field.
  defp field(body), do: to_form(%{"body" => body}, as: :post)[:body]

  defp html(assigns), do: render_component(&Components.kotoba/1, assigns)

  defp find(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp attr(html, selector, name) do
    case html |> find(selector) |> LazyHTML.attribute(name) do
      [value] -> value
      [] -> nil
    end
  end

  defp upload_config(name \\ :attachments, opts \\ [accept: ~w(.png), max_entries: 2]) do
    socket = %Phoenix.LiveView.Socket{}
    socket = Phoenix.LiveView.allow_upload(socket, name, opts)
    socket.assigns.uploads[name]
  end

  describe "kotoba/1, the hidden input" do
    test "holds the JSON of the field's content" do
      content = Content.from_markdown("Hello **world**")
      html = html(field: field(content))

      value = attr(html, "input[type=hidden]", "value")
      assert JSON.decode!(value) == content.doc
      assert attr(html, "input[type=hidden]", "name") == "post[body]"
      assert attr(html, "input[type=hidden]", "id") == "post_body"
    end

    test "holds the empty document for a field with no value" do
      value = attr(html(field: field(nil)), "input[type=hidden]", "value")
      assert JSON.decode!(value) == Content.empty().doc
    end

    test "casts a JSON string from the params" do
      envelope = TestJSON.envelope([TestJSON.paragraph([TestJSON.text("posted")])])
      form = to_form(%{"body" => JSON.encode!(envelope)}, as: :post)
      value = attr(html(field: form[:body]), "input[type=hidden]", "value")

      assert %{"root" => %{"children" => [%{"children" => [%{"text" => "posted"}]}]}} =
               JSON.decode!(value)
    end

    test "holds the empty document for a value that does not cast" do
      form = to_form(%{"body" => "not json"}, as: :post)
      value = attr(html(field: form[:body]), "input[type=hidden]", "value")
      assert JSON.decode!(value) == Content.empty().doc
    end

    test "is outside the phx-update=ignore element" do
      html = html(field: field(nil))
      assert find(html, "[phx-update=ignore] input[type=hidden]") |> Enum.count() == 0
      assert find(html, ".kotoba-field > input[type=hidden]") |> Enum.count() == 1
    end
  end

  describe "kotoba/1, the editor element" do
    test "has the hook, the id and the default data attributes" do
      html = html(field: field(nil))
      editor = "[phx-hook=Kotoba]"

      assert attr(html, editor, "id") == "post_body_editor"
      assert attr(html, editor, "phx-update") == "ignore"
      assert attr(html, editor, "data-input") == "post_body"
      assert attr(html, editor, "data-readonly") == "false"
      assert attr(html, editor, "data-change") == "false"
      assert attr(html, editor, "data-link-schemes") == "http,https,mailto"
      assert attr(html, editor, "data-placeholder") == nil
      assert attr(html, editor, "data-nodes") == nil
      assert attr(html, editor, "data-prompts") == nil
      assert attr(html, editor, "data-upload") == nil
      assert attr(html, editor, "data-debounce") == nil
      assert attr(html, editor, "aria-labelledby") == nil
      assert attr(html, editor, "aria-label") == "Body"
    end

    test "always has an accessible name" do
      assert attr(html(field: field(nil), label: "Post body"), "[phx-hook]", "aria-label") ==
               "Post body"

      html = html(field: field(nil), label_id: "l", label: "Ignored")
      assert attr(html, "[phx-hook]", "aria-labelledby") == "l"
      assert attr(html, "[phx-hook]", "aria-label") == nil

      html = html(field: field(nil), "aria-label": "From rest")
      assert find(html, "[phx-hook]") |> LazyHTML.attribute("aria-label") == ["From rest"]
    end

    test "renders every attribute that is given" do
      html =
        html(
          field: field(nil),
          id: "body",
          label_id: "body-label",
          placeholder: "Write…",
          readonly: true,
          change: true,
          debounce: 0,
          nodes: [{Kotoba.Nodes.Mention, "/assets/pointer.js"}, "/assets/card.js"],
          prompts: [people: fn _ -> [] end, work: fn _ -> [] end],
          class: "my-field",
          "phx-target": "#comments",
          "aria-describedby": "body-help"
        )

      editor = "#body"
      assert attr(html, editor, "phx-hook") == "Kotoba"
      assert attr(html, editor, "data-readonly") == "true"
      assert attr(html, editor, "data-change") == "true"
      assert attr(html, editor, "data-placeholder") == "Write…"
      assert attr(html, editor, "data-debounce") == "0"
      assert attr(html, editor, "data-nodes") == "/assets/pointer.js,/assets/card.js"
      assert JSON.decode!(attr(html, editor, "data-prompts")) == %{"@" => "people", "#" => "work"}
      assert attr(html, editor, "data-prompt-labels") == nil
      assert attr(html, editor, "aria-labelledby") == "body-label"
      assert attr(html, editor, "data-aria-describedby") == "body-help"
      assert attr(html, editor, "aria-describedby") == nil
      assert attr(html, editor, "phx-target") == "#comments"
      assert attr(html, ".kotoba-field", "class") == "kotoba-field my-field"
    end

    test "puts the field's aria state in data attributes, which a patch updates" do
      html = html(field: field(nil), "aria-invalid": true, "aria-describedby": "a b")
      assert attr(html, "[phx-hook]", "data-aria-invalid") == "true"
      assert attr(html, "[phx-hook]", "data-aria-describedby") == "a b"
      assert attr(html, "[phx-hook]", "aria-invalid") == nil

      html = html(field: field(nil), "aria-invalid": false)
      assert attr(html, "[phx-hook]", "data-aria-invalid") == nil
    end

    test "renders explicit prompt triggers" do
      html = html(field: field(nil), prompts: [{"+", :tags, fn _ -> [] end}])
      assert JSON.decode!(attr(html, "[phx-hook]", "data-prompts")) == %{"+" => "tags"}
    end

    test "renders the labels of the prompts that have one" do
      html =
        html(
          field: field(nil),
          prompts: [
            people: {fn _ -> [] end, label: "People in the workshop"},
            work: fn _ -> [] end
          ]
        )

      assert JSON.decode!(attr(html, "[phx-hook]", "data-prompts")) == %{
               "@" => "people",
               "#" => "work"
             }

      assert JSON.decode!(attr(html, "[phx-hook]", "data-prompt-labels")) == %{
               "people" => "People in the workshop"
             }
    end

    test "renders the actions of the Assist menu" do
      assert attr(html(field: field(nil)), "[phx-hook]", "data-assist") == nil
      assert attr(html(field: field(nil), assist: false), "[phx-hook]", "data-assist") == nil
      assert attr(html(field: field(nil), assist: true), "[phx-hook]", "data-assist") == "[]"

      html =
        html(
          field: field(nil),
          assist: [
            {:rewrite, "Rewrite"},
            {"tone", "Friendlier"},
            %{id: "sum", label: "Summarize"}
          ]
        )

      assert JSON.decode!(attr(html, "[phx-hook]", "data-assist")) == [
               %{"id" => "rewrite", "label" => "Rewrite"},
               %{"id" => "tone", "label" => "Friendlier"},
               %{"id" => "sum", "label" => "Summarize"}
             ]

      for assist <- [[rewrite: ""], [{"", "Rewrite"}], [:rewrite], "rewrite", [%{id: "x"}]] do
        assert_raise ArgumentError, fn -> html(field: field(nil), assist: assist) end
      end
    end

    test "renders the languages of the code language picker, as ids" do
      assert attr(html(field: field(nil)), "[phx-hook]", "data-code-languages") == nil

      html = html(field: field(nil), code_languages: ["elixir", "js", :sql, "ex"])
      assert attr(html, "[phx-hook]", "data-code-languages") == "elixir,javascript,sql"

      assert_raise ArgumentError, ~r/unknown Kotoba code language "cobol"/, fn ->
        html(field: field(nil), code_languages: ["cobol"])
      end

      assert_raise ArgumentError, ~r/at least one language/, fn ->
        html(field: field(nil), code_languages: [])
      end
    end

    test "renders the features and the extension URLs" do
      html = html(field: field(nil))
      assert attr(html, "[phx-hook]", "data-features") == nil
      assert attr(html, "[phx-hook]", "data-extensions") == nil

      html =
        html(
          field: field(nil),
          features: ["tables", :bold, :lists, :check_lists],
          extensions: ["/assets/kotoba/callout.js", "/assets/kotoba/poll.js"]
        )

      assert attr(html, "[phx-hook]", "data-features") == "bold,lists,check_lists,tables"

      assert attr(html, "[phx-hook]", "data-extensions") ==
               "/assets/kotoba/callout.js,/assets/kotoba/poll.js"

      # An empty list is an editor with no feature: paragraphs and text.
      assert attr(html(field: field(nil), features: []), "[phx-hook]", "data-features") == ""
    end

    test "raises on features or extensions that are not valid" do
      assert_raise ArgumentError, ~r/unknown Kotoba feature "nope"/, fn ->
        html(field: field(nil), features: ["nope"])
      end

      assert_raise ArgumentError, ~r/needs :lists/, fn ->
        html(field: field(nil), features: [:check_lists])
      end

      assert_raise ArgumentError, ~r/must be a module URL/, fn ->
        html(field: field(nil), extensions: [MyApp.Callout])
      end

      assert_raise ArgumentError, ~r/cannot have a comma/, fn ->
        html(field: field(nil), extensions: ["/a,b.js"])
      end
    end

    test "raises on a prompt list that is not valid" do
      assert_raise ArgumentError, ~r/one character/, fn ->
        html(field: field(nil), prompts: [{"@@", :people, fn _ -> [] end}])
      end
    end
  end

  describe "kotoba/1 with uploads" do
    test "renders the LiveView file input, visually hidden, with a label" do
      upload = upload_config()
      html = html(field: field(nil), uploads: upload)

      assert attr(html, "[phx-hook]", "data-upload") == upload.ref
      input = "input[type=file]##{upload.ref}"
      assert attr(html, input, "data-phx-upload-ref") == upload.ref
      assert attr(html, input, "accept") == ".png"
      assert attr(html, input, "multiple") != nil
      assert attr(html, input, "tabindex") == "-1"
      assert find(html, ".kotoba-visually-hidden #{input}") |> Enum.count() == 1
      assert attr(html, "label[for='#{upload.ref}']", "for") == upload.ref

      assert find(html, "label[for='#{upload.ref}']") |> LazyHTML.text() == "Attach files"
    end

    test "renders no file input without uploads" do
      assert find(html(field: field(nil)), "input[type=file]") |> Enum.count() == 0
    end
  end

  describe "kotoba/1 with a toolbar slot" do
    test "renders the toolbar inside the editor element" do
      assigns = %{field: field(nil)}

      html =
        rendered_to_string(~H"""
        <Components.kotoba field={@field} paste_markdown={false}>
          <:toolbar><Components.kotoba_toolbar commands={["bold", "link"]} /></:toolbar>
        </Components.kotoba>
        """)

      buttons = find(html, "[phx-hook=Kotoba] [data-kotoba-toolbar] button")
      assert LazyHTML.attribute(buttons, "data-kotoba-command") == ["bold", "link"]
    end
  end

  describe "kotoba/1 with a selection menu" do
    test "no menu by default" do
      assert attr(html(%{field: field(nil)}), "[phx-hook=Kotoba]", "data-selection-menu") == nil
    end

    test "true gives the default commands, a list gives its own" do
      assert attr(
               html(%{field: field(nil), selection_menu: true}),
               "[phx-hook=Kotoba]",
               "data-selection-menu"
             ) ==
               "true"

      assert attr(
               html(%{field: field(nil), selection_menu: ["bold", :link, "callout:toggle"]}),
               "[phx-hook=Kotoba]",
               "data-selection-menu"
             ) == "bold,link,callout:toggle"
    end

    test "an unknown command raises" do
      assert_raise ArgumentError, ~r/unknown Kotoba toolbar command "shout"/, fn ->
        html(%{field: field(nil), selection_menu: ["shout"]})
      end
    end

    test "the selection slot renders the app's menu inside the editor element" do
      assigns = %{field: field(nil)}

      html =
        rendered_to_string(~H"""
        <Components.kotoba field={@field} paste_markdown={false}>
          <:selection>
            <Components.kotoba_selection_menu class="mine">
              <:button command="bold">B</:button>
              <:button command="link" label="Add a link">L</:button>
            </Components.kotoba_selection_menu>
          </:selection>
        </Components.kotoba>
        """)

      menu = "[phx-hook=Kotoba] [data-kotoba-selection-menu]"
      assert attr(html, menu, "class") == "kotoba-selection-menu mine"
      assert attr(html, menu, "aria-label") == "Selection formatting"
      assert attr(html, menu, "hidden") == ""
      buttons = find(html, menu <> " button")
      assert LazyHTML.attribute(buttons, "data-kotoba-command") == ["bold", "link"]
      assert LazyHTML.attribute(buttons, "aria-label") == ["Bold", "Add a link"]
      # It is not the editor's toolbar.
      assert find(html, "[data-kotoba-toolbar]") |> Enum.count() == 0
    end

    test "kotoba_selection_menu/1 with no buttons has a text button for each default command" do
      html = render_component(&Components.kotoba_selection_menu/1, %{})
      buttons = find(html, "button")

      assert LazyHTML.attribute(buttons, "data-kotoba-command") ==
               ~w(bold italic underline strikethrough code highlight link)
    end
  end

  describe "kotoba_toolbar/1" do
    defp toolbar(assigns), do: render_component(&Components.kotoba_toolbar/1, assigns)

    test "renders a text button for each command" do
      html = toolbar(%{})
      controls = find(html, "[data-kotoba-command]")

      assert LazyHTML.attribute(controls, "data-kotoba-command") == Components.toolbar_commands()
      assert Enum.all?(LazyHTML.attribute(find(html, "button"), "type"), &(&1 == "button"))

      # The code language picker is a select, which the editor fills.
      assert attr(html, "select[data-kotoba-command=code-language]", "aria-label") ==
               "Code language"

      assert find(html, "select option") |> Enum.count() == 0
      assert attr(html, "[data-kotoba-toolbar]", "aria-label") == "Formatting"
      assert attr(html, "[data-kotoba-toolbar]", "data-kotoba-toolbar") == ""
      assert attr(html, "[data-kotoba-toolbar]", "phx-update") == nil
      assert attr(html, "button[data-kotoba-command=h2]", "title") == "Heading 2"
    end

    test "has the commands of the editor's toolbar, in its order" do
      source = File.read!(Path.expand("../../assets/src/toolbar.ts", __DIR__))
      [items] = Regex.run(~r/TOOLBAR_ITEMS[^=]*= \[(.*?)\n\];/s, source, capture: :all_but_first)
      editor = Regex.scan(~r/command: "([a-z0-9-]+)", label: "([^"]+)"/, items)

      assert Enum.map(editor, fn [_, command, _label] -> command end) ==
               Components.toolbar_commands()

      html = toolbar(%{})

      for [_, command, label] <- editor do
        assert attr(html, "[data-kotoba-command=#{command}]", "title") == label
      end
    end

    test "takes the command of an extension's control, with its label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Components.kotoba_toolbar>
          <:button command="callout:insert" label="Callout"><svg class="icon-callout" /></:button>
        </Components.kotoba_toolbar>
        """)

      assert attr(html, "button[data-kotoba-command='callout:insert']", "aria-label") == "Callout"

      for command <- ["callout", "Callout:insert", "callout:", "a_b:insert"] do
        assert_raise ArgumentError, ~r/unknown Kotoba toolbar command/, fn ->
          toolbar(%{commands: [command]})
        end
      end
    end

    test "outside the editor, points at it and is ignored by patches" do
      html = toolbar(%{for: "post-body", commands: ["bold"]})

      assert attr(html, "[data-kotoba-toolbar]", "data-kotoba-toolbar") == "post-body"
      assert attr(html, "[data-kotoba-toolbar]", "id") == "post-body-toolbar"
      assert attr(html, "[data-kotoba-toolbar]", "phx-update") == "ignore"
    end

    test "renders button slots with an accessible name" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Components.kotoba_toolbar for="body">
          <:button command="bold"><svg class="icon-bold" /></:button>
          <:button command="link" label="Add a link"><svg class="icon-link" /></:button>
        </Components.kotoba_toolbar>
        """)

      assert attr(html, "button[data-kotoba-command=bold]", "aria-label") == "Bold"
      assert attr(html, "button[data-kotoba-command=link]", "aria-label") == "Add a link"
      assert find(html, "button[data-kotoba-command=bold] svg.icon-bold") |> Enum.count() == 1
    end

    test "raises on an unknown command" do
      assert_raise ArgumentError, ~r/unknown Kotoba toolbar command "shout"/, fn ->
        toolbar(%{commands: ["shout"]})
      end
    end
  end

  describe "kotoba_content/1" do
    defp content_html(assigns), do: render_component(&Components.kotoba_content/1, assigns)

    test "renders the cached HTML" do
      content = %{Content.from_markdown("Hello") | html: "<p>cached</p>"}
      assert content_html(content: content) =~ ~s(<div class="kotoba-content"><p>cached</p></div>)
    end

    test "renders again when the cache version is not the current one" do
      content = %{Content.from_markdown("Hello") | html: "<p>stale</p>", version: 0}
      html = content_html(content: content)

      assert html =~ "<p>Hello</p>"
      refute html =~ "stale"
    end

    test "renders again with another policy" do
      content = Content.from_markdown("[site](https://example.com)")
      assert content_html(content: content) =~ ~s(href="https://example.com")

      html = content_html(content: content, policy: :untrusted)
      refute html =~ "href"
      assert html =~ "site"
    end

    test "renders again with extra nodes" do
      content = %{Content.from_markdown("Hello") | html: "<p>cached</p>"}

      assert content_html(content: content, nodes: [{KotobaTest.Nodes.Pointer, "/m.js"}]) =~
               "Hello"
    end

    test "takes the same nodes as kotoba/1, plain JavaScript URLs included" do
      content = %{Content.from_markdown("Hello") | html: "<p>cached</p>"}

      assert content_html(content: content, nodes: ["/assets/nodes/chart.js"]) =~
               "<p>cached</p>"

      assert content_html(
               content: content,
               nodes: ["/assets/nodes/chart.js", {KotobaTest.Nodes.Pointer, "/m.js"}]
             ) =~ "<p>Hello</p>"
    end

    test "escapes text on a re-render" do
      doc = TestJSON.envelope([TestJSON.paragraph([TestJSON.text("<script>x</script>")])])
      {:ok, content} = Content.cast(doc)
      html = content_html(content: %{content | version: 0}, class: "prose")

      assert html =~ "&lt;script&gt;"
      assert html =~ ~s(class="kotoba-content prose")
    end

    test "renders nothing for a document that no longer parses" do
      content = %Content{doc: %{"kotoba" => 2}, html: "<p>old</p>", text: "", version: 0}
      assert content_html(content: content) == ~s(<div class="kotoba-content"></div>)
    end

    test "renders an empty wrapper for nil" do
      assert content_html(content: nil) == ~s(<div class="kotoba-content"></div>)
    end
  end
end

defmodule Kotoba.ComponentsConfigTest do
  # Changes the shared application config, so it does not run with the
  # async tests.
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  test "kotoba/1 renders the configured link schemes" do
    Application.put_env(:kotoba, :allowed_link_schemes, ~w(HTTPS tel))
    on_exit(fn -> Application.delete_env(:kotoba, :allowed_link_schemes) end)

    field = to_form(%{"body" => nil}, as: :post)[:body]
    html = render_component(&Kotoba.Components.kotoba/1, field: field)

    assert html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("[phx-hook]")
           |> LazyHTML.attribute("data-link-schemes") == ["https,tel"]
  end
end
