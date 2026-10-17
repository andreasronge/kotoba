defmodule Kotoba.Nodes.TableCell do
  @moduledoc """
  A cell of a table (Lexical type `"tablecell"`).

  `header_state` (`"headerState"`) is a set of bits: `0` for a data cell,
  `1` for a cell of the header row, `2` for a cell of the header column,
  and `3` for both. A header cell renders as `th`, with `scope="col"` in
  the header row and `scope="row"` in the header column; a data cell
  renders as `td`. `col_span` and `row_span` (`"colSpan"` and `"rowSpan"`)
  are at least 1, and at most 1000. The editor's `backgroundColor`,
  `width` and `verticalAlign` keys stay in `extra`, and the renderers do
  not use them.

  A cell is valid only in a `Kotoba.Nodes.TableRow`. It holds blocks
  (paragraphs, headings, quotes, lists, code blocks, horizontal rules and
  attachments) and inline nodes, but no table.

  In plain text, the cells of a row are separated by a tab, and a cell
  keeps its text as it is (a cell with two blocks has two lines). In
  Markdown, a cell is one line: its line breaks become `<br>`, a tab
  becomes a space, and `|` is escaped.
  """
  use Kotoba.Node, type: "tablecell", kind: :block, element: true

  alias Kotoba.Renderer

  @max_span 1000

  field :header_state, :integer, key: "headerState", required: true, default: 0, in: [0, 1, 2, 3]
  field :col_span, :integer, key: "colSpan", required: true, default: 1
  field :row_span, :integer, key: "rowSpan", required: true, default: 1

  @impl Kotoba.Node
  def validate(node) do
    errors =
      for {key, value} <- [{"colSpan", node.col_span}, {"rowSpan", node.row_span}],
          is_integer(value) and (value < 1 or value > @max_span),
          do: "#{key} must be from 1 to #{@max_span}"

    case {super(node), errors} do
      {:ok, []} -> :ok
      {:ok, errors} -> {:error, errors}
      {{:error, messages}, errors} -> {:error, messages ++ errors}
    end
  end

  @impl Kotoba.Node
  def render_html(node, opts) do
    {tag, scope} =
      cond do
        column_header?(node) -> {"th", "col"}
        row_header?(node) -> {"th", "row"}
        true -> {"td", nil}
      end

    attrs = [
      scope: scope,
      class: if(align = align(node), do: "kotoba-align-" <> align),
      colspan: if(node.col_span > 1, do: node.col_span),
      rowspan: if(node.row_span > 1, do: node.row_span)
    ]

    Renderer.tag(tag, attrs, Renderer.html_children(node, opts))
  end

  @impl Kotoba.Node
  def render_text(node, opts), do: Renderer.text_children(node, opts)

  @impl Kotoba.Node
  def render_markdown(node, opts) do
    node
    |> Renderer.markdown_children(opts, "\n")
    |> String.replace("\t", " ")
    |> String.replace("|", "\\|")
    |> String.replace(~r/ *\n/, "<br>")
  end

  @doc """
  Returns the alignment of the cell, `"left"`, `"center"` or `"right"`, or
  `nil`: the alignment (`format`) of its first paragraph, as the editor
  sets it. `"start"` and `"end"` are `"left"` and `"right"`.
  """
  @spec align(t()) :: String.t() | nil
  def align(%{children: [%{format: format} | _rest]}) when is_binary(format) do
    case format do
      format when format in ["left", "start"] -> "left"
      "center" -> "center"
      format when format in ["right", "end"] -> "right"
      _other -> nil
    end
  end

  def align(_node), do: nil

  @doc "Returns `true` for a cell of the header row (`headerState` 1 or 3)."
  @spec column_header?(t()) :: boolean()
  def column_header?(%{header_state: state}) when is_integer(state),
    do: Bitwise.band(state, 1) == 1

  def column_header?(_node), do: false

  @doc "Returns `true` for a cell of the header column (`headerState` 2 or 3)."
  @spec row_header?(t()) :: boolean()
  def row_header?(%{header_state: state}) when is_integer(state),
    do: Bitwise.band(state, 2) == 2

  def row_header?(_node), do: false
end
