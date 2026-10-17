defmodule Kotoba.Nodes.Paragraph do
  @moduledoc """
  A paragraph (Lexical type `"paragraph"`).

  `text_format` and `text_style` are the format and the style that Lexical
  gives to new text in the paragraph.

  ## Blank lines

  An empty paragraph between other blocks (of the root, of a quote of
  blocks or of a footnote) is a blank line, as a person typed it. It keeps
  its height in HTML (`<p><br></p>`), and it is `&nbsp;` in Markdown, which
  `Kotoba.Content.from_markdown/2` reads back as an empty paragraph. An
  empty paragraph at the start or the end is not a blank line.

  The `blank_lines: :collapse` render option leaves blank lines out of the
  HTML, the text and the Markdown.
  """
  use Kotoba.Node, type: "paragraph", kind: :block, element: true

  alias Kotoba.Nodes.{FootnoteDefinition, Quote, Root, Text}
  alias Kotoba.Renderer

  field :text_format, :integer, key: "textFormat", default: 0
  field :text_style, :string, key: "textStyle", default: ""

  @impl Kotoba.Node
  def render_html(node, opts) do
    case blank_line(node, opts) do
      :keep -> Renderer.tag("p", [], Renderer.tag("br", [], :void))
      :collapse -> ""
      nil -> Renderer.tag("p", [], Renderer.html_children(node, opts))
    end
  end

  @impl Kotoba.Node
  def render_text(node, opts) do
    case blank_line(node, opts) do
      :collapse -> ""
      _other -> Renderer.text_children(node, opts)
    end
  end

  @impl Kotoba.Node
  def render_markdown(node, opts) do
    case blank_line(node, opts) do
      :keep -> "&nbsp;"
      :collapse -> ""
      nil -> Renderer.markdown_children(node, opts)
    end
  end

  @doc """
  Returns `true` when the paragraph has no content: no children, or only
  text nodes with no text.
  """
  @spec empty?(t()) :: boolean()
  # The struct is defined at the end of the module (`Kotoba.Node`), so this
  # matches the type and the children.
  def empty?(%{__struct__: __MODULE__, children: children}),
    do: Enum.all?(children, &match?(%Text{text: ""}, &1))

  def empty?(_node), do: false

  # `:keep` or `:collapse` (the `blank_lines` option) for a blank line, else
  # `nil`.
  defp blank_line(node, opts) do
    with true <- empty?(node),
         %parent{children: siblings} when parent in [Root, Quote, FootnoteDefinition] <-
           opts[:parent],
         index when is_integer(index) <- opts[:index],
         {before, [_self | rest]} = Enum.split(siblings, index),
         true <- Enum.any?(before, &(not empty?(&1))) and Enum.any?(rest, &(not empty?(&1))) do
      Keyword.get(opts, :blank_lines, :keep)
    else
      _other -> nil
    end
  end
end
