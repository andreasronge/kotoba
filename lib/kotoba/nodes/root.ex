defmodule Kotoba.Nodes.Root do
  @moduledoc """
  The root node of a document (Lexical type `"root"`).

  A document has one root node, at the top. Its children are block nodes.

  In HTML, the footnotes of the document (`Kotoba.Nodes.FootnoteDefinition`)
  come after the other blocks, in one `section.kotoba-footnotes` list.
  """
  use Kotoba.Node, type: "root", kind: :block, element: true

  alias Kotoba.Nodes.FootnoteDefinition
  alias Kotoba.Renderer

  @impl Kotoba.Node
  def render_html(node, opts) do
    case Enum.split_with(node.children, &is_struct(&1, FootnoteDefinition)) do
      {[], _blocks} ->
        Renderer.html_children(node, opts)

      {notes, blocks} ->
        numbers = Keyword.get(opts, :footnotes, %{})
        notes = Enum.sort_by(notes, &Map.get(numbers, &1.label, :unreferenced))
        {:safe, body} = Renderer.html_children(%{node | children: blocks}, opts)
        list = Renderer.tag("ol", [], Renderer.html_children(%{node | children: notes}, opts))
        {:safe, section} = Renderer.tag("section", [class: "kotoba-footnotes"], list)
        {:safe, [body, section]}
    end
  end

  @impl Kotoba.Node
  def render_text(node, opts), do: Renderer.text_children(node, opts)

  @impl Kotoba.Node
  def render_markdown(node, opts), do: Renderer.markdown_children(node, opts)
end
