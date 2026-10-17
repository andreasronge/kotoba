defmodule Kotoba.Nodes.Quote do
  @moduledoc """
  A block quote (Lexical type `"quote"`).

  A quote holds inline content. With `shadow_root` (`"shadowRoot": true`,
  Lexical's own opt-in), it holds blocks instead: paragraphs, headings,
  lists, code blocks, tables, horizontal rules and other quotes, as a
  Markdown quote can.
  """
  use Kotoba.Node, type: "quote", kind: :block, element: true

  alias Kotoba.Renderer

  field :shadow_root, :boolean, key: "shadowRoot", omit_nil: true

  @impl Kotoba.Node
  def render_html(node, opts),
    do: Renderer.tag("blockquote", [], Renderer.html_children(node, opts))

  @impl Kotoba.Node
  def render_text(node, opts), do: Renderer.text_children(node, opts)

  @impl Kotoba.Node
  def render_markdown(node, opts) do
    node
    |> Renderer.markdown_children(opts)
    |> String.split("\n")
    |> Enum.map_join("\n", &if(&1 == "", do: ">", else: "> " <> &1))
  end
end
