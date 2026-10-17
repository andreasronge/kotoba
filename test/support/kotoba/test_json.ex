defmodule Kotoba.TestJSON do
  @moduledoc """
  Builders of node JSON in the shape that Lexical 0.51 writes, for tests.
  """

  alias Kotoba.Document

  def doc(children) do
    {:ok, doc} = Document.parse(envelope(children))
    doc
  end

  def envelope(children), do: %{"kotoba" => 1, "lexical" => "0.51", "root" => root(children)}

  def root(children), do: element("root", children)

  def paragraph(children),
    do: element("paragraph", children, %{"textFormat" => 0, "textStyle" => ""})

  def heading(tag, children), do: element("heading", children, %{"tag" => tag})

  def quote_block(children), do: element("quote", children)

  def list(list_type, items, attrs \\ %{}) do
    tag = if list_type == "number", do: "ol", else: "ul"

    element(
      "list",
      items,
      Map.merge(%{"listType" => list_type, "start" => 1, "tag" => tag}, attrs)
    )
  end

  def item(children, attrs \\ %{}),
    do: element("listitem", children, Map.merge(%{"value" => 1}, attrs))

  def code(children, language \\ nil) do
    json = element("code", children)
    if language, do: Map.put(json, "language", language), else: json
  end

  def highlight(text, type \\ nil) do
    json = text |> text() |> Map.put("type", "code-highlight")
    if type, do: Map.put(json, "highlightType", type), else: json
  end

  def text(value, format \\ 0) do
    %{
      "detail" => 0,
      "format" => format,
      "mode" => "normal",
      "style" => "",
      "text" => value,
      "type" => "text",
      "version" => 1
    }
  end

  def linebreak, do: %{"type" => "linebreak", "version" => 1}

  def tab do
    %{
      "detail" => 2,
      "format" => 0,
      "mode" => "normal",
      "style" => "",
      "text" => "\t",
      "type" => "tab",
      "version" => 1
    }
  end

  def hr, do: %{"type" => "horizontalrule", "version" => 1}

  def link(url, children, attrs \\ %{}) do
    element(
      "link",
      children,
      Map.merge(%{"url" => url, "rel" => nil, "target" => nil, "title" => nil}, attrs)
    )
  end

  def autolink(url, children, attrs \\ %{}) do
    url
    |> link(children, attrs)
    |> Map.merge(%{"type" => "autolink", "isUnlinked" => false})
    |> Map.merge(attrs)
  end

  def mention(kind, id, label) do
    %{"type" => "mention", "version" => 1, "kind" => kind, "id" => id, "label" => label}
  end

  def image(url, alt \\ "", attrs \\ %{}) do
    Map.merge(%{"type" => "image", "version" => 1, "url" => url, "alt" => alt}, attrs)
  end

  def footnote_reference(label),
    do: %{"type" => "footnotereference", "version" => 1, "label" => label}

  def footnote_definition(label, children),
    do: element("footnotedefinition", children, %{"label" => label})

  def attachment(attrs \\ %{}) do
    Map.merge(
      %{
        "type" => "attachment",
        "version" => 1,
        "key" => "k/cat.png",
        "url" => "/uploads/k/cat.png",
        "name" => "cat.png",
        "contentType" => "image/png",
        "bytes" => 2048,
        "width" => 640,
        "height" => 480
      },
      attrs
    )
  end

  def table(rows, attrs \\ %{}), do: element("table", rows, attrs)

  def table_row(cells), do: element("tablerow", cells)

  @doc "A cell with `headerState` 0 (data), 1 (header row), 2 (header column) or 3."
  def table_cell(children, header_state \\ 0, attrs \\ %{}) do
    element(
      "tablecell",
      children,
      Map.merge(
        %{
          "backgroundColor" => nil,
          "colSpan" => 1,
          "headerState" => header_state,
          "rowSpan" => 1
        },
        attrs
      )
    )
  end

  def gallery(attachments), do: element("gallery", attachments)

  def unknown(type), do: %{"type" => type, "version" => 1, "children" => [text("hidden")]}

  def element(type, children, attrs \\ %{}) do
    Map.merge(
      %{
        "children" => children,
        "direction" => nil,
        "format" => "",
        "indent" => 0,
        "type" => type,
        "version" => 1
      },
      attrs
    )
  end
end
