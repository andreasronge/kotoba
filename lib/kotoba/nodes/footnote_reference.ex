defmodule Kotoba.Nodes.FootnoteReference do
  @moduledoc """
  A reference to a footnote, in the text (type `"footnotereference"`):
  Markdown's `[^label]`. The JSON key is `label`, the label of the
  `Kotoba.Nodes.FootnoteDefinition` that it refers to.

  In HTML, a reference is the number of its footnote, in a `sup`, linked to
  the footnote. Footnotes are numbered in the order of their first
  reference. In plain text and in Markdown, it is `[^label]`.
  """
  use Kotoba.Node, type: "footnotereference", kind: :decorator

  alias Kotoba.{Markdown, Renderer}
  alias Kotoba.Nodes.FootnoteDefinition

  field :label, :string, required: true

  @impl Kotoba.Node
  def render_html(node, opts) do
    number = opts |> Keyword.get(:footnotes, %{}) |> Map.get(node.label)

    Renderer.tag(
      "sup",
      [class: "kotoba-footnote-ref"],
      Renderer.tag(
        "a",
        [href: "#" <> FootnoteDefinition.id(node.label)],
        to_string(number || node.label)
      )
    )
  end

  @impl Kotoba.Node
  def render_text(node, _opts), do: "[^" <> node.label <> "]"

  @impl Kotoba.Node
  def render_markdown(node, _opts), do: "[^" <> Markdown.footnote_label(node.label) <> "]"
end
