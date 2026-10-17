defmodule Kotoba.MarkdownNodesTest do
  # The nodes and the output that full Markdown brought: images, footnotes,
  # quotes of blocks, table alignment, blank lines, nested formats.
  use ExUnit.Case, async: true

  import Kotoba.TestJSON

  alias Kotoba.{Content, Document, Renderer}

  defp html(children, opts \\ []),
    do: children |> doc() |> Renderer.to_html(opts) |> Phoenix.HTML.safe_to_string()

  defp markdown(children, opts \\ []), do: children |> doc() |> Renderer.to_markdown(opts)

  defp round_trip(markdown) do
    {:ok, doc} = markdown |> Content.from_markdown() |> Map.fetch!(:doc) |> Document.parse()
    Renderer.to_markdown(doc)
  end

  defp block_quote(children), do: Map.put(quote_block(children), "shadowRoot", true)

  describe "images" do
    test "render as an img, with the alternative text and the title" do
      input = [paragraph([image("https://a.b/c.png", "A cat", %{"title" => "Cat"})])]

      assert html(input) ==
               ~s(<p><img class="kotoba-image" src="https://a.b/c.png" alt="A cat" title="Cat" loading="lazy"></p>)

      assert markdown(input) == ~s(![A cat]\(https://a.b/c.png "Cat"\))
      assert input |> doc() |> Renderer.to_text() == "A cat"
    end

    test "with a URL that is not safe, or under the untrusted policy, are their text" do
      assert html([paragraph([image("javascript:alert(1)", "x")])]) == "<p>x</p>"

      assert html([paragraph([image("https://a.b/c.png", "x")])], policy: :untrusted) ==
               "<p>x</p>"

      assert markdown([paragraph([image("javascript:alert(1)", "x")])]) == "x"
    end
  end

  describe "footnotes" do
    test "are numbered in the order of their first reference, in a list at the end" do
      input = [
        footnote_definition("b", [paragraph([text("Note B")])]),
        paragraph([text("One"), footnote_reference("a"), text(" two"), footnote_reference("b")]),
        footnote_definition("a", [paragraph([text("Note A")])])
      ]

      assert html(input) ==
               ~s(<p>One<sup class="kotoba-footnote-ref"><a href="#kotoba-fn-a">1</a></sup> two) <>
                 ~s(<sup class="kotoba-footnote-ref"><a href="#kotoba-fn-b">2</a></sup></p>) <>
                 ~s(<section class="kotoba-footnotes"><ol>) <>
                 ~s(<li id="kotoba-fn-a"><p>Note A</p></li><li id="kotoba-fn-b"><p>Note B</p></li>) <>
                 "</ol></section>"
    end

    test "read and write as Markdown" do
      markdown = "Text[^note]\n\n[^note]: The note\n\n    and more."
      assert round_trip(markdown) == markdown
    end

    test "are valid only under the root" do
      assert html([block_quote([footnote_definition("a", [paragraph([text("x")])])])]) =~
               ~s(<span class="kotoba-unknown" data-type="footnotedefinition">)
    end
  end

  describe "quotes of blocks" do
    test "hold paragraphs, lists, code and other quotes" do
      input = [
        block_quote([
          paragraph([text("Steps:")]),
          list("bullet", [item([text("Open")]), item([text("Pick")])]),
          block_quote([paragraph([text("Inner")])])
        ])
      ]

      assert html(input) ==
               "<blockquote><p>Steps:</p><ul><li>Open</li><li>Pick</li></ul>" <>
                 "<blockquote><p>Inner</p></blockquote></blockquote>"

      assert markdown(input) == "> Steps:\n>\n> - Open\n> - Pick\n>\n> > Inner"
    end

    test "a quote of inline content holds no blocks" do
      assert html([quote_block([paragraph([text("x")])])]) =~ "kotoba-unknown"
    end
  end

  describe "tables" do
    test "keep the alignment of their columns" do
      markdown = "| a | b | c |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |"
      assert round_trip(markdown) == markdown

      assert Content.from_markdown(markdown).html =~
               ~s(<th scope="col" class="kotoba-align-right">)
    end
  end

  describe "blank lines" do
    @blank [paragraph([text("Hello")]), paragraph([]), paragraph([]), paragraph([text("World")])]

    test "keep their height in HTML, and are &nbsp; in Markdown" do
      assert html(@blank) == "<p>Hello</p><p><br></p><p><br></p><p>World</p>"
      assert markdown(@blank) == "Hello\n\n&nbsp;\n\n&nbsp;\n\nWorld"
      assert round_trip(markdown(@blank)) == markdown(@blank)
    end

    test "at the start or the end of a document are not blank lines" do
      assert html([paragraph([]), paragraph([text("x")]), paragraph([])]) ==
               "<p></p><p>x</p><p></p>"

      assert markdown([paragraph([]), paragraph([text("x")]), paragraph([])]) == "x"
    end

    test "are left out with blank_lines: :collapse" do
      assert html(@blank, blank_lines: :collapse) == "<p>Hello</p><p>World</p>"
      assert markdown(@blank, blank_lines: :collapse) == "Hello\n\nWorld"
      assert @blank |> doc() |> Renderer.to_text(blank_lines: :collapse) == "Hello\nWorld"
    end
  end

  describe "Markdown of formats" do
    test "nested formats nest" do
      input = [paragraph([text("foo \"", 1), text("bar", 3), text("\" foo", 1)])]
      assert markdown(input) == ~s(**foo "*bar*" foo**)
    end

    test "a format that lasts longer is the outer one" do
      assert markdown([paragraph([text("foo", 3), text(" bar", 2)])]) == "***foo** bar*"
    end

    test "a format around a link goes around the link" do
      input = [paragraph([text("foo ", 1), link("/url", [text("bar", 1)])])]
      assert markdown(input) == "**foo [bar](/url)**"
    end

    test "white space stays outside the markers" do
      assert markdown([paragraph([text("a "), text(" b ", 2), text("c")])]) == "a  *b* c"
    end
  end

  describe "Markdown of lists" do
    test "two lists in a row get different markers, so they stay two lists" do
      input = [
        list("bullet", [item([text("a")])]),
        list("bullet", [item([text("b")])]),
        list("number", [item([text("c")])]),
        list("number", [item([text("d")])])
      ]

      assert markdown(input) == "- a\n\n* b\n\n1. c\n\n1) d"
    end
  end

  describe "from_markdown/2 with features" do
    test "a construct whose feature is off becomes its closest form" do
      content =
        Content.from_markdown("# Title\n\n> **quote** and ![img](https://a.b/c.png)\n\n- a\n- b",
          features: [:links]
        )

      assert content.html == "<p>Title</p><p>quote and img</p><p>a</p><p>b</p>"
    end

    test "a table with tables off is a line for each row" do
      assert Content.from_markdown("| a | b |\n|---|---|\n| 1 | 2 |", features: []).text ==
               "a\tb\n1\t2"
    end

    test "a footnote with footnotes off is its text" do
      assert Content.from_markdown("x[^1]\n\n[^1]: Note", features: []).text ==
               "x[^1]\n[^1]: Note"
    end
  end
end
