defmodule Kotoba.ContentTest do
  # async: false because "cast/1 uses the configured node registry" changes
  # the shared application config with Application.put_env/2.
  use ExUnit.Case, async: false

  import Kotoba.TestJSON

  alias Ecto.Changeset
  alias Kotoba.Content
  alias KotobaTest.Post

  doctest Kotoba.Content

  defmodule Chip do
    use Kotoba.Node, type: "chip", kind: :decorator
    field :label, :string, required: true

    @impl Kotoba.Node
    def render_html(node, _opts), do: Phoenix.HTML.html_escape("[" <> node.label <> "]")

    @impl Kotoba.Node
    def render_text(node, _opts), do: "[#{node.label}]"
  end

  defmodule Broken do
    use Kotoba.Node, type: "broken", kind: :decorator
    field :ref, :string, required: true

    @impl Kotoba.Node
    def render_html(_node, _opts), do: {:safe, ""}

    @impl Kotoba.Node
    def render_text(_node, _opts), do: ""
  end

  defp chip(label), do: %{"type" => "chip", "version" => 1, "label" => label}

  describe "cast/1" do
    test "a JSON string, as the form posts it" do
      json = envelope([paragraph([text("hi")])]) |> JSON.encode!()

      assert {:ok, %Content{} = content} = Content.cast(json)
      assert content.html == "<p>hi</p>"
      assert content.text == "hi"
      assert content.version == 1
    end

    test "a document envelope" do
      assert {:ok, content} = Content.cast(envelope([paragraph([text("hi")])]))
      assert content.html == "<p>hi</p>"
    end

    test "a bare Lexical root, wrapped in an envelope" do
      assert {:ok, content} = Content.cast(root([paragraph([text("hi")])]))
      assert content.doc == envelope([paragraph([text("hi")])])
      assert content.html == "<p>hi</p>"
    end

    test "a %Kotoba.Content{} that Kotoba built casts to itself" do
      {:ok, content} = Content.cast(root([paragraph([text("hi")])]))
      assert Content.cast(content) == {:ok, content}
    end

    test "a %Kotoba.Content{} is rendered again: its html and text are not kept" do
      {:ok, content} = Content.cast(root([paragraph([text("hi")])]))
      forged = %{content | html: "<script>alert(1)</script>", text: "forged"}

      assert Content.cast(forged) == {:ok, content}
    end

    test "a %Kotoba.Content{} with a document that is not valid is an error" do
      assert Content.cast(%{Content.empty() | doc: nil, html: "<script></script>"}) == :error
      assert Content.cast(%{Content.empty() | doc: %{"root" => "no"}}) == :error
    end

    test "nil and the empty string cast to empty/0" do
      assert Content.cast(nil) == {:ok, Content.empty()}
      assert Content.cast("") == {:ok, Content.empty()}
    end

    test "invalid JSON is an error" do
      assert Content.cast("{not json") == :error
    end

    test "a JSON null is an error, not empty/0" do
      assert Content.cast("null") == :error
    end

    test "a double-encoded JSON string is an error, not decoded twice" do
      double_encoded = envelope([paragraph([text("hi")])]) |> JSON.encode!() |> JSON.encode!()
      assert Content.cast(double_encoded) == :error
    end

    test "a map with no type and no root is an error" do
      assert Content.cast(%{"hello" => "world"}) == :error
    end

    test "a document that fails Kotoba.Document.parse/2 validation is an error" do
      assert Content.cast(root([%{"type" => "attachment", "version" => 1}])) == :error
    end

    test "a value of another type is an error" do
      assert Content.cast(1) == :error
      assert Content.cast([]) == :error
    end
  end

  describe "cast/1 uses the configured node registry" do
    test "an unknown node becomes known through config :kotoba, nodes:" do
      Application.put_env(:kotoba, :nodes, [Chip])
      on_exit(fn -> Application.delete_env(:kotoba, :nodes) end)

      assert {:ok, content} = Content.cast(envelope([chip("VIP")]))
      assert content.html =~ "[VIP]"
      assert content.text == "[VIP]"
    end
  end

  describe "dump/1 and load/1" do
    test "dump/1 returns a map with string keys" do
      {:ok, content} = Content.cast(root([paragraph([text("hi")])]))

      assert {:ok, dumped} = Content.dump(content)

      assert dumped == %{
               "doc" => content.doc,
               "html" => content.html,
               "text" => content.text,
               "version" => 1
             }
    end

    test "dump/1 refuses a value that is not a Kotoba.Content" do
      assert Content.dump(%{}) == :error
    end

    test "load/1 rebuilds the struct from a complete map" do
      {:ok, content} = Content.cast(root([paragraph([text("hi")])]))
      {:ok, dumped} = Content.dump(content)

      assert Content.load(dumped) == {:ok, content}
    end

    test "load/1 re-renders html and text when they are missing" do
      {:ok, content} = Content.cast(root([paragraph([text("hi")])]))

      assert Content.load(%{"doc" => content.doc}) == {:ok, content}
      assert Content.load(%{"doc" => content.doc, "html" => nil, "text" => nil}) == {:ok, content}
    end

    test "load/1 refuses a map with no doc key, or a value of another type" do
      assert Content.load(%{"html" => "x"}) == :error
      assert Content.load("not a map") == :error
    end

    test "load/1 refuses a map whose doc is not itself a map, cache or not" do
      assert Content.load(%{"doc" => "x", "html" => "y", "text" => "z"}) == :error
      assert Content.load(%{"doc" => "x"}) == :error
    end

    test "load/1 keeps a row with no cache whose doc no longer parses, with an empty cache" do
      bad_doc = envelope([%{"type" => "attachment", "version" => 1}])

      assert {:ok, content} = Content.load(%{"doc" => bad_doc})
      assert content.doc == bad_doc
      assert content.html == ""
      assert content.text == ""
    end
  end

  describe "equal?/2" do
    test "compares the doc field only" do
      {:ok, a} = Content.cast(root([paragraph([text("hi")])]))
      b = %{a | html: "different", text: "different"}

      assert Content.equal?(a, b)
      refute Content.equal?(a, Content.empty())
    end

    test "falls back to == for anything else, so nil equals nil" do
      assert Content.equal?(nil, nil)
      refute Content.equal?(Content.empty(), %{})
      refute Content.equal?(Content.empty(), nil)
    end
  end

  test "embed_as/1 is :dump" do
    assert Content.embed_as(:json) == :dump
  end

  test "type/0 is :map" do
    assert Content.type() == :map
  end

  describe "empty/0" do
    test "has an empty root, and no html or text" do
      content = Content.empty()
      assert content.html == ""
      assert content.text == ""
      assert content.doc == envelope([])
    end
  end

  describe "rerender/2" do
    test "with a registry change, an unknown node becomes known" do
      {:ok, content} = Content.cast(envelope([chip("VIP")]))
      assert content.html =~ "kotoba-unknown"
      refute content.html =~ "VIP"

      rerendered = Content.rerender(content, nodes: [Chip])
      assert rerendered.html =~ "[VIP]"
      assert rerendered.text == "[VIP]"
      assert rerendered.doc == content.doc
    end

    test "with a policy change, only html changes" do
      {:ok, content} = Content.cast(envelope([attachment()]))
      assert content.html =~ "<figure"

      untrusted = Content.rerender(content, policy: :untrusted)
      refute untrusted.html =~ "<figure"
      assert untrusted.doc == content.doc
      assert untrusted.text == content.text
    end

    test "keeps the content unchanged when the doc no longer parses" do
      {:ok, content} = Content.cast(envelope([%{"type" => "broken", "version" => 1}]))
      assert Content.rerender(content, nodes: [Broken]) == content
    end
  end

  describe "from_markdown/2" do
    test "a paragraph" do
      assert Content.from_markdown("Hello there.").text == "Hello there."
    end

    test "the lines of a paragraph are one line, as CommonMark has them" do
      assert Content.from_markdown("Line one\nLine two").text == "Line one Line two"
    end

    test "a line that ends with two spaces or a backslash ends with a line break" do
      assert Content.from_markdown("Line one  \nLine two").text == "Line one\nLine two"
      assert Content.from_markdown("Line one\\\nLine two").text == "Line one\nLine two"
    end

    test "a heading" do
      content = Content.from_markdown("## Section")
      assert content.text == "Section"
      assert content.html == "<h2>Section</h2>"
    end

    test "a bullet list" do
      content = Content.from_markdown("- one\n- two")
      assert content.text == "one\ntwo"
      assert content.html == "<ul><li>one</li><li>two</li></ul>"
    end

    test "a numbered list" do
      content = Content.from_markdown("1. one\n2. two")
      assert content.text == "one\ntwo"
      assert content.html == "<ol><li>one</li><li>two</li></ol>"
    end

    test "a fenced code block, with a language" do
      content = Content.from_markdown("```elixir\ndef f do\nend\n```")
      assert content.text == "def f do\nend"
      assert content.html == ~s(<pre><code class="language-elixir">def f do\nend</code></pre>)
    end

    test "bold, italic and inline code" do
      assert Content.from_markdown("**bold**").html == "<p><strong>bold</strong></p>"
      assert Content.from_markdown("_italic_").html == "<p><em>italic</em></p>"
      assert Content.from_markdown("`code`").html == "<p><code>code</code></p>"
    end

    test "a link" do
      content = Content.from_markdown("See [Kotoba](https://kotoba.dev) here.")
      assert content.text == "See Kotoba here."
      assert content.html =~ ~s(<a href="https://kotoba.dev" rel="noopener nofollow">Kotoba</a>)
    end

    test "a link URL keeps one level of balanced parentheses" do
      content = Content.from_markdown("[x](https://en.wikipedia.org/wiki/A_(b))")
      assert content.html =~ ~s[href="https://en.wikipedia.org/wiki/A_(b)"]
    end

    test "_ is emphasis only around non-word characters, so a snake_case name is not italic" do
      assert Content.from_markdown("snake_case_name").html == "<p>snake_case_name</p>"
      assert Content.from_markdown("Hello _world_ there.").html =~ "<em>world</em>"
    end

    test "a white-space-only line is blank, like an empty line" do
      content = Content.from_markdown("para\n   \npara2")
      assert content.text == "para\npara2"
      assert content.html == "<p>para</p><p>para2</p>"
    end

    test "a link with no text gives no node, not an empty <a>" do
      content = Content.from_markdown("[](https://example.com)")
      assert content.html == "<p></p>"
      assert content.text == ""
    end

    test "a blank line in a fenced code block gives no empty text node" do
      content = Content.from_markdown("```\na\n\nb\n```")
      assert content.text == "a\n\nb"

      %{"root" => %{"children" => [%{"children" => children}]}} = content.doc
      refute Enum.any?(children, &match?(%{"type" => "text", "text" => ""}, &1))
    end

    test "an empty string gives an empty document" do
      assert Content.from_markdown("").text == ""
      assert Content.from_markdown("").doc == envelope([])
    end

    test "* italic and ~~ strikethrough, as Kotoba's Markdown writes them" do
      assert Content.from_markdown("*italic*").html == "<p><em>italic</em></p>"
      assert Content.from_markdown("~~gone~~").html == "<p><s>gone</s></p>"
      assert Content.from_markdown("2 * 3 * 4").html == "<p>2 * 3 * 4</p>"
    end

    test "formats nest: a link in bold, bold in a link" do
      assert Content.from_markdown("**see [docs](https://a.dev)**").html ==
               ~s(<p><strong>see </strong><a href="https://a.dev" rel="noopener nofollow"><strong>docs</strong></a></p>)

      assert Content.from_markdown("[**docs**](https://a.dev)").html ==
               ~s(<p><a href="https://a.dev" rel="noopener nofollow"><strong>docs</strong></a></p>)

      assert Content.from_markdown("***both***").html == "<p><strong><em>both</em></strong></p>"
    end

    test "a quote holds blocks" do
      content = Content.from_markdown("> one\n> two\n>\n> - a\n\nafter")

      assert content.html ==
               "<blockquote><p>one two</p><ul><li>a</li></ul></blockquote><p>after</p>"
    end

    test "a check list" do
      content = Content.from_markdown("- [x] done\n- [ ] to do")
      assert content.html =~ ~s(<ul class="kotoba-check">)
      assert content.html =~ ~s(<li class="kotoba-checked")
      assert content.html =~ ~s(<li class="kotoba-unchecked")
      assert content.text =~ "done"
    end

    test "a numbered list keeps its first number" do
      assert Content.from_markdown("3. three\n4. four").html ==
               ~s(<ol start="3"><li>three</li><li>four</li></ol>)
    end

    test "a list of another kind starts a new list" do
      assert Content.from_markdown("- a\n1. b").html == "<ul><li>a</li></ul><ol><li>b</li></ol>"
    end

    test "a horizontal rule" do
      assert Content.from_markdown("a\n\n---\n\nb").html == "<p>a</p><hr><p>b</p>"
      assert Content.from_markdown("***").html == "<hr>"
    end

    test "a table, with a header row" do
      content = Content.from_markdown("| A | B |\n| --- | :-: |\n| 1 | **2** |")

      assert content.html =~
               ~s(<thead><tr><th scope="col"><p>A</p></th><th scope="col" class="kotoba-align-center"><p>B</p></th></tr></thead>)

      assert content.html =~
               ~s(<tbody><tr><td><p>1</p></td><td class="kotoba-align-center"><p><strong>2</strong></p></td></tr></tbody>)
    end

    test "Kotoba's own Markdown reads back to the same HTML" do
      markdown = """
      # Title

      Some **bold**, *italic*, ~~gone~~ and `code` with a [link](https://a.dev).

      > A quote

      - one
      - two

      1. first
      2. second

      - [x] done
      - [ ] open

      ---

      | A | B |
      | --- | --- |
      | 1 | 2 |
      """

      once = Content.from_markdown(markdown)
      {:ok, doc} = Kotoba.Document.parse(once.doc)
      twice = doc |> Kotoba.Renderer.to_markdown() |> Content.from_markdown()
      assert twice.html == once.html
    end
  end

  describe "Ecto.Type.dump/2 and Ecto.Type.load/2" do
    test "a content value round trips" do
      {:ok, content} = Content.cast(root([paragraph([text("hi")])]))

      assert {:ok, dumped} = Ecto.Type.dump(Content, content)
      assert {:ok, loaded} = Ecto.Type.load(Content, dumped)
      assert loaded == content
    end
  end

  describe "KotobaTest.Post changeset" do
    test "casts the form's JSON string" do
      json = envelope([paragraph([text("hi")])]) |> JSON.encode!()
      changeset = Post.changeset(%Post{}, %{"body" => json})

      assert changeset.valid?
      assert Changeset.get_change(changeset, :body).html == "<p>hi</p>"
    end

    test "casts a map" do
      changeset = Post.changeset(%Post{}, %{"body" => root([paragraph([text("hi")])])})

      assert changeset.valid?
      assert Changeset.get_change(changeset, :body).html == "<p>hi</p>"
    end

    test "with Ecto's defaults, an empty or blank string is dropped before it reaches Kotoba.Content.cast/1" do
      changeset = Post.changeset(%Post{}, %{"body" => ""})
      assert changeset.valid?
      refute Changeset.get_change(changeset, :body)

      changeset = Post.changeset(%Post{}, %{"body" => "   "})
      assert changeset.valid?
      refute Changeset.get_change(changeset, :body)
    end

    test "changeset_with_empty_values/2 opts in, so an empty string casts to empty content" do
      changeset = Post.changeset_with_empty_values(%Post{}, %{"body" => ""})

      assert changeset.valid?
      assert Changeset.get_change(changeset, :body) == Content.empty()
    end

    test "invalid JSON gives an 'is invalid' changeset error" do
      changeset = Post.changeset(%Post{}, %{"body" => "{not json"})

      refute changeset.valid?
      assert errors_on(changeset)[:body] == ["is invalid"]
    end

    test "dump/load round trip through the changeset's cast value" do
      changeset = Post.changeset(%Post{}, %{"body" => root([paragraph([text("hi")])])})
      content = Changeset.get_change(changeset, :body)

      {:ok, dumped} = Ecto.Type.dump(Content, content)
      assert Ecto.Type.load(Content, dumped) == {:ok, content}
    end

    test "rerender/2 with a registry change, on the cast value" do
      changeset = Post.changeset(%Post{}, %{"body" => envelope([chip("VIP")])})
      content = Changeset.get_change(changeset, :body)

      assert content.html =~ "kotoba-unknown"
      assert Content.rerender(content, nodes: [Chip]).html =~ "[VIP]"
    end
  end

  describe "validate_features/3" do
    test "refuses content with a feature that the field does not have" do
      body = root([table([table_row([table_cell([paragraph([text("x", 1)])])])])])

      changeset =
        %Post{}
        |> Post.changeset(%{"body" => body})
        |> Content.validate_features(:body, [:bold])

      refute changeset.valid?
      assert errors_on(changeset)[:body] == ["has content that is not allowed: tables"]
      assert [body: {_message, [names: "tables", validation: :features]}] = changeset.errors

      changeset =
        %Post{}
        |> Post.changeset(%{"body" => body})
        |> Content.validate_features(:body, ~w(bold tables))

      assert changeset.valid?
    end

    test "passes with no change of the field, and raises for an unknown feature" do
      assert %Post{}
             |> Post.changeset(%{})
             |> Content.validate_features(:body, [])
             |> Map.get(:valid?)

      assert_raise ArgumentError, ~r/unknown Kotoba feature/, fn ->
        %Post{} |> Post.changeset(%{}) |> Content.validate_features(:body, [:nope])
      end
    end
  end

  defp errors_on(changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
