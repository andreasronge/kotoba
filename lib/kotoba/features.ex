defmodule Kotoba.Features do
  @moduledoc """
  The built-in features of the editor, and the check of a document against
  the features of a field.

  `Kotoba.Components.kotoba/1` takes a `features` list: the editor has
  those features, and no other. With no list, it has every feature.

      <.kotoba field={@form[:comment]} features={~w(bold italic links lists mentions)} />

  | Feature | What it is | Nodes and formats |
  | ------- | ---------- | ----------------- |
  | `bold` | bold text | the `bold` format |
  | `italic` | italic text | the `italic` format |
  | `underline` | underlined text | the `underline` format |
  | `strikethrough` | struck text | the `strikethrough` format |
  | `highlight` | highlighted text, and the color palette | the `highlight` format, a text color |
  | `subscript` | subscript text (not in the default toolbar) | the `subscript` format |
  | `superscript` | superscript text (not in the default toolbar) | the `superscript` format |
  | `inline_code` | code in a line of text | the `code` format |
  | `links` | links, autolinks, the link form | `link`, `autolink` |
  | `headings` | headings | `heading` |
  | `quotes` | block quotes | `quote` |
  | `lists` | bulleted and numbered lists | `list`, `listitem` |
  | `check_lists` | check lists (needs `lists`) | a `list` with `listType` `"check"` |
  | `code_blocks` | code blocks and their language picker | `code`, `code-highlight` |
  | `horizontal_rules` | horizontal rules | `horizontalrule` |
  | `tables` | tables | `table`, `tablerow`, `tablecell` |
  | `attachments` | file uploads and image galleries (with the `uploads` attribute) | `attachment`, `gallery` |
  | `mentions` | prompts and mentions (with the `prompts` attribute) | `mention` |
  | `images` | images from a URL, as Markdown has them | `image` |
  | `footnotes` | footnotes and their references | `footnotedefinition`, `footnotereference` |

  Paragraphs, line breaks, tabs, undo and redo are always there. The case
  formats (`lowercase`, `uppercase`, `capitalize`) are not features: the
  editor keeps them.

  The keyboard shortcuts of the formats are Cmd (Ctrl on other systems)
  with `B`, `I`, `U`, `Shift+H` (highlight), `,` (subscript) and `.`
  (superscript). Subscript and superscript have no button in the default
  toolbar: an app's toolbar (`Kotoba.Components.kotoba_toolbar/1`) can have
  them.

  A feature that is off has no node, no toolbar button, no Markdown shortcut
  and no keyboard shortcut in the editor. A pasted table, heading or code
  block comes in as paragraphs, and a pasted format that is off is dropped.
  A stored node of a feature that is off loads as an unknown node: the
  editor shows a placeholder and saves it with no change.

  The [Editing features](features.md) guide has the shortcuts and the
  toolbar of each feature.

  The editor is not a check: a request can post any document. To refuse a
  document with a feature that the field does not have, use
  `Kotoba.Content.validate_features/3` in the changeset, or `check/2`.
  App nodes and unknown nodes are not features, and `check/2` allows them.
  """

  alias Kotoba.{Document, Nodes}

  @features [
    :bold,
    :italic,
    :underline,
    :strikethrough,
    :highlight,
    :subscript,
    :superscript,
    :inline_code,
    :links,
    :headings,
    :quotes,
    :lists,
    :check_lists,
    :code_blocks,
    :horizontal_rules,
    :tables,
    :attachments,
    :mentions,
    :images,
    :footnotes
  ]

  @requires %{check_lists: :lists}

  @formats %{
    bold: :bold,
    italic: :italic,
    underline: :underline,
    strikethrough: :strikethrough,
    highlight: :highlight,
    subscript: :subscript,
    superscript: :superscript,
    inline_code: :code
  }

  @types %{
    Nodes.Link => :links,
    Nodes.AutoLink => :links,
    Nodes.Heading => :headings,
    Nodes.Quote => :quotes,
    Nodes.ListItem => :lists,
    Nodes.Code => :code_blocks,
    Nodes.CodeHighlight => :code_blocks,
    Nodes.HorizontalRule => :horizontal_rules,
    Nodes.Table => :tables,
    Nodes.TableRow => :tables,
    Nodes.TableCell => :tables,
    Nodes.Attachment => :attachments,
    Nodes.Gallery => :attachments,
    Nodes.Mention => :mentions,
    Nodes.Image => :images,
    Nodes.FootnoteReference => :footnotes,
    Nodes.FootnoteDefinition => :footnotes
  }

  @typedoc "A built-in feature."
  @type feature ::
          :bold
          | :italic
          | :underline
          | :strikethrough
          | :highlight
          | :subscript
          | :superscript
          | :inline_code
          | :links
          | :headings
          | :quotes
          | :lists
          | :check_lists
          | :code_blocks
          | :horizontal_rules
          | :tables
          | :attachments
          | :mentions
          | :images
          | :footnotes

  @doc """
  Returns the features, in order.

  ## Examples

      iex> :tables in Kotoba.Features.all()
      true

  """
  @spec all() :: [feature()]
  def all, do: @features

  @doc """
  Returns the features of a list of names (atoms or strings), in the order
  of `all/0` and once each.

  Raises `ArgumentError` for a name that is not a feature, or for a
  feature without the one that it needs (`check_lists` needs `lists`).

  ## Examples

      iex> Kotoba.Features.names!(["lists", :bold, "lists"])
      [:bold, :lists]

  """
  @spec names!([atom() | String.t()]) :: [feature()]
  def names!(names) when is_list(names) do
    named = MapSet.new(names, &feature!/1)

    for {feature, required} <- @requires, feature in named, required not in named do
      raise ArgumentError, "the Kotoba feature #{inspect(feature)} needs #{inspect(required)}"
    end

    Enum.filter(@features, &(&1 in named))
  end

  defp feature!(name) when is_atom(name) and name in @features, do: name

  defp feature!(name) when is_binary(name) do
    Enum.find(@features, &(Atom.to_string(&1) == name)) || unknown!(name)
  end

  defp feature!(name), do: unknown!(name)

  defp unknown!(name) do
    raise ArgumentError,
          "unknown Kotoba feature #{inspect(name)}, use one of #{inspect(@features)}"
  end

  @doc """
  Returns the features that a document uses, in the order of `all/0`.

  ## Examples

      iex> {:ok, doc} =
      ...>   Kotoba.Document.parse(%{
      ...>     "kotoba" => 1,
      ...>     "lexical" => "0.51",
      ...>     "root" => %{
      ...>       "type" => "root",
      ...>       "children" => [
      ...>         %{"type" => "heading", "tag" => "h2", "children" => [%{"type" => "text", "text" => "Hi", "format" => 1}]}
      ...>       ]
      ...>     }
      ...>   })
      iex> Kotoba.Features.used(doc)
      [:bold, :headings]

  """
  @spec used(Document.t()) :: [feature()]
  def used(%Document{} = doc) do
    used = Document.reduce(doc, MapSet.new(), &node_features/2)
    Enum.filter(@features, &(&1 in used))
  end

  defp node_features(%Nodes.List{list_type: list_type}, acc) do
    acc = MapSet.put(acc, :lists)
    if list_type == "check", do: MapSet.put(acc, :check_lists), else: acc
  end

  defp node_features(%module{format: format} = node, acc)
       when module in [Nodes.Text, Nodes.CodeHighlight] and is_integer(format) do
    acc = if module == Nodes.CodeHighlight, do: MapSet.put(acc, :code_blocks), else: acc
    acc = if text_color?(node), do: MapSet.put(acc, :highlight), else: acc

    Enum.reduce(@formats, acc, fn {feature, name}, acc ->
      if Nodes.Text.format?(format, name), do: MapSet.put(acc, feature), else: acc
    end)
  end

  defp node_features(%module{}, acc) do
    case Map.fetch(@types, module) do
      {:ok, feature} -> MapSet.put(acc, feature)
      :error -> acc
    end
  end

  # A text color is part of the `highlight` feature (its palette).
  defp text_color?(%Nodes.Text{} = node), do: Nodes.Text.colors(node).text != nil
  defp text_color?(_node), do: false

  @doc """
  Checks that a document uses only the given features (a list for
  `names!/1`). Returns `:ok`, or `{:error, features}` with the features
  that it uses and does not have.

  ## Examples

      iex> {:ok, doc} =
      ...>   Kotoba.Document.parse(%{
      ...>     "kotoba" => 1,
      ...>     "lexical" => "0.51",
      ...>     "root" => %{"type" => "root", "children" => [%{"type" => "quote", "children" => []}]}
      ...>   })
      iex> Kotoba.Features.check(doc, [:bold])
      {:error, [:quotes]}
      iex> Kotoba.Features.check(doc, [:quotes])
      :ok

  """
  @spec check(Document.t(), [atom() | String.t()]) :: :ok | {:error, [feature()]}
  def check(%Document{} = doc, features) do
    allowed = names!(features)

    case used(doc) -- allowed do
      [] -> :ok
      extra -> {:error, extra}
    end
  end
end
