defmodule Kotoba.Nodes.Text do
  @moduledoc """
  A run of text (Lexical type `"text"`).

  `format` is a bitmask of text formats. Use `formats/1` and `format?/2` to
  read it:

  | Format           | Bit   |
  | ---------------- | ----- |
  | `:bold`          | `1`   |
  | `:italic`        | `2`   |
  | `:strikethrough` | `4`   |
  | `:underline`     | `8`   |
  | `:code`          | `16`  |
  | `:subscript`     | `32`  |
  | `:superscript`   | `64`  |
  | `:highlight`     | `128` |
  | `:lowercase`     | `256` |
  | `:uppercase`     | `512` |
  | `:capitalize`    | `1024` |

  In HTML, the formats become `strong`, `em`, `s`, `u`, `code`, `sub`,
  `sup` and `mark`, and the three text transforms become `span` elements
  with the classes `kotoba-lowercase`, `kotoba-uppercase` and
  `kotoba-capitalize`. The `style` of the run is not rendered, but for its
  colors (see `colors/1`).

  ## Colors

  A run has a text color and a highlight color from a palette (the
  `highlight` feature of `Kotoba.Features`): `red`, `orange`, `yellow`,
  `green`, `blue`, `purple` and `gray` (`palette/0`). The editor stores them
  in the `style`, as the custom properties of the theme:

      color: var(--kotoba-color-red);background-color: var(--kotoba-highlight-green);

  A highlight color goes with the `:highlight` format. The format with no
  color is the default highlight, `yellow`. In HTML, a text color is a
  `span` with the class `kotoba-color-<name>`, and a highlight color is the
  class `kotoba-highlight-<name>` of the `mark` (the default highlight is a
  `mark` with no class). Any other `style` is ignored: a color that is not
  in the palette, or a declaration that is not one of these two, renders
  nothing. `kotoba.css` has the classes.

  `mode` is `"normal"`, `"token"` or `"segmented"`. `detail` is a bitmask
  that Lexical uses for special characters. `style` is an inline CSS text
  that Lexical keeps for the run.
  """
  use Kotoba.Node, type: "text", kind: :inline

  import Bitwise

  alias Kotoba.{Markdown, Renderer}

  field :text, :string, required: true
  field :format, :integer, default: 0
  field :style, :string, default: ""
  field :mode, :string, default: "normal", in: ~w(normal token segmented)
  field :detail, :integer, default: 0

  @typedoc "A text format."
  @type format ::
          :bold
          | :italic
          | :strikethrough
          | :underline
          | :code
          | :subscript
          | :superscript
          | :highlight
          | :lowercase
          | :uppercase
          | :capitalize

  @formats [
    bold: 1,
    italic: 2,
    strikethrough: 4,
    underline: 8,
    code: 16,
    subscript: 32,
    superscript: 64,
    highlight: 128,
    lowercase: 256,
    uppercase: 512,
    capitalize: 1024
  ]

  @doc """
  Returns the formats that are set in a format bitmask, or in the bitmask of
  a text node.

  ## Examples

      iex> Kotoba.Nodes.Text.formats(3)
      [:bold, :italic]

      iex> Kotoba.Nodes.Text.formats(%Kotoba.Nodes.Text{text: "x", format: 16})
      [:code]

  """
  @spec formats(integer() | %{:format => integer(), optional(atom()) => term()}) :: [format()]
  def formats(%{format: bitmask}), do: formats(bitmask)

  def formats(bitmask) when is_integer(bitmask),
    do: for({name, bit} <- @formats, (bitmask &&& bit) != 0, do: name)

  @doc """
  Returns `true` when the format is set in a format bitmask, or in the
  bitmask of a text node.

  ## Examples

      iex> Kotoba.Nodes.Text.format?(1, :bold)
      true

      iex> Kotoba.Nodes.Text.format?(1, :italic)
      false

  """
  @spec format?(integer() | %{format: integer()}, format()) :: boolean()
  def format?(%{format: bitmask}, format), do: format?(bitmask, format)

  def format?(bitmask, format) when is_integer(bitmask),
    do: (bitmask &&& Keyword.fetch!(@formats, format)) != 0

  @doc """
  Returns the format bitmask for a list of formats.

  ## Examples

      iex> Kotoba.Nodes.Text.bitmask([:bold, :code])
      17

  """
  @spec bitmask([format()]) :: non_neg_integer()
  def bitmask(formats) when is_list(formats) do
    formats |> Enum.map(&Keyword.fetch!(@formats, &1)) |> Enum.reduce(0, &bor/2)
  end

  @html [
    bold: {"strong", nil},
    italic: {"em", nil},
    strikethrough: {"s", nil},
    underline: {"u", nil},
    code: {"code", nil},
    subscript: {"sub", nil},
    superscript: {"sup", nil},
    highlight: {"mark", nil},
    lowercase: {"span", "kotoba-lowercase"},
    uppercase: {"span", "kotoba-uppercase"},
    capitalize: {"span", "kotoba-capitalize"}
  ]

  @markdown [bold: "**", italic: "*", strikethrough: "~~"]

  @colors ~w(red orange yellow green blue purple gray)
  @default_highlight "yellow"

  @doc """
  Returns the names of the palette, in order.

  ## Examples

      iex> "green" in Kotoba.Nodes.Text.palette()
      true

  """
  @spec palette() :: [String.t()]
  def palette, do: @colors

  @doc """
  Returns the colors of a text node: its text color and its highlight
  color, each a name of `palette/0` or `nil`.

  The highlight color is `nil` without the `:highlight` format, and
  `"yellow"` (the default) for the format with no color.

  ## Examples

      iex> Kotoba.Nodes.Text.colors(%Kotoba.Nodes.Text{
      ...>   text: "x",
      ...>   format: 128,
      ...>   style: "color: var(--kotoba-color-red);background-color: var(--kotoba-highlight-green);"
      ...> })
      %{text: "red", highlight: "green"}

      iex> Kotoba.Nodes.Text.colors(%Kotoba.Nodes.Text{text: "x", format: 128, style: "color: red"})
      %{text: nil, highlight: "yellow"}

  """
  @spec colors(%{
          :format => integer(),
          :style => String.t() | nil,
          optional(atom()) => any()
        }) :: %{
          text: String.t() | nil,
          highlight: String.t() | nil
        }
  def colors(%{format: format, style: style}) do
    declarations = declarations(style)

    highlight =
      if format?(format, :highlight),
        do: color(declarations["background-color"], "highlight") || @default_highlight

    %{text: color(declarations["color"], "color"), highlight: highlight}
  end

  # The declarations of a CSS text, the last one of a property winning.
  defp declarations(style) when is_binary(style) do
    style
    |> String.split(";")
    |> Enum.reduce(%{}, fn part, acc ->
      case String.split(part, ":", parts: 2) do
        [property, value] ->
          Map.put(acc, property |> String.trim() |> String.downcase(), String.trim(value))

        _other ->
          acc
      end
    end)
  end

  defp declarations(_style), do: %{}

  @color_value %{
    "color" => ~r/\Avar\(--kotoba-color-([a-z]+)\)\z/,
    "highlight" => ~r/\Avar\(--kotoba-highlight-([a-z]+)\)\z/
  }

  defp color(nil, _kind), do: nil

  defp color(value, kind) do
    case Regex.run(Map.fetch!(@color_value, kind), value, capture: :all_but_first) do
      [name] when name in @colors -> name
      _other -> nil
    end
  end

  @impl Kotoba.Node
  def render_html(%{text: ""}, _opts), do: {:safe, ""}

  def render_html(node, _opts) do
    colors = colors(node)

    inner =
      node.format
      |> formats()
      |> Enum.reverse()
      |> Enum.reduce(Phoenix.HTML.html_escape(node.text), fn format, inner ->
        {tag, class} = Keyword.fetch!(@html, format)
        Renderer.tag(tag, [class: class || highlight_class(format, colors.highlight)], inner)
      end)

    case colors.text do
      nil -> inner
      name -> Renderer.tag("span", [class: "kotoba-color-" <> name], inner)
    end
  end

  defp highlight_class(:highlight, name) when name not in [nil, @default_highlight],
    do: "kotoba-highlight-" <> name

  defp highlight_class(_format, _name), do: nil

  @impl Kotoba.Node
  def render_text(node, _opts), do: node.text

  @impl Kotoba.Node
  def render_markdown(%{text: ""}, _opts), do: ""

  def render_markdown(node, _opts) do
    formats = markdown_formats(node)

    @markdown
    |> Enum.filter(fn {format, _marker} -> format in formats end)
    |> Enum.reverse()
    |> Enum.reduce(markdown_body(node), fn {_format, marker}, inner ->
      Markdown.wrap(inner, marker)
    end)
  end

  @doc """
  Returns the formats of the text that Markdown has markers for, in the
  order of their markers: `:bold`, `:italic` and `:strikethrough`. Inline
  code is the body itself (see `markdown_body/1`).
  """
  @spec markdown_formats(t()) :: [atom()]
  def markdown_formats(node) do
    formats = formats(node)
    for {format, _marker} <- @markdown, format in formats, do: format
  end

  @doc """
  Returns the Markdown of the text with no format markers: a code span for
  inline code, else the escaped text.
  """
  @spec markdown_body(t()) :: String.t()
  def markdown_body(node) do
    if :code in formats(node),
      do: Markdown.code_span(node.text),
      else: Markdown.escape(node.text)
  end

  @doc "Returns the Markdown marker of a format of `markdown_formats/1`."
  @spec markdown_marker(atom()) :: String.t()
  def markdown_marker(format), do: Keyword.fetch!(@markdown, format)
end
