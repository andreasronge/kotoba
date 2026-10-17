defmodule Kotoba.Nodes.Table do
  @moduledoc """
  A table (Lexical type `"table"`).

  The children are `Kotoba.Nodes.TableRow` nodes, and a table is valid only
  under the root. The editor's layout keys (`colWidths`, `rowStriping`,
  `frozenColumnCount`, `frozenRowCount`) stay in `extra`: `to_json/1`
  writes them back, and the renderers do not use them.

  In HTML, the table is in a `div.kotoba-table-scroll` (a wide table
  scrolls in it, as in the editor), a first row of header cells goes in a
  `thead`, and the other rows in a `tbody`. In Markdown, the table is a GitHub Flavored Markdown
  table: the first row is its header row when it is made of header cells,
  and the header row is empty otherwise. Markdown has no merged cells and
  no blocks in a cell, so the Markdown of such a table is lossy: see
  `Kotoba.Nodes.TableCell`.
  """
  use Kotoba.Node, type: "table", kind: :block, element: true

  alias Kotoba.Nodes.{TableCell, TableRow}
  alias Kotoba.Renderer

  @impl Kotoba.Node
  def render_html(node, opts) do
    {head, body} = split_header(node)

    # The editor puts a wide table in a box that scrolls, and so does the
    # HTML: the page does not.
    {:safe, thead} =
      if head != [],
        do: Renderer.tag("thead", [], Renderer.html_children(%{node | children: head}, opts)),
        else: {:safe, ""}

    {:safe, tbody} =
      Renderer.tag("tbody", [], Renderer.html_children(%{node | children: body}, opts))

    Renderer.tag(
      "div",
      [class: "kotoba-table-scroll"],
      Renderer.tag("table", [class: "kotoba-table"], {:safe, [thead, tbody]})
    )
  end

  @impl Kotoba.Node
  def render_text(node, opts), do: Renderer.text_children(node, opts)

  @impl Kotoba.Node
  def render_markdown(node, opts) do
    {head, _body} = split_header(node)
    rows = node |> Renderer.markdown_each(opts) |> Enum.map(&row_cells/1)
    columns = rows |> Enum.map(&length/1) |> Enum.max(fn -> 0 end) |> max(1)

    {header, rows} =
      case {head, rows} do
        {[_row], [cells | rest]} -> {cells, rest}
        {[], rows} -> {[], rows}
      end

    [markdown_row(header, columns), separator(node, columns)]
    |> Kernel.++(Enum.map(rows, &markdown_row(&1, columns)))
    |> Enum.join("\n")
  end

  # The markdown of a row is its cells, as `TableRow.render_markdown/2`
  # joins them with a tab, which no cell has (see `TableCell`).
  defp row_cells({%TableRow{}, markdown}) when markdown != "", do: String.split(markdown, "\t")
  defp row_cells(_other), do: []

  # The alignment of each column is the alignment of its cell in the first
  # row (see `TableCell.align/1`).
  defp separator(node, columns) do
    aligns =
      case node.children do
        [%TableRow{children: cells} | _rest] -> Enum.map(cells, &TableCell.align/1)
        _other -> []
      end

    aligns
    |> Kernel.++(List.duplicate(nil, columns))
    |> Enum.take(columns)
    |> Enum.map_join(fn
      "left" -> " :-- |"
      "center" -> " :-: |"
      "right" -> " --: |"
      nil -> " --- |"
    end)
    |> then(&("|" <> &1))
  end

  defp markdown_row(cells, columns) do
    cells = cells ++ List.duplicate("", columns - length(cells))
    "| " <> Enum.join(cells, " | ") <> " |"
  end

  @doc """
  Splits the rows of a table into the header row and the body rows. The
  first row is a header row when it has cells and all of them are header
  cells of a row (`headerState` 1 or 3).
  """
  @spec split_header(t()) :: {[Kotoba.Node.t()], [Kotoba.Node.t()]}
  def split_header(%{children: [%TableRow{children: [_ | _] = cells} = first | rest]} = node) do
    if Enum.all?(cells, &TableCell.column_header?/1),
      do: {[first], rest},
      else: {[], node.children}
  end

  def split_header(%{children: children}), do: {[], children}
end
