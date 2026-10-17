defmodule Kotoba.Nodes.Link do
  @moduledoc """
  A link (Lexical type `"link"`). Its children are inline nodes.

  `rel`, `target` and `title` can be `nil`.

  In HTML, a link is an `a` element with `rel="noopener nofollow"`. It has
  `target="_blank"` only when `target` is `"_blank"`, and a `title` when
  `title` is set. When `Kotoba.Sanitizer.link_url/2` refuses the URL, or
  when the policy renders no links, only the children are rendered.
  """
  use Kotoba.Node, type: "link", kind: :inline, element: true

  alias Kotoba.{Markdown, Renderer, Sanitizer}

  field :url, :string, required: true
  field :rel, :string
  field :target, :string
  field :title, :string

  @impl Kotoba.Node
  def render_html(node, opts), do: html(node, opts)

  @impl Kotoba.Node
  def render_text(node, opts), do: Renderer.text_children(node, opts)

  @impl Kotoba.Node
  def render_markdown(node, opts), do: markdown(node, opts)

  @doc false
  @spec href(struct(), keyword()) :: String.t() | nil
  def href(node, opts) do
    if Renderer.policy(opts).links and not Map.get(node, :is_unlinked, false),
      do: Sanitizer.link_url(node.url, opts)
  end

  @doc false
  @spec html(struct(), keyword()) :: Phoenix.HTML.safe()
  def html(node, opts) do
    children = Renderer.html_children(node, opts)

    case href(node, opts) do
      nil ->
        children

      href ->
        target = if node.target == "_blank", do: "_blank"
        attrs = [href: href, rel: "noopener nofollow", target: target, title: node.title]
        Renderer.tag("a", attrs, children)
    end
  end

  @doc false
  @spec markdown(struct(), keyword()) :: String.t()
  def markdown(node, opts) do
    text = Renderer.markdown_children(node, opts)

    with href when is_binary(href) <- href(node, opts),
         destination when is_binary(destination) <- Markdown.destination(href) do
      "[" <> text <> "](" <> destination <> Markdown.title(Map.get(node, :title)) <> ")"
    else
      nil -> text
    end
  end
end
