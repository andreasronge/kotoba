defmodule Kotoba.Nodes.FootnoteDefinition do
  @moduledoc """
  The text of a footnote (type `"footnotedefinition"`): Markdown's
  `[^label]: text`. The JSON key is `label`. It holds blocks, and is valid
  only under the root.

  In HTML, the footnotes of a document are one list at its end
  (`section.kotoba-footnotes`), numbered in the order of their first
  reference (see `Kotoba.Nodes.FootnoteReference`); a footnote with no
  reference comes last. In Markdown, a footnote is `[^label]:` and its
  blocks, the blocks after the first indented by four spaces.
  """
  use Kotoba.Node, type: "footnotedefinition", kind: :block, element: true

  alias Kotoba.{Markdown, Renderer}

  field :label, :string, required: true

  @impl Kotoba.Node
  def render_html(node, opts),
    do: Renderer.tag("li", [id: id(node.label)], Renderer.html_children(node, opts))

  @impl Kotoba.Node
  def render_text(node, opts),
    do: "[^" <> node.label <> "]: " <> Renderer.text_children(node, opts)

  @impl Kotoba.Node
  def render_markdown(node, opts) do
    [first | rest] = node |> Renderer.markdown_children(opts) |> String.split("\n")
    lines = Enum.map(rest, &if(&1 == "", do: "", else: "    " <> &1))
    Enum.join(["[^" <> Markdown.footnote_label(node.label) <> "]: " <> first | lines], "\n")
  end

  @doc """
  Returns the HTML `id` of the footnote with `label`.

  ## Examples

      iex> Kotoba.Nodes.FootnoteDefinition.id("my note")
      "kotoba-fn-my-note"

  """
  @spec id(String.t()) :: String.t()
  def id(label), do: "kotoba-fn-" <> String.replace(label, ~r/\s+/u, "-")
end
