defmodule Kotoba.RendererTest do
  use ExUnit.Case, async: true

  import Kotoba.TestJSON

  alias Kotoba.Renderer

  doctest Kotoba.Renderer

  defmodule Pointer do
    use Kotoba.Node, type: "pointer", kind: :inline

    import Phoenix.Component, only: [sigil_H: 2]

    field :ref, :string, required: true
    field :excerpt, :string

    @impl Kotoba.Node
    def render_html(node, _opts) do
      assigns = %{node: node}

      ~H"""
      <span class="pointer" data-ref={@node.ref}>{@node.excerpt}</span>
      """
    end

    @impl Kotoba.Node
    def render_text(node, _opts), do: "[#{node.excerpt}]"
  end

  defmodule Panel do
    use Kotoba.Node, type: "panel", kind: :block, element: true

    @impl Kotoba.Node
    def render_html(node, opts),
      do: Renderer.tag("section", [class: "panel"], Renderer.html_children(node, opts))

    @impl Kotoba.Node
    def render_text(node, opts), do: Renderer.text_children(node, opts)

    @impl Kotoba.Node
    def render_markdown(node, opts), do: "::: " <> Renderer.markdown_children(node, opts)
  end

  defp html(children, opts \\ []) do
    children |> doc() |> Renderer.to_html(opts) |> Phoenix.HTML.safe_to_string()
  end

  defp html_with(children, nodes, opts \\ []) do
    {:ok, doc} = Kotoba.Document.parse(envelope(children), nodes: nodes)
    doc |> Renderer.to_html(opts) |> Phoenix.HTML.safe_to_string()
  end

  describe "to_html/2 of each node" do
    test "returns safe iodata" do
      assert {:safe, iodata} = Renderer.to_html(doc([paragraph([text("a")])]))
      assert IO.iodata_to_binary(iodata) == "<p>a</p>"
    end

    test "an empty document" do
      assert html([]) == ""
    end

    test "paragraph" do
      assert html([paragraph([text("Hello")])]) == "<p>Hello</p>"
      assert html([paragraph([])]) == "<p></p>"
    end

    test "heading, h1 to h6" do
      assert html([heading("h1", [text("A")])]) == "<h1>A</h1>"
      assert html([heading("h3", [text("A")])]) == "<h3>A</h3>"
      assert html([heading("h4", [text("A")])]) == "<h4>A</h4>"
      assert html([heading("h5", [text("A")])]) == "<h5>A</h5>"
      assert html([heading("h6", [text("A")])]) == "<h6>A</h6>"
    end

    test "quote" do
      assert html([quote_block([text("q"), linebreak(), text("r")])]) ==
               "<blockquote>q<br>r</blockquote>"
    end

    test "bullet and number lists" do
      assert html([list("bullet", [item([text("a")]), item([text("b")])])]) ==
               "<ul><li>a</li><li>b</li></ul>"

      assert html([list("number", [item([text("a")])])]) == "<ol><li>a</li></ol>"

      assert html([list("number", [item([text("a")])], %{"start" => 4})]) ==
               ~s(<ol start="4"><li>a</li></ol>)
    end

    test "check list" do
      input = [
        list("check", [
          item([text("done")], %{"checked" => true}),
          item([text("todo")], %{"checked" => false}),
          item([text("new")])
        ])
      ]

      assert html(input) ==
               ~s(<ul class="kotoba-check"><li class="kotoba-checked">done</li>) <>
                 ~s(<li class="kotoba-unchecked">todo</li><li class="kotoba-unchecked">new</li></ul>)
    end

    test "nested lists render in the item" do
      input = [
        list("bullet", [
          item([text("a")]),
          item([list("number", [item([text("a.1")])])]),
          item([text("b"), list("bullet", [item([text("b.1")])])])
        ])
      ]

      assert html(input) ==
               "<ul><li>a</li><li><ol><li>a.1</li></ol></li>" <>
                 "<li>b<ul><li>b.1</li></ul></li></ul>"
    end

    test "an item that holds only a nested list has no check class" do
      input = [list("check", [item([list("check", [item([text("x")], %{"checked" => true})])])])]

      assert html(input) ==
               ~s(<ul class="kotoba-check"><li><ul class="kotoba-check">) <>
                 ~s(<li class="kotoba-checked">x</li></ul></li></ul>)
    end

    test "code block with a language class and escaped text" do
      input = [
        code(
          [highlight("def", "keyword"), highlight(" x <> "), linebreak(), text("\"y\" & 'z'")],
          "elixir"
        )
      ]

      assert html(input) ==
               ~s(<pre><code class="language-elixir">def x &lt;&gt; \n&quot;y&quot; &amp; &#39;z&#39;</code></pre>)
    end

    test "code block with no language, or a language that is not a safe class name" do
      assert html([code([highlight("x")])]) == "<pre><code>x</code></pre>"
      assert html([code([highlight("x")], "js onclick")]) == "<pre><code>x</code></pre>"
    end

    test "text formats" do
      cases = [
        {1, "<strong>t</strong>"},
        {2, "<em>t</em>"},
        {4, "<s>t</s>"},
        {8, "<u>t</u>"},
        {16, "<code>t</code>"},
        {32, "<sub>t</sub>"},
        {64, "<sup>t</sup>"},
        {128, "<mark>t</mark>"},
        {256, ~s(<span class="kotoba-lowercase">t</span>)},
        {512, ~s(<span class="kotoba-uppercase">t</span>)},
        {1024, ~s(<span class="kotoba-capitalize">t</span>)},
        {1 + 2 + 16, "<strong><em><code>t</code></em></strong>"}
      ]

      for {format, expected} <- cases do
        assert html([paragraph([text("t", format)])]) == "<p>#{expected}</p>"
      end
    end

    test "text never renders its style" do
      input = [paragraph([Map.put(text("t"), "style", "color: red")])]
      assert html(input) == "<p>t</p>"
    end

    test "line break and horizontal rule" do
      assert html([paragraph([text("a"), linebreak(), text("b")]), hr()]) ==
               "<p>a<br>b</p><hr>"
    end

    test "tab, in a paragraph and in a code block" do
      assert html([paragraph([text("a"), tab(), text("b")])]) == "<p>a\tb</p>"

      assert html([code([highlight("a"), tab(), highlight("b")])]) ==
               "<pre><code>a\tb</code></pre>"
    end

    test "link" do
      assert html([paragraph([link("https://example.com", [text("x")])])]) ==
               ~s(<p><a href="https://example.com" rel="noopener nofollow">x</a></p>)
    end

    test "link with a target and a title" do
      input = [
        paragraph([
          link("https://example.com", [text("x")], %{"target" => "_blank", "title" => "T"}),
          link("/a", [text("y")], %{"target" => "_self", "rel" => "opener"})
        ])
      ]

      assert html(input) ==
               ~s(<p><a href="https://example.com" rel="noopener nofollow" target="_blank" title="T">x</a>) <>
                 ~s(<a href="/a" rel="noopener nofollow">y</a></p>)
    end

    test "autolink, and an autolink that the writer unlinked" do
      input = [
        paragraph([
          autolink("https://a.b", [text("https://a.b")]),
          autolink("https://c.d", [text("c")], %{"isUnlinked" => true})
        ])
      ]

      assert html(input) ==
               ~s(<p><a href="https://a.b" rel="noopener nofollow">https://a.b</a>c</p>)
    end

    test "image attachment" do
      assert html([attachment()]) ==
               ~s(<figure class="kotoba-attachment"><img src="/uploads/k/cat.png" alt="cat.png" width="640" height="480">) <>
                 "<figcaption>cat.png</figcaption></figure>"
    end

    test "file attachment" do
      input = [
        attachment(%{"contentType" => "application/zip", "name" => "a.zip", "url" => "/f/a.zip"})
        |> Map.drop(["width", "height"])
      ]

      assert html(input) ==
               ~s(<figure class="kotoba-attachment"><figcaption>) <>
                 ~s(<a href="/f/a.zip" download rel="noopener nofollow">a.zip</a></figcaption></figure>)
    end

    test "PDF attachment: the browser's viewer, with a download link" do
      input = [
        attachment(%{"contentType" => "application/pdf", "name" => "a.pdf", "url" => "/f/a.pdf"})
        |> Map.drop(["width", "height"])
      ]

      link = ~s(<a href="/f/a.pdf" download rel="noopener nofollow">a.pdf</a>)

      assert html(input) ==
               ~s(<figure class="kotoba-attachment kotoba-attachment-pdf">) <>
                 ~s(<object data="/f/a.pdf" type="application/pdf" aria-label="a.pdf">#{link}</object>) <>
                 "<figcaption>#{link}</figcaption></figure>"
    end

    test "PDF attachment with a preview image" do
      input = [
        attachment(%{
          "contentType" => "application/pdf",
          "name" => "a.pdf",
          "url" => "/f/a.pdf",
          "preview" => "/f/a.png"
        })
        |> Map.drop(["width", "height"])
      ]

      assert html(input) ==
               ~s(<figure class="kotoba-attachment kotoba-attachment-pdf">) <>
                 ~s(<a href="/f/a.pdf" rel="noopener nofollow"><img src="/f/a.png" alt="Preview of a.pdf"></a>) <>
                 ~s(<figcaption><a href="/f/a.pdf" download rel="noopener nofollow">a.pdf</a></figcaption></figure>)
    end

    test "video attachment: controls, metadata only, no autoplay, the preview as its poster" do
      input = [
        attachment(%{
          "contentType" => "video/webm",
          "name" => "clip.webm",
          "url" => "/f/clip.webm",
          "preview" => "/f/clip.jpg"
        })
        |> Map.drop(["width", "height"])
      ]

      link = ~s(<a href="/f/clip.webm" download rel="noopener nofollow">clip.webm</a>)

      assert html(input) ==
               ~s(<figure class="kotoba-attachment kotoba-attachment-video">) <>
                 ~s(<video src="/f/clip.webm" controls preload="metadata" playsinline poster="/f/clip.jpg" aria-label="clip.webm">) <>
                 "#{link}</video><figcaption>#{link}</figcaption></figure>"

      refute html(input) =~ "autoplay"
    end

    test "an attachment with a preview that is not a safe URL renders as unknown" do
      input = [
        attachment(%{"contentType" => "video/mp4", "preview" => "javascript:alert(1)"})
      ]

      assert html(input) == ~s(<span class="kotoba-unknown" data-type="attachment"></span>)
    end

    test "mention" do
      assert html([paragraph([text("Hi "), mention("people", "u1", "Ada")])]) ==
               ~s(<p>Hi <span class="kotoba-mention" data-kind="people" data-id="u1">Ada</span></p>)
    end

    test "unknown node" do
      assert html([unknown("x-chart"), paragraph([unknown("x-chip")])]) ==
               ~s(<span class="kotoba-unknown" data-type="x-chart"></span>) <>
                 ~s(<p><span class="kotoba-unknown" data-type="x-chip"></span></p>)
    end

    test "a custom node with a ~H template and a custom element node" do
      input = [
        element("panel", [
          paragraph([%{"type" => "pointer", "version" => 1, "ref" => "r\"1", "excerpt" => "<i>"}])
        ])
      ]

      assert html_with(input, [Pointer, Panel]) ==
               ~s(<section class="panel"><p><span class="pointer" data-ref="r&quot;1">&lt;i&gt;</span></p></section>)
    end
  end

  describe "escaping" do
    test "a script in text is escaped" do
      assert html([paragraph([text("<script>alert(1)</script>")])]) ==
               "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>"
    end

    test "every attribute is escaped" do
      input = [
        paragraph([
          mention("\"><script>", "1\" onclick=\"x", "<b>"),
          link("/x?a=1&b=\"2\"", [text("l")], %{"title" => "\"><img src=x>"})
        ])
      ]

      html = html(input)

      refute html =~ "<script>"
      refute html =~ "<img"
      refute html =~ ~s(" onclick)

      assert html ==
               ~s(<p><span class="kotoba-mention" data-kind="&quot;&gt;&lt;script&gt;" data-id="1&quot; onclick=&quot;x">&lt;b&gt;</span>) <>
                 ~s(<a href="/x?a=1&amp;b=&quot;2&quot;" rel="noopener nofollow" title="&quot;&gt;&lt;img src=x&gt;">l</a></p>)
    end

    test "a javascript: link renders its text with no anchor" do
      for url <- [
            "javascript:alert(1)",
            " JavaScript:alert(1)",
            "java\tscript:alert(1)",
            "data:text/html,x"
          ] do
        assert html([paragraph([link(url, [text("click")])])]) == "<p>click</p>"
      end
    end

    test "an attachment with a javascript: URL renders as unknown" do
      assert html([attachment(%{"url" => "javascript:alert(1)"})]) ==
               ~s(<span class="kotoba-unknown" data-type="attachment"></span>)
    end

    test "the unknown type is escaped" do
      assert html([unknown("x\"><script>")]) ==
               ~s(<span class="kotoba-unknown" data-type="x&quot;&gt;&lt;script&gt;"></span>)
    end
  end

  describe "policies" do
    setup do
      input = [
        paragraph([
          link("https://example.com", [text("site")]),
          text(" "),
          mention("people", "1", "Ada")
        ]),
        attachment(),
        attachment(%{"contentType" => "application/pdf", "name" => "a.pdf"})
      ]

      %{input: input}
    end

    test ":untrusted renders no anchors and no attachments", %{input: input} do
      html = html(input, policy: :untrusted)

      assert html ==
               ~s(<p>site <span class="kotoba-mention" data-kind="people" data-id="1">Ada</span></p>) <>
                 "cat.pnga.pdf"

      refute html =~ "<a"
      refute html =~ "<img"
      refute html =~ "<figure"
    end

    test ":default renders anchors and attachments", %{input: input} do
      html = html(input, policy: :default)
      assert html =~ ~s(<a href="https://example.com")
      assert html =~ "<img"
    end

    test "an unknown policy raises" do
      assert_raise ArgumentError, ~r/unknown policy/, fn -> html([], policy: :open) end
    end

    test "the :schemes option and the config choose the link schemes" do
      input = [paragraph([link("tel:+100", [text("call")])])]

      assert html(input) == "<p>call</p>"

      assert html(input, schemes: ["tel"]) ==
               ~s(<p><a href="tel:+100" rel="noopener nofollow">call</a></p>)
    end
  end

  describe "nesting violations render the node as unknown" do
    test "a list holds only list items" do
      assert html([list("bullet", [item([text("a")]), paragraph([text("p")])])]) ==
               ~s(<ul><li>a</li><span class="kotoba-unknown" data-type="paragraph"></span></ul>)
    end

    test "a list item holds one nested list and no other blocks" do
      input = [
        list("bullet", [
          item([
            text("a"),
            list("bullet", [item([text("b")])]),
            list("bullet", [item([text("c")])]),
            paragraph([text("d")])
          ])
        ])
      ]

      assert html(input) ==
               "<ul><li>a<ul><li>b</li></ul>" <>
                 ~s(<span class="kotoba-unknown" data-type="list"></span>) <>
                 ~s(<span class="kotoba-unknown" data-type="paragraph"></span></li></ul>)
    end

    test "a list item holds only one nested list even when a second list is identical to the first" do
      nested = list("bullet", [item([text("b")])])
      input = [list("bullet", [item([nested, nested])])]

      assert html(input) ==
               "<ul><li><ul><li>b</li></ul>" <>
                 ~s(<span class="kotoba-unknown" data-type="list"></span></li></ul>)
    end

    test "a code block holds only code highlight, text, line breaks and tabs" do
      input = [code([highlight("x"), link("https://a.b", [text("l")]), mention("p", "1", "A")])]
      assert html(input) == "<pre><code>x</code></pre>"
    end

    test "a horizontal rule and an attachment are valid only under the root, a list item or a table cell" do
      input = [paragraph([hr(), attachment()])]

      assert html(input) ==
               ~s(<p><span class="kotoba-unknown" data-type="horizontalrule"></span>) <>
                 ~s(<span class="kotoba-unknown" data-type="attachment"></span></p>)

      assert html([list("bullet", [item([hr(), attachment()])])]) ==
               ~s(<ul><li><hr><figure class="kotoba-attachment">) <>
                 ~s(<img src="/uploads/k/cat.png" alt="cat.png" width="640" height="480">) <>
                 "<figcaption>cat.png</figcaption></figure></li></ul>"
    end

    test "a list item outside a list renders as unknown" do
      assert html([item([text("x")])]) ==
               ~s(<span class="kotoba-unknown" data-type="listitem"></span>)
    end

    test "a paragraph holds no blocks and a link holds no link" do
      input = [
        paragraph([
          heading("h1", [text("h")]),
          link("https://a.b", [link("https://c.d", [text("inner")]), text("outer")])
        ])
      ]

      assert html(input) ==
               ~s(<p><span class="kotoba-unknown" data-type="heading"></span>) <>
                 ~s(<a href="https://a.b" rel="noopener nofollow">) <>
                 ~s(<span class="kotoba-unknown" data-type="link"></span>outer</a></p>)
    end

    test "a decorator has no children" do
      defmodule Boxed do
        use Kotoba.Node, type: "boxed", kind: :decorator, element: true

        @impl Kotoba.Node
        def render_html(_node, _opts), do: {:safe, "<b>boxed</b>"}

        @impl Kotoba.Node
        def render_text(_node, _opts), do: "boxed"
      end

      assert html_with([element("boxed", [])], [Boxed]) == "<b>boxed</b>"

      assert html_with([element("boxed", [text("x")])], [Boxed]) ==
               ~s(<span class="kotoba-unknown" data-type="boxed"></span>)
    end

    test "a string attribute that is too long or has a control character" do
      assert html([paragraph([link("https://a.b", [text("x")], %{"title" => "a\nb"})])]) ==
               ~s(<p><span class="kotoba-unknown" data-type="link"></span></p>)

      long = String.duplicate("a", 201)

      assert html([paragraph([mention("people", "1", long)])]) ==
               ~s(<p><span class="kotoba-unknown" data-type="mention"></span></p>)

      assert html([paragraph([mention("people", "1\u0000", "Ada")])]) ==
               ~s(<p><span class="kotoba-unknown" data-type="mention"></span></p>)

      url = "https://example.com/" <> String.duplicate("a", 2048)

      assert html([paragraph([link(url, [text("x")])])]) == "<p>x</p>"
    end

    test "a node that map/2 made not valid renders as unknown, with no raise" do
      doc =
        [paragraph([text("a")])]
        |> doc()
        |> Kotoba.Document.map(fn
          %Kotoba.Nodes.Text{} = node -> %{node | text: nil}
          node -> node
        end)

      assert Phoenix.HTML.safe_to_string(Renderer.to_html(doc)) ==
               ~s(<p><span class="kotoba-unknown" data-type="text"></span></p>)
    end
  end

  describe "tables" do
    defp cell(value, header_state \\ 0, attrs \\ %{}),
      do: table_cell([paragraph([text(value)])], header_state, attrs)

    defp people_table do
      table([
        table_row([cell("Name", 1), cell("Role", 1)]),
        table_row([cell("Ada"), table_cell([paragraph([text("Engineer", 1)])])])
      ])
    end

    test "a first row of header cells goes in a thead, with th scope=col" do
      assert html([people_table()]) ==
               ~s(<div class="kotoba-table-scroll"><table class="kotoba-table"><thead><tr>) <>
                 ~s(<th scope="col"><p>Name</p></th><th scope="col"><p>Role</p></th>) <>
                 "</tr></thead><tbody><tr><td><p>Ada</p></td>" <>
                 "<td><p><strong>Engineer</strong></p></td></tr></tbody></table></div>"
    end

    test "a header column has th scope=row; spans render, colours and widths do not" do
      input =
        table(
          [
            table_row([
              cell("Total", 2),
              cell("42", 0, %{
                "colSpan" => 2,
                "rowSpan" => 3,
                "backgroundColor" => "#ffeeaa",
                "width" => 120
              })
            ]),
            table_row([cell("Corner", 3), cell("x")])
          ],
          %{"colWidths" => [90, 60, 60]}
        )

      assert html([input]) ==
               ~s(<div class="kotoba-table-scroll"><table class="kotoba-table"><tbody><tr><th scope="row"><p>Total</p></th>) <>
                 ~s(<td colspan="2" rowspan="3"><p>42</p></td></tr>) <>
                 ~s(<tr><th scope="col"><p>Corner</p></th><td><p>x</p></td></tr></tbody></table></div>)
    end

    test "a first row with a data cell is not a header row" do
      input = table([table_row([cell("a", 1), cell("b")]), table_row([cell("c"), cell("d")])])

      assert html([input]) ==
               ~s(<div class="kotoba-table-scroll"><table class="kotoba-table"><tbody><tr><th scope="col"><p>a</p></th>) <>
                 "<td><p>b</p></td></tr><tr><td><p>c</p></td><td><p>d</p></td></tr></tbody></table></div>"
    end

    test "a cell holds blocks and block decorators" do
      input =
        table([
          table_row([
            table_cell([
              heading("h2", [text("H")]),
              list("bullet", [item([text("i")])]),
              code([highlight("x")]),
              hr(),
              attachment()
            ])
          ])
        ])

      assert html([input]) ==
               ~s(<div class="kotoba-table-scroll"><table class="kotoba-table"><tbody><tr><td><h2>H</h2><ul><li>i</li></ul>) <>
                 "<pre><code>x</code></pre><hr>" <>
                 ~s(<figure class="kotoba-attachment">) <>
                 ~s(<img src="/uploads/k/cat.png" alt="cat.png" width="640" height="480">) <>
                 "<figcaption>cat.png</figcaption></figure></td></tr></tbody></table></div>"
    end

    test "an empty table has an empty tbody" do
      assert html([table([])]) ==
               ~s(<div class="kotoba-table-scroll"><table class="kotoba-table"><tbody></tbody></table></div>)
    end

    test "a table is valid only under the root, and holds no table" do
      unknown = ~s(<span class="kotoba-unknown" data-type="table"></span>)

      assert html([quote_block([people_table()])]) == "<blockquote>#{unknown}</blockquote>"
      assert html([list("bullet", [item([people_table()])])]) == "<ul><li>#{unknown}</li></ul>"

      assert html([table([table_row([table_cell([people_table()])])])]) ==
               ~s(<div class="kotoba-table-scroll"><table class="kotoba-table"><tbody><tr><td>#{unknown}</td></tr></tbody></table></div>)
    end

    test "rows are valid only in a table, and cells only in a row" do
      assert html([table_row([cell("x")])]) ==
               ~s(<span class="kotoba-unknown" data-type="tablerow"></span>)

      assert html([table([cell("x")])]) ==
               ~s(<div class="kotoba-table-scroll"><table class="kotoba-table"><tbody>) <>
                 ~s(<span class="kotoba-unknown" data-type="tablecell"></span></tbody></table></div>)

      assert html([table([table_row([paragraph([text("x")])])])]) ==
               ~s(<div class="kotoba-table-scroll"><table class="kotoba-table"><tbody><tr>) <>
                 ~s(<span class="kotoba-unknown" data-type="paragraph"></span></tr></tbody></table></div>)

      assert html([paragraph([cell("x")])]) ==
               ~s(<p><span class="kotoba-unknown" data-type="tablecell"></span></p>)
    end

    test "to_text/2 gives a line for each row, with the cells separated by a tab" do
      input = [
        paragraph([text("Before")]),
        people_table(),
        table([
          table_row([table_cell([paragraph([text("a")]), paragraph([text("b")])]), cell("c")])
        ]),
        paragraph([text("After")])
      ]

      assert input |> doc() |> Renderer.to_text() ==
               "Before\nName\tRole\nAda\tEngineer\na\nb\tc\nAfter"
    end

    test "to_markdown/2 writes a table with a header row" do
      input = [paragraph([text("Before")]), people_table(), paragraph([text("After")])]

      assert input |> doc() |> Renderer.to_markdown() ==
               "Before\n\n| Name | Role |\n| --- | --- |\n| Ada | **Engineer** |\n\nAfter"
    end

    test "to_markdown/2 gives a table with no header row an empty one, and keeps each cell on its line" do
      input =
        table([
          table_row([cell("Total", 2), cell("a | b")]),
          table_row([
            table_cell([paragraph([text("x"), linebreak(), text("y")]), paragraph([text("z")])])
          ]),
          table_row([
            table_cell([list("bullet", [item([text("Navy")]), item([text("COBOL")])])]),
            table_cell([paragraph([text("c"), tab(), text("d")])])
          ])
        ])

      assert [input] |> doc() |> Renderer.to_markdown() ==
               Enum.join(
                 [
                   "|  |  |",
                   "| --- | --- |",
                   "| Total | a \\| b |",
                   "| x<br>y<br>z |  |",
                   "| - Navy<br>- COBOL | c d |"
                 ],
                 "\n"
               )
    end

    test "to_markdown/2 of an empty table has one empty column" do
      assert [table([])] |> doc() |> Renderer.to_markdown() == "|  |\n| --- |"
    end
  end

  describe "galleries" do
    setup do
      dog = attachment(%{"name" => "dog.png", "url" => "/uploads/k/dog.png", "key" => "k2"})
      %{images: [attachment(), dog |> Map.drop(["width", "height"])]}
    end

    test "a gallery is a div with the figure of each image", %{images: images} do
      assert html([gallery(images)]) ==
               ~s(<div class="kotoba-gallery">) <>
                 ~s(<figure class="kotoba-attachment"><img src="/uploads/k/cat.png" alt="cat.png" width="640" height="480">) <>
                 "<figcaption>cat.png</figcaption></figure>" <>
                 ~s(<figure class="kotoba-attachment"><img src="/uploads/k/dog.png" alt="dog.png">) <>
                 "<figcaption>dog.png</figcaption></figure></div>"
    end

    test "its text and Markdown have one image a line", %{images: images} do
      doc = doc([paragraph([text("Look")]), gallery(images), paragraph([text("end")])])

      assert Renderer.to_text(doc) == "Look\ncat.png\ndog.png\nend"

      assert Renderer.to_markdown(doc) ==
               "Look\n\n![cat.png](/uploads/k/cat.png)\n![dog.png](/uploads/k/dog.png)\n\nend"
    end

    test ":untrusted renders the names in a paragraph", %{images: images} do
      input = [gallery([attachment(%{"name" => "<b>.png"}) | images])]

      assert html(input, policy: :untrusted) == "<p>&lt;b&gt;.png, cat.png, dog.png</p>"
    end

    test "a gallery is valid only under the root, and holds only attachments", %{images: images} do
      assert html([list("bullet", [item([gallery(images)])])]) ==
               ~s(<ul><li><span class="kotoba-unknown" data-type="gallery"></span></li></ul>)

      assert html([gallery([paragraph([text("no")]), hd(images)])]) ==
               ~s(<div class="kotoba-gallery"><span class="kotoba-unknown" data-type="paragraph"></span>) <>
                 ~s(<figure class="kotoba-attachment"><img src="/uploads/k/cat.png" alt="cat.png" width="640" height="480">) <>
                 "<figcaption>cat.png</figcaption></figure></div>"
    end

    test "an attachment with a URL that is not safe renders as unknown in a gallery" do
      assert html([gallery([attachment(%{"url" => "javascript:alert(1)"})])]) ==
               ~s(<div class="kotoba-gallery"><span class="kotoba-unknown" data-type="attachment"></span></div>)
    end
  end

  describe "to_text/2" do
    test "joins the blocks with a new line" do
      input = [
        heading("h1", [text("Title")]),
        paragraph([
          text("Hi "),
          mention("people", "1", "Ada"),
          text("!"),
          linebreak(),
          text("next")
        ]),
        hr(),
        list("bullet", [item([text("a"), list("bullet", [item([text("b")])])]), item([text("c")])]),
        code([highlight("x = 1"), linebreak(), highlight("y")]),
        quote_block([link("https://a.b", [text("link")])]),
        attachment(),
        unknown("x-chart"),
        paragraph([text("<end>")])
      ]

      assert input |> doc() |> Renderer.to_text() ==
               "Title\nHi Ada!\nnext\na\nb\nc\nx = 1\ny\nlink\ncat.png\n<end>"
    end

    test "a custom node gives its render_text/2" do
      {:ok, doc} =
        Kotoba.Document.parse(
          envelope([paragraph([%{"type" => "pointer", "ref" => "r", "excerpt" => "ex"}])]),
          nodes: [Pointer]
        )

      assert Renderer.to_text(doc) == "[ex]"
    end
  end

  describe "to_markdown/2" do
    test "headings, emphasis, links and plain text" do
      input = [
        heading("h2", [text("Title")]),
        paragraph([
          text("bold ", 1),
          text("it", 2),
          text(" "),
          text("gone", 4),
          text(" "),
          text("a`b", 16),
          text(" "),
          link("https://a.b/x y", [text("link")]),
          text(" and *stars* "),
          text("under", 8)
        ])
      ]

      assert input |> doc() |> Renderer.to_markdown() ==
               "## Title\n\n**bold** *it* ~~gone~~ ``a`b`` [link](<https://a.b/x y>) and \\*stars\\* under"
    end

    test "lists" do
      input = [
        list("bullet", [
          item([text("a"), list("number", [item([text("a1")]), item([text("a2")])])])
        ]),
        list("number", [item([text("x")]), item([text("y")])], %{"start" => 3}),
        list("check", [
          item([text("done")], %{"checked" => true}),
          item([text("todo")], %{"checked" => false})
        ])
      ]

      assert input |> doc() |> Renderer.to_markdown() ==
               "- a\n  1. a1\n  2. a2\n\n3. x\n4. y\n\n- [x] done\n- [ ] todo"
    end

    test "code fences" do
      input = [
        code([highlight("IO.puts(1)"), linebreak(), highlight("```")], "elixir"),
        code([highlight("plain")])
      ]

      assert input |> doc() |> Renderer.to_markdown() ==
               "````elixir\nIO.puts(1)\n```\n````\n\n```\nplain\n```"
    end

    test "quotes, rules, attachments, mentions and unknown nodes" do
      input = [
        quote_block([text("q"), linebreak(), text("r")]),
        hr(),
        attachment(),
        attachment(%{"contentType" => "application/pdf", "name" => "a.pdf", "url" => "/a.pdf"}),
        paragraph([mention("people", "1", "Ada"), unknown("x-chip")]),
        unknown("x-chart")
      ]

      assert input |> doc() |> Renderer.to_markdown() ==
               "> q  \n> r\n\n---\n\n![cat.png](/uploads/k/cat.png)\n\n[a.pdf](/a.pdf)\n\nAda"
    end

    test ":untrusted gives the text of links and the name of attachments" do
      input = [paragraph([link("https://a.b", [text("site")])]), attachment()]
      assert input |> doc() |> Renderer.to_markdown(policy: :untrusted) == "site\n\ncat.png"
    end

    test "a javascript: link gives its text" do
      input = [paragraph([link("javascript:alert(1)", [text("x")])])]
      assert input |> doc() |> Renderer.to_markdown() == "x"
    end

    test "an entity-encoded javascript: link gives its text, not a link" do
      # A CommonMark renderer decodes entities in a destination: the output
      # must never be "[x](javascript&#58;alert%281%29)".
      for url <- [
            "javascript&#58;alert(1)",
            "javascript&colon;alert(1)",
            "JaVaScRiPt&#x3A;alert(1)",
            "javascript&#58alert(1)"
          ] do
        input = [paragraph([link(url, [text("x")])])]
        markdown = input |> doc() |> Renderer.to_markdown()

        assert markdown == "x", "#{url} gave #{inspect(markdown)}"
        refute markdown =~ "javascript"
      end
    end

    test "an attachment with an entity-encoded javascript: URL gives its name" do
      for url <- ["javascript&#58;alert(1)", "javascript&colon;alert(1)"] do
        input = [
          attachment(%{"url" => url}),
          attachment(%{"contentType" => "application/pdf", "name" => "a.pdf", "url" => url})
        ]

        assert input |> doc() |> Renderer.to_markdown() == "cat.png\n\na.pdf"
      end
    end

    test "&, < and > in a link or image destination get a backslash" do
      input = [
        paragraph([link("/search?a=1&b=<2>&amp;c", [text("s")])]),
        attachment(%{"url" => "/uploads/k/cat.png?v=1&#38;w=2"})
      ]

      assert input |> doc() |> Renderer.to_markdown() ==
               "[s](/search?a=1\\&b=\\<2\\>\\&amp;c)\n\n![cat.png](/uploads/k/cat.png?v=1\\&#38;w=2)"
    end

    test "& in text gets a backslash, so an entity reads as text" do
      input = [paragraph([text("a &lt; b & c &#58;")])]
      assert input |> doc() |> Renderer.to_markdown() == "a \\&lt; b \\& c \\&#58;"
    end

    test "a custom element node gives its render_markdown/2" do
      {:ok, doc} =
        Kotoba.Document.parse(envelope([element("panel", [paragraph([text("in")])])]),
          nodes: [Panel]
        )

      assert Renderer.to_markdown(doc) == "::: in"
    end
  end

  describe "escape_markdown/1" do
    test "escapes the block syntax at the start of a line" do
      cases = [
        {"# not a heading", "\\# not a heading"},
        {"### three", "\\### three"},
        {"> not a quote", "\\> not a quote"},
        {">x", "\\>x"},
        {"- not an item", "\\- not an item"},
        {"+ not an item", "\\+ not an item"},
        {"* not an item", "\\* not an item"},
        {"1. not an item", "1\\. not an item"},
        {"12) not an item", "12\\) not an item"},
        {"```elixir", "\\`\\`\\`elixir"},
        {"~~~", "\\~\\~\\~"},
        {"---", "\\---"},
        {"===", "\\==="},
        {"  # indented", "  \\# indented"},
        {"a\n# b\n1. c", "a\n\\# b\n1\\. c"}
      ]

      for {text, escaped} <- cases do
        assert Renderer.escape_markdown(text) == escaped, "escape_markdown(#{inspect(text)})"
      end
    end

    test "keeps the same characters inside a line and where they are not syntax" do
      for text <- [
            "a # b",
            "a - b",
            "a > b",
            "no. 1",
            "#hashtag",
            "-5 degrees",
            "2024 was",
            "1.5 m"
          ] do
        assert Renderer.escape_markdown(text) == text, "escape_markdown(#{inspect(text)})"
      end
    end

    test "block syntax in the text of a paragraph and of a list item stays text" do
      input = [
        paragraph([text("# not a heading")]),
        paragraph([text("1. not a list")]),
        list("bullet", [item([text("> not a quote")])])
      ]

      assert input |> doc() |> Renderer.to_markdown() ==
               "\\# not a heading\n\n1\\. not a list\n\n- \\> not a quote"
    end
  end

  test "tag/3 escapes a string and keeps safe content" do
    assert Renderer.tag("b", [], {:safe, "<i>x</i>"}) |> Phoenix.HTML.safe_to_string() ==
             "<b><i>x</i></b>"

    assert Renderer.tag("b", [hidden: true, id: 1], "<x>") |> Phoenix.HTML.safe_to_string() ==
             ~s(<b hidden id="1">&lt;x&gt;</b>)
  end
end
