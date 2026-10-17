defmodule Kotoba.Nodes.Image do
  @moduledoc """
  An image from a URL, in the text (type `"image"`): Markdown's
  `![alt](url "title")`. The JSON keys are `url`, `alt` and `title`.

  An image that a person uploads is a `Kotoba.Nodes.Attachment`; this node
  is the image of Markdown, a URL that the document links to.

  The URL is checked with `Kotoba.Sanitizer.link_url/2`. An image with a URL
  that is not safe, or under the `:untrusted` policy (which loads no file
  from a URL), renders as its alternative text.
  """
  use Kotoba.Node, type: "image", kind: :decorator

  alias Kotoba.{Markdown, Renderer, Sanitizer}

  field :url, :string, required: true
  field :alt, :string, default: ""
  field :title, :string, omit_nil: true

  @impl Kotoba.Node
  def render_html(node, opts) do
    case src(node, opts) do
      nil ->
        node.alt

      src ->
        Renderer.tag(
          "img",
          [class: "kotoba-image", src: src, alt: node.alt, title: node.title, loading: "lazy"],
          :void
        )
    end
  end

  @impl Kotoba.Node
  def render_text(node, _opts), do: node.alt

  @impl Kotoba.Node
  def render_markdown(node, opts) do
    destination = Markdown.destination(node.url)

    if src(node, opts) == nil or destination == nil,
      do: Markdown.escape(node.alt),
      else:
        "![" <>
          Markdown.escape(node.alt) <> "](" <> destination <> Markdown.title(node.title) <> ")"
  end

  defp src(node, opts) do
    if Renderer.policy(opts).attachments, do: Sanitizer.link_url(node.url, opts)
  end
end
