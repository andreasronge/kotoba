defmodule Kotoba.Content.MarkdownImport do
  @moduledoc false
  # Markdown to a Lexical root, for `Kotoba.Content.from_markdown/2` and
  # pasted Markdown. MDEx (comrak, a port of GitHub's cmark-gfm) parses
  # CommonMark and GitHub Flavored Markdown: tables, task lists,
  # strikethrough, autolinks and footnotes. This module maps its tree to
  # the nodes of the editor.
  #
  # Raw HTML becomes its text: Kotoba never passes HTML through.
  #
  # A construct whose feature is off becomes its closest form, with no text
  # lost: a heading becomes a paragraph, a quote its blocks, a list its
  # items as paragraphs, a code block its lines, a table one paragraph for
  # each row, an image its alternative text, a footnote its `[^label]`
  # text, and a format is dropped.
  #
  # A list item holds inline content and one nested list. In an item with
  # more than one paragraph, the paragraphs are joined with line breaks; a
  # code block, a quote, a table or a heading in an item ends the list,
  # comes after it, and the list goes on after it.

  import Bitwise

  alias Kotoba.Features

  @parse_options [
    extension: [
      strikethrough: true,
      table: true,
      autolink: true,
      tasklist: true,
      footnotes: true
    ]
  ]

  @bold 1
  @italic 2
  @strikethrough 4
  @code 16

  @doc "Returns the root node JSON for a Markdown string."
  @spec root(String.t(), keyword()) :: map()
  def root(markdown, opts \\ []) do
    features = opts |> Keyword.get(:features, Features.all()) |> Features.names!() |> MapSet.new()
    document = MDEx.parse_document!(markdown, @parse_options)
    element("root", blocks(document.nodes, features))
  end

  # -- blocks ----------------------------------------------------------------

  defp blocks(nodes, features), do: Enum.flat_map(nodes, &block(&1, features))

  # A paragraph of one non-breaking space (`&nbsp;`) is a blank line, as
  # `Kotoba.Renderer.to_markdown/2` writes it: an empty paragraph.
  defp block(%MDEx.Paragraph{nodes: nodes}, features) do
    case inline(nodes, features) do
      [%{"type" => "text", "text" => "\u00A0"}] -> [paragraph([])]
      children -> [paragraph(children)]
    end
  end

  defp block(%MDEx.Heading{level: level, nodes: nodes}, features) do
    if on?(features, :headings),
      do: [element("heading", inline(nodes, features), %{"tag" => "h#{level}"})],
      else: [paragraph(inline(nodes, features))]
  end

  defp block(%MDEx.ThematicBreak{}, features) do
    if on?(features, :horizontal_rules),
      do: [%{"type" => "horizontalrule", "version" => 1}],
      else: []
  end

  defp block(%MDEx.CodeBlock{info: info, literal: literal}, features) do
    lines = literal |> String.replace_suffix("\n", "") |> String.split("\n")

    if on?(features, :code_blocks) do
      code = element("code", lines_with_breaks(lines))

      case info |> to_string() |> String.split() do
        [language | _rest] -> [Map.put(code, "language", language)]
        [] -> [code]
      end
    else
      [paragraph(lines_with_breaks(lines))]
    end
  end

  defp block(%MDEx.HtmlBlock{literal: literal}, _features) do
    literal
    |> String.replace_suffix("\n", "")
    |> String.split("\n")
    |> lines_with_breaks()
    |> paragraph()
    |> List.wrap()
  end

  defp block(%MDEx.BlockQuote{nodes: nodes}, features) do
    if on?(features, :quotes),
      do: [element("quote", blocks(nodes, features), %{"shadowRoot" => true})],
      else: blocks(nodes, features)
  end

  defp block(%MDEx.List{} = list, features), do: list(list, features)

  defp block(%MDEx.Table{} = table, features), do: table(table, features)

  defp block(%MDEx.FootnoteDefinition{name: name, nodes: nodes}, features) do
    if on?(features, :footnotes) do
      [element("footnotedefinition", blocks(nodes, features), %{"label" => name})]
    else
      label = text_node("[^" <> name <> "]: ")

      case blocks(nodes, features) do
        [%{"type" => "paragraph"} = first | rest] ->
          [%{first | "children" => [label | first["children"]]} | rest]

        blocks ->
          [paragraph([label]) | blocks]
      end
    end
  end

  # A construct of an extension that is not on (none today) gives its text.
  defp block(%{nodes: nodes}, features), do: blocks(nodes, features)
  defp block(_node, _features), do: []

  defp lines_with_breaks(lines) do
    lines
    |> Enum.map(&if(&1 == "", do: [], else: [text_node(&1)]))
    |> Enum.intersperse([linebreak_node()])
    |> List.flatten()
  end

  # -- lists -----------------------------------------------------------------

  defp list(%MDEx.List{nodes: items} = list, features) do
    check? = Enum.all?(items, &match?(%MDEx.TaskItem{}, &1)) and on?(features, :check_lists)

    if on?(features, :lists) do
      {type, tag} =
        cond do
          check? -> {"check", "ul"}
          list.list_type == :ordered -> {"number", "ol"}
          true -> {"bullet", "ul"}
        end

      start = if type == "number", do: list.start || 1, else: 1
      build_list(items, %{type: type, tag: tag, start: start, check?: check?}, features)
    else
      Enum.flat_map(items, &item_blocks(&1, features))
    end
  end

  # The items of a list, as a list node. An item with a block that a list
  # item cannot hold ends the list: the block comes after it, and a new
  # list (numbered on) holds the next items.
  defp build_list(items, kind, features) do
    {lists, current, _number} =
      Enum.reduce(items, {[], [], kind.start}, fn item, {done, current, number} ->
        {inline, nested, after_blocks} = item_parts(item, kind, features)
        checked = if kind.check?, do: %{"checked" => item.checked}, else: %{}
        li = element("listitem", inline, Map.put(checked, "value", number))

        nested_li =
          if nested == [],
            do: [],
            else: [element("listitem", nested, %{"value" => number})]

        current = current ++ [li | nested_li]

        case after_blocks do
          [] ->
            {done, current, number + 1}

          blocks ->
            {done ++ [list_node(current, kind, number_of(current, kind))] ++ blocks, [],
             number + 1}
        end
      end)

    case current do
      [] -> lists
      items -> lists ++ [list_node(items, kind, number_of(items, kind))]
    end
  end

  defp number_of([%{"value" => value} | _rest], _kind), do: value

  defp list_node(items, kind, start) do
    element("list", items, %{
      "listType" => kind.type,
      "start" => if(kind.type == "number", do: start, else: 1),
      "tag" => kind.tag
    })
  end

  # The inline content of an item, its nested list (as the children of an
  # item of its own, as Lexical has it) and the blocks that come after the
  # list.
  defp item_parts(%{nodes: nodes} = item, kind, features) do
    prefix = task_prefix(item, kind)

    {inline, nested, after_blocks} =
      Enum.reduce(nodes, {[], [], []}, fn node, {inline, nested, after_blocks} ->
        case node do
          %MDEx.Paragraph{nodes: children} when nested == [] and after_blocks == [] ->
            {join_lines(inline, inline(children, features)), nested, after_blocks}

          # A nested list that a block split: its first part is the
          # nested list, and the rest comes after the list.
          %MDEx.List{} = list when nested == [] and after_blocks == [] ->
            [first | rest] = list(list, features)
            {inline, [first], rest}

          %MDEx.ThematicBreak{} when after_blocks == [] ->
            {inline, nested, after_blocks}

          other ->
            {inline, nested, after_blocks ++ block(other, features)}
        end
      end)

    {prefix ++ inline, nested, after_blocks}
  end

  defp task_prefix(%MDEx.TaskItem{checked: checked}, %{check?: false}),
    do: [text_node(if(checked, do: "[x] ", else: "[ ] "))]

  defp task_prefix(_item, _kind), do: []

  defp join_lines([], next), do: next
  defp join_lines(inline, next), do: inline ++ [linebreak_node() | next]

  # A list item as blocks, when lists are off.
  defp item_blocks(%{nodes: nodes} = item, features) do
    prefix = task_prefix(item, %{check?: false})

    case blocks(nodes, features) do
      [%{"type" => "paragraph"} = first | rest] ->
        [%{first | "children" => prefix ++ first["children"]} | rest]

      blocks when prefix != [] ->
        [paragraph(prefix) | blocks]

      blocks ->
        blocks
    end
  end

  # -- tables ----------------------------------------------------------------

  defp table(%MDEx.Table{nodes: rows, alignments: alignments}, features) do
    if on?(features, :tables) do
      [element("table", Enum.map(rows, &table_row(&1, alignments, features)))]
    else
      Enum.map(rows, fn %MDEx.TableRow{nodes: cells} ->
        cells
        |> Enum.map(&inline(&1.nodes, features))
        |> Enum.intersperse([
          %{
            "type" => "tab",
            "detail" => 2,
            "format" => 0,
            "mode" => "normal",
            "style" => "",
            "text" => "\t",
            "version" => 1
          }
        ])
        |> List.flatten()
        |> paragraph()
      end)
    end
  end

  defp table_row(%MDEx.TableRow{header: header, nodes: cells}, alignments, features) do
    cells
    |> Enum.with_index()
    |> Enum.map(fn {%MDEx.TableCell{nodes: nodes}, index} ->
      format = alignments |> Enum.at(index) |> align()
      cell_paragraph = Map.put(paragraph(inline(nodes, features)), "format", format)

      element("tablecell", [cell_paragraph], %{
        "headerState" => if(header, do: 1, else: 0),
        "colSpan" => 1,
        "rowSpan" => 1
      })
    end)
    |> then(&element("tablerow", &1))
  end

  defp align(alignment) when alignment in [:left, :center, :right], do: Atom.to_string(alignment)
  defp align(_alignment), do: ""

  # -- inline ----------------------------------------------------------------

  defp inline(nodes, features), do: nodes |> inline(features, 0) |> merge_text()

  defp inline(nodes, features, format) when is_list(nodes),
    do: Enum.flat_map(nodes, &inline_node(&1, features, format))

  # A line ending in text (from `&#10;`) is white space in HTML.
  defp inline_node(%MDEx.Text{literal: literal}, _features, format),
    do: [text_node(String.replace(literal, ~r/\r\n|\r|\n/, " "), format)]

  defp inline_node(%MDEx.SoftBreak{}, _features, format), do: [text_node(" ", format)]
  defp inline_node(%MDEx.LineBreak{}, _features, _format), do: [linebreak_node()]

  defp inline_node(%MDEx.HtmlInline{literal: literal}, _features, format),
    do: [text_node(literal, format)]

  defp inline_node(%MDEx.Emph{nodes: nodes}, features, format),
    do: inline(nodes, features, with_format(format, features, :italic, @italic))

  defp inline_node(%MDEx.Strong{nodes: nodes}, features, format),
    do: inline(nodes, features, with_format(format, features, :bold, @bold))

  defp inline_node(%MDEx.Strikethrough{nodes: nodes}, features, format),
    do: inline(nodes, features, with_format(format, features, :strikethrough, @strikethrough))

  defp inline_node(%MDEx.Code{literal: literal}, features, format),
    do: [text_node(literal, with_format(format, features, :inline_code, @code))]

  defp inline_node(%MDEx.Link{url: url, title: title, nodes: nodes}, features, format) do
    children = inline(nodes, features, format) |> merge_text()

    cond do
      not on?(features, :links) -> children
      children == [] -> []
      true -> [link_node(url, title, children)]
    end
  end

  defp inline_node(%MDEx.Image{url: url, title: title, nodes: nodes}, features, format) do
    alt = plain_text(nodes)

    if on?(features, :images) do
      image = %{"type" => "image", "url" => url, "alt" => alt, "version" => 1}
      [if(present?(title), do: Map.put(image, "title", title), else: image)]
    else
      if alt == "", do: [], else: [text_node(alt, format)]
    end
  end

  defp inline_node(%MDEx.FootnoteReference{name: name}, features, format) do
    if on?(features, :footnotes),
      do: [%{"type" => "footnotereference", "label" => name, "version" => 1}],
      else: [text_node("[^" <> name <> "]", format)]
  end

  defp inline_node(%{nodes: nodes}, features, format), do: inline(nodes, features, format)

  defp inline_node(%{literal: literal}, _features, format) when is_binary(literal),
    do: [text_node(literal, format)]

  defp inline_node(_node, _features, _format), do: []

  defp with_format(format, features, feature, bit),
    do: if(on?(features, feature), do: format ||| bit, else: format)

  # The text of inline nodes, for the alternative text of an image.
  defp plain_text(nodes) do
    Enum.map_join(nodes, fn
      %MDEx.Text{literal: literal} -> literal
      %MDEx.Code{literal: literal} -> literal
      %MDEx.SoftBreak{} -> " "
      %MDEx.LineBreak{} -> " "
      %{nodes: nodes} -> plain_text(nodes)
      _other -> ""
    end)
  end

  # Adjacent text nodes with the same format are one node, as Lexical
  # normalizes them.
  defp merge_text(nodes) do
    nodes
    |> Enum.reduce([], fn
      %{"type" => "text", "format" => format, "text" => text},
      [%{"type" => "text", "format" => format} = previous | rest] ->
        [%{previous | "text" => previous["text"] <> text} | rest]

      node, acc ->
        [node | acc]
    end)
    |> Enum.reverse()
  end

  defp on?(features, feature), do: MapSet.member?(features, feature)
  defp present?(value), do: value not in [nil, ""]

  # -- JSON builders -----------------------------------------------------

  defp paragraph(children),
    do: element("paragraph", children, %{"textFormat" => 0, "textStyle" => ""})

  defp element(type, children, attrs \\ %{}) do
    Map.merge(
      %{
        "type" => type,
        "children" => children,
        "direction" => nil,
        "format" => "",
        "indent" => 0,
        "version" => 1
      },
      attrs
    )
  end

  defp text_node(text, format \\ 0) do
    %{
      "type" => "text",
      "detail" => 0,
      "format" => format,
      "mode" => "normal",
      "style" => "",
      "text" => text,
      "version" => 1
    }
  end

  defp linebreak_node, do: %{"type" => "linebreak", "version" => 1}

  defp link_node(url, title, children) do
    element("link", children, %{
      "url" => url,
      "rel" => nil,
      "target" => nil,
      "title" => if(present?(title), do: String.replace(title, ~r/\s+/, " "))
    })
  end
end
