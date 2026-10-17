defmodule Kotoba.Content do
  @moduledoc """
  An `Ecto.Type` that stores a rich text document with a cached rendering.

  A `Kotoba.Content` struct has:

    * `:doc` - the document envelope, as a map with string keys (see
      `Kotoba.Document`).
    * `:html` - the safe HTML of the document, rendered with the
      `:default` policy, as a string.
    * `:text` - the plain text of the document, as a string.
    * `:version` - the content cache version, currently `1`.

  `cast/1` reads a JSON string (as a form posts it through the hidden
  input), a document envelope, a bare Lexical root node (wrapped in an
  envelope), a `Kotoba.Content` struct, `nil` or `""` (both cast to
  `empty/0`). It parses the input through `Kotoba.Document.parse/2`, with
  the node registry from the application configuration, and renders
  `:html` and `:text` right away, so a row always carries a fresh cache.
  Invalid input casts to `:error`, which `Ecto.Changeset` turns into an
  `"is invalid"` error.

  `dump/1` and `load/1` store and read `%{"doc", "html", "text",
  "version"}`. When a loaded map has no `"html"` or no `"text"` (an older
  row, or one written outside Kotoba), `load/1` re-renders them from
  `"doc"`. When `"doc"` itself no longer parses (for example a custom
  node lost a field it once allowed), `load/1` still succeeds, with an
  empty cache, rather than failing the whole query; a row where `"doc"`
  is not even a map is refused.

  `equal?/2` compares the `:doc` field of two `Kotoba.Content` structs,
  so an `Ecto.Changeset` does not mark the field changed when only the
  cache was recomputed; it falls back to `==` for anything else, so `nil`
  equals `nil`.

  Use `rerender/2` after a node registry or a render policy changes, to
  bring the cache of a stored document up to date. Use `from_markdown/2`
  to build a `Kotoba.Content` from a Markdown string, on a best-effort
  basis.

  ## Forms and changesets

  The Kotoba editor hook always posts a JSON document through the hidden
  input, on every change: an empty editor posts the empty envelope (the
  `doc` of `empty/0`), never `""` and never no param at all. So in the
  ordinary form-submit path, `cast/1` only ever sees a JSON string, and
  the `nil`/`""` handling above does not come into play.

  `Ecto.Changeset.cast/4` has its own, separate handling of `""`: by
  default, it treats a param of `""` (or all white space) as absent and
  keeps the field's current value (`nil`, unless the schema gives it a
  default) instead of calling this type's `cast/1` at all. A blank param
  never reaches `empty/0` this way. A host that wants `""` to cast to
  `empty/0` — a manual API call, say, rather than the editor — opts in
  with `empty_values: []` on that field's own `cast/4` call. This turns
  off the `""` → current-value behaviour for every field named in that
  same `cast/4` call, not only `:body`, so give the field its own
  `cast/4` call when the form has other string fields that should keep
  the default. A host can instead give the field a starting document with
  `field :body, Kotoba.Content, default: Kotoba.Content.empty()`.

  ## Examples

      iex> content = Kotoba.Content.empty()
      iex> content.html
      ""
      iex> content.text
      ""

  """

  use Ecto.Type

  alias Kotoba.Content.MarkdownImport
  alias Kotoba.{Document, Features, Renderer}

  @version 1
  @kotoba_version 1
  @lexical_version "0.51"

  @enforce_keys [:doc, :html, :text]
  defstruct doc: nil, html: "", text: "", version: @version

  @type t :: %__MODULE__{
          doc: map(),
          html: String.t(),
          text: String.t(),
          version: pos_integer()
        }

  @impl Ecto.Type
  def type, do: :map

  @doc """
  Casts a JSON string, a document envelope, a bare Lexical root node, a
  `Kotoba.Content` struct, `nil` or `""` to a `Kotoba.Content`.

  Renders `:html` and `:text` at cast time, also for a `Kotoba.Content`
  struct: its `:doc` is parsed again, and its `:html` and `:text` are not
  kept. Returns `:error` when the
  input is not valid JSON, is not an object, or does not parse as a
  `Kotoba.Document` (see `Kotoba.Document.parse/2`).

  ## Examples

      iex> {:ok, content} = Kotoba.Content.cast(%{"type" => "root", "children" => []})
      iex> content.text
      ""

      iex> Kotoba.Content.cast("not json")
      :error

  """
  @impl Ecto.Type
  def cast(%__MODULE__{doc: %{} = envelope}), do: parse(envelope)
  def cast(%__MODULE__{}), do: :error
  def cast(nil), do: {:ok, empty()}
  def cast(""), do: {:ok, empty()}

  def cast(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, decoded} -> cast_decoded(decoded)
      {:error, _reason} -> :error
    end
  end

  def cast(%{} = map), do: cast_decoded(map)
  def cast(_other), do: :error

  # Only a map from here on: a decoded JSON string that turns out to hold
  # something other than an object (`null`, a number, another JSON string)
  # is not cast a second time.
  defp cast_decoded(%{"type" => "root"} = root), do: parse(wrap(root))
  defp cast_decoded(%{"root" => _root} = envelope), do: parse(envelope)
  defp cast_decoded(_other), do: :error

  @doc """
  Returns the document envelope of anything that `cast/1` accepts, with the
  same checks, but without rendering `:html` and `:text`.

  `Kotoba.Components.kotoba/1` uses it for the hidden input on every
  render.

  ## Examples

      iex> {:ok, doc} = Kotoba.Content.to_doc(~s({"type": "root", "children": []}))
      iex> doc["kotoba"]
      1

      iex> Kotoba.Content.to_doc(42)
      :error

  """
  @spec to_doc(term()) :: {:ok, map()} | :error
  def to_doc(%__MODULE__{doc: doc}), do: {:ok, doc}
  def to_doc(nil), do: parse_doc(wrap(%{"type" => "root"}))
  def to_doc(""), do: to_doc(nil)

  def to_doc(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, decoded} -> to_doc_decoded(decoded)
      {:error, _reason} -> :error
    end
  end

  def to_doc(%{} = map), do: to_doc_decoded(map)
  def to_doc(_other), do: :error

  defp to_doc_decoded(%{"type" => "root"} = root), do: parse_doc(wrap(root))
  defp to_doc_decoded(%{"root" => _root} = envelope), do: parse_doc(envelope)
  defp to_doc_decoded(_other), do: :error

  defp parse_doc(envelope) do
    case Document.parse(envelope) do
      {:ok, doc} -> {:ok, Document.to_json(doc)}
      {:error, _messages} -> :error
    end
  end

  @impl Ecto.Type
  def dump(%__MODULE__{} = content) do
    {:ok,
     %{
       "doc" => content.doc,
       "html" => content.html,
       "text" => content.text,
       "version" => content.version
     }}
  end

  def dump(_other), do: :error

  @impl Ecto.Type
  def load(%{"doc" => doc} = map) when is_map(doc) do
    with html when is_binary(html) <- Map.get(map, "html"),
         text when is_binary(text) <- Map.get(map, "text") do
      {:ok,
       %__MODULE__{doc: doc, html: html, text: text, version: Map.get(map, "version", @version)}}
    else
      _missing -> {:ok, load_without_cache(doc, map)}
    end
  end

  def load(_other), do: :error

  # `doc` is a map (checked above), but may still fail Document.parse/2 (a
  # required field a removed custom node used to allow, say). A bad doc
  # loads with an empty cache instead of failing the whole query.
  defp load_without_cache(doc, map) do
    case Document.parse(doc) do
      {:ok, parsed} ->
        build(parsed, [])

      {:error, _messages} ->
        %__MODULE__{doc: doc, html: "", text: "", version: cache_version(map)}
    end
  end

  defp cache_version(map), do: Map.get(map, "version", @version)

  @impl Ecto.Type
  def equal?(%__MODULE__{doc: a}, %__MODULE__{doc: b}), do: a == b
  def equal?(a, b), do: a == b

  @impl Ecto.Type
  def embed_as(_format), do: :dump

  @doc """
  Returns the current content cache version.

  A `Kotoba.Content` with another `:version` has a cache made by another
  version of Kotoba; `Kotoba.Components.kotoba_content/1` renders such a
  document again instead of using its `:html`.
  """
  @spec cache_version() :: pos_integer()
  def cache_version, do: @version

  @doc """
  Returns an empty `Kotoba.Content`, for a new form or a blank field.
  """
  @spec empty() :: t()
  def empty do
    {:ok, doc} = Document.parse(wrap(%{"type" => "root"}))
    build(doc, [])
  end

  @doc """
  Re-renders `:html` and `:text` from `:doc`, with a node registry and a
  render policy.

  When `:doc` no longer parses (for example a required field that a
  removed custom node used to allow), the content is returned unchanged.

  ## Options

    * `:nodes` - extra node modules for the registry, as in
      `Kotoba.Document.parse/2`.
    * `:policy` - the render policy for `:html`. The default is `:default`.

  """
  @spec rerender(t(), keyword()) :: t()
  def rerender(%__MODULE__{doc: envelope} = content, opts \\ []) do
    {nodes, render_opts} = Keyword.pop(opts, :nodes, [])

    case Document.parse(envelope, nodes: nodes) do
      {:ok, doc} -> build(doc, render_opts)
      {:error, _messages} -> content
    end
  end

  @doc """
  Builds a `Kotoba.Content` from a Markdown string.

  MDEx (comrak, a port of GitHub's cmark-gfm) reads the Markdown:
  CommonMark and GitHub Flavored Markdown, with tables, task lists,
  strikethrough, autolinks and footnotes. Each construct becomes its
  node: quotes hold blocks, an image is a `Kotoba.Nodes.Image`, and a
  paragraph of `&nbsp;` is a blank line (see `Kotoba.Nodes.Paragraph`), so
  the Markdown of `Kotoba.Renderer.to_markdown/2` reads back to the same
  document.

  Raw HTML is text: Kotoba never passes HTML through. A list item holds
  inline content and one nested list; the paragraphs of an item with
  several are joined by line breaks, and a code block, a quote, a table or
  a heading in an item comes after the list. When the built document
  somehow fails to parse, returns `empty/0`.

  ## Options

    * `:features` - the features of the editor (see `Kotoba.Features`),
      every feature by default. A construct whose feature is off becomes
      its closest form, with no text lost: a heading a paragraph, a quote
      its blocks, a list its items, a table a line for each row, an image
      its alternative text, a footnote its `[^label]` text, and a format is
      dropped.
    * `:nodes` and `:policy` - as in `rerender/2`.

  ## Examples

      iex> content = Kotoba.Content.from_markdown("# Title\\n\\nHello **world**.")
      iex> content.text
      "Title\\nHello world."

  """
  @spec from_markdown(String.t(), keyword()) :: t()
  def from_markdown(markdown, opts \\ []) when is_binary(markdown) do
    {features, opts} = Keyword.pop(opts, :features, Kotoba.Features.all())
    envelope = wrap(MarkdownImport.root(markdown, features: features))
    {nodes, render_opts} = Keyword.pop(opts, :nodes, [])

    case Document.parse(envelope, nodes: nodes) do
      {:ok, doc} -> build(doc, render_opts)
      {:error, _messages} -> empty()
    end
  end

  @doc """
  Validates that the `Kotoba.Content` of a changeset field uses only the
  given features (see `Kotoba.Features`), the ones of the field's editor.
  The editor keeps out what it does not have, but a request can post any
  document; this refuses one with a table in a comment field, say.

      changeset
      |> cast(params, [:body])
      |> Kotoba.Content.validate_features(:body, ~w(bold italic links lists)a)

  The error is `"has content that is not allowed: %{names}"`, with
  `names: "tables"` (the features, joined with ", ") and
  `validation: :features` in its keys. A field with no content, or with a
  document that no longer parses, passes. The features are checked with
  `Kotoba.Features.names!/1`, which raises for an unknown name.
  """
  @spec validate_features(Ecto.Changeset.t(), atom(), [atom() | String.t()]) :: Ecto.Changeset.t()
  def validate_features(%Ecto.Changeset{} = changeset, field, features) when is_atom(field) do
    allowed = Features.names!(features)

    Ecto.Changeset.validate_change(changeset, field, fn ^field, content ->
      with {:ok, envelope} <- to_doc(content),
           {:ok, doc} <- Document.parse(envelope),
           {:error, extra} <- Features.check(doc, allowed) do
        [
          {field,
           {"has content that is not allowed: %{names}",
            names: Enum.join(extra, ", "), validation: :features}}
        ]
      else
        _ok -> []
      end
    end)
  end

  defp parse(envelope) do
    case Document.parse(envelope) do
      {:ok, doc} -> {:ok, build(doc, [])}
      {:error, _messages} -> :error
    end
  end

  defp build(doc, opts) do
    policy = Keyword.get(opts, :policy, :default)

    html =
      doc |> Renderer.to_html(Keyword.put(opts, :policy, policy)) |> Phoenix.HTML.safe_to_string()

    text = Renderer.to_text(doc, opts)
    %__MODULE__{doc: Document.to_json(doc), html: html, text: text, version: @version}
  end

  defp wrap(root),
    do: %{"kotoba" => @kotoba_version, "lexical" => @lexical_version, "root" => root}
end
