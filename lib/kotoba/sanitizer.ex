defmodule Kotoba.Sanitizer do
  @moduledoc """
  The structural checks that `Kotoba.Renderer` does before it renders a
  node.

  Kotoba never passes raw HTML through. The renderer escapes every string,
  and the sanitizer adds these checks:

    * **Attributes.** The node must pass its own `validate/1`. Each string
      attribute must have no control characters, and its length must be in
      the limit: 200 characters for `label`, `name`, `title`, `kind`, `id`,
      `rel`, `target`, `language` and `content_type`, and 2048 characters
      for the other string attributes, `url` included. The text of a `Kotoba.Nodes.Text` or
      `Kotoba.Nodes.CodeHighlight` node and the `style` of a text node are
      not attributes; they have no limit. The URL of a link is checked by
      `link_url/2`.
    * **Nesting.** A list holds only list items, and a list item is valid
      only inside a list. A list item holds inline nodes, decorators and
      one nested list (by position: a second list at the same level
      renders as unknown, even when it repeats the first). A table is
      valid only under the root, a quote of blocks or a footnote, and
      holds only table rows; a table row is valid only in a table and
      holds only table cells; a table cell is valid only in a table row,
      and holds no table. A gallery is valid only under the root and holds
      only attachments. A footnote is valid only under the root. A code
      block holds only code highlight, text, line break and tab nodes. A
      paragraph, a heading, a quote and a link hold only inline nodes and
      decorators, and a link holds no other link; a quote of blocks
      (`shadowRoot`) holds blocks too. A decorator has no children.
      `horizontalrule` and `attachment` (block decorators) are valid only
      under the root, a list item, a table cell, a quote of blocks or a
      footnote (and an attachment in a gallery); elsewhere they render as
      unknown.
    * **Links.** `link_url/2` accepts a URL with an allowed scheme, or a
      relative URL. A link with a URL that is not safe renders as its text.
      An attachment with a URL or a `preview` that is not safe fails the
      check.

  When a node fails a check, the renderer renders it as an unknown node
  (inert, with no content). It does not raise.

  ## Link schemes

  The allowed schemes come from the application config. The default is
  `~w(http https mailto)`:

      config :kotoba, allowed_link_schemes: ~w(http https mailto tel)

  ## Policies

    * `:default` - links render as anchors and attachments render as
      figures.
    * `:untrusted` - for content from people that the app does not trust.
      Links render as their text, with no anchor. Attachments render as
      their file name, with no image and no link.
  """

  alias Kotoba.Nodes

  @typedoc "The name of a policy."
  @type policy_name :: :default | :untrusted

  @typedoc """
  A policy. `links` is `true` when links render as anchors. `attachments`
  is `true` when attachments render as figures.
  """
  @type policy :: %{name: policy_name(), links: boolean(), attachments: boolean()}

  @default_schemes ~w(http https mailto)
  @url_limit 2048
  @label_limit 200
  @label_fields [:label, :name, :title, :kind, :id, :rel, :target, :language, :content_type]

  @control ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @scheme ~r/\A([a-zA-Z][a-zA-Z0-9+.\-]*):/

  @doc """
  Returns the policy for a name. A policy map is returned with no change.

  Raises `ArgumentError` for an unknown name.

  ## Examples

      iex> Kotoba.Sanitizer.policy(:untrusted)
      %{name: :untrusted, links: false, attachments: false}

  """
  @spec policy(policy_name() | policy()) :: policy()
  def policy(:default), do: %{name: :default, links: true, attachments: true}
  def policy(:untrusted), do: %{name: :untrusted, links: false, attachments: false}

  def policy(%{name: _name, links: links, attachments: attachments} = policy)
      when is_boolean(links) and is_boolean(attachments),
      do: policy

  def policy(other),
    do: raise(ArgumentError, "unknown policy #{inspect(other)}, use :default or :untrusted")

  @doc """
  Returns the URL for an `href` or a `src`, or `nil` when it is not safe.

  The URL is trimmed. It is accepted when it has a scheme from the allowed
  schemes, or when it has no scheme (a relative URL). A URL with a control
  character, or with more than 2048 characters, is refused.

  ## Options

    * `:schemes` - the allowed schemes. The default comes from
      `config :kotoba, allowed_link_schemes:`, else `~w(http https mailto)`.

  ## Examples

      iex> Kotoba.Sanitizer.link_url("https://example.com")
      "https://example.com"

      iex> Kotoba.Sanitizer.link_url("/docs#top")
      "/docs#top"

      iex> Kotoba.Sanitizer.link_url("javascript:alert(1)")
      nil

  """
  @spec link_url(term(), keyword()) :: String.t() | nil
  def link_url(url, opts \\ [])

  def link_url(url, opts) when is_binary(url) and is_list(opts) do
    url = String.trim(url)

    cond do
      url == "" -> nil
      String.length(url) > @url_limit -> nil
      Regex.match?(@control, url) -> nil
      true -> check_scheme(url, opts)
    end
  end

  def link_url(_url, _opts), do: nil

  defp check_scheme(url, opts) do
    case Regex.run(@scheme, url, capture: :all_but_first) do
      nil -> url
      [scheme] -> if String.downcase(scheme) in allowed_schemes(opts), do: url
    end
  end

  @doc """
  Returns the allowed link schemes, in lower case.

  The editor gets the same list (see `Kotoba.Components.kotoba/1`), so that
  it keeps the links that the server keeps.

  ## Options

    * `:schemes` - the allowed schemes. The default comes from
      `config :kotoba, allowed_link_schemes:`, else `~w(http https mailto)`.

  ## Examples

      iex> Kotoba.Sanitizer.allowed_schemes(schemes: ["HTTPS", "tel"])
      ["https", "tel"]

  """
  @spec allowed_schemes(keyword()) :: [String.t()]
  def allowed_schemes(opts \\ []) do
    opts
    |> Keyword.get_lazy(:schemes, fn ->
      Application.get_env(:kotoba, :allowed_link_schemes, @default_schemes)
    end)
    |> Enum.map(&String.downcase/1)
  end

  @doc """
  Checks one node in its parent. `parent` is `nil` for the root node. The
  `:schemes` option is the same as in `link_url/2`. `:index` is the
  position of the node among its parent's children; `Kotoba.Renderer`
  sets it for every node it renders, and it decides whether a list nested
  in a list item is the one allowed nested list. A direct call that
  checks a nested list without `:index` always refuses it.

  Returns `:ok`, or `{:error, reason}` when the renderer must render the
  node as an unknown node.
  """
  @spec check(Kotoba.Node.t(), Kotoba.Node.t() | nil, keyword()) :: :ok | {:error, String.t()}
  def check(node, parent, opts \\ [])

  def check(%Nodes.Unknown{}, _parent, _opts), do: :ok

  def check(%module{} = node, parent, opts) do
    with :ok <- check_valid(module, node),
         :ok <- check_strings(module, node),
         :ok <- check_children(module, node),
         :ok <- check_url(node, opts) do
      check_parent(node, parent, opts)
    end
  end

  defp check_url(%Nodes.Attachment{url: url, preview: preview}, opts) do
    cond do
      link_url(url, opts) == nil -> {:error, "url is not a safe URL"}
      preview != nil and link_url(preview, opts) == nil -> {:error, "preview is not a safe URL"}
      true -> :ok
    end
  end

  defp check_url(_node, _opts), do: :ok

  defp check_valid(module, node) do
    case module.validate(node) do
      :ok -> :ok
      {:error, [message | _rest]} -> {:error, message}
    end
  end

  defp check_strings(module, node) do
    Enum.reduce_while(module.fields(), :ok, fn field, :ok ->
      case check_string(module, field, Map.fetch!(node, field.name)) do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp check_string(module, field, _value)
       when module in [Nodes.Text, Nodes.CodeHighlight] and field.name in [:text, :style],
       do: :ok

  # Not a blanket exemption: `validate/1` (`Kotoba.Nodes.Tab`'s `in:
  # ["\t"]`) already refuses every value but the single tab character
  # before this check runs, so this clause only ever sees that one,
  # harmless value.
  defp check_string(Nodes.Tab, %{name: :text}, "\t"), do: :ok

  # `link_url/2` checks the URL of a link; a link with a bad URL keeps its text.
  defp check_string(module, field, _value)
       when module in [Nodes.Link, Nodes.AutoLink] and field.name == :url,
       do: :ok

  defp check_string(module, field, values) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case check_string(module, field, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_string(_module, field, value) when is_binary(value) do
    cond do
      Regex.match?(@control, value) ->
        {:error, "#{field.key} has a control character"}

      String.length(value) > limit(field.name) ->
        {:error, "#{field.key} is longer than #{limit(field.name)} characters"}

      true ->
        :ok
    end
  end

  defp check_string(_module, _field, _value), do: :ok

  defp limit(name) when name in @label_fields, do: @label_limit
  defp limit(_name), do: @url_limit

  defp check_children(module, node) do
    if module.kind() == :decorator and Map.get(node, :children, []) != [],
      do: {:error, "a decorator has no children"},
      else: :ok
  end

  # A list item is valid only directly inside a list.
  defp check_parent(%Nodes.ListItem{}, %Nodes.List{}, _opts), do: :ok

  defp check_parent(%Nodes.ListItem{}, _other_parent, _opts),
    do: {:error, "a list item must be inside a list"}

  # A table under the root holds rows, and a row holds cells.
  defp check_parent(%Nodes.TableRow{}, %Nodes.Table{}, _opts), do: :ok

  defp check_parent(%Nodes.TableRow{}, _other_parent, _opts),
    do: {:error, "a table row must be inside a table"}

  defp check_parent(%Nodes.TableCell{}, %Nodes.TableRow{}, _opts), do: :ok

  defp check_parent(%Nodes.TableCell{}, _other_parent, _opts),
    do: {:error, "a table cell must be inside a table row"}

  defp check_parent(_node, %Nodes.Table{}, _opts), do: {:error, "a table holds only table rows"}

  defp check_parent(_node, %Nodes.TableRow{}, _opts),
    do: {:error, "a table row holds only table cells"}

  defp check_parent(%Nodes.Table{}, %Nodes.Root{}, _opts), do: :ok

  defp check_parent(%Nodes.Table{}, parent, _opts)
       when is_struct(parent, Nodes.FootnoteDefinition),
       do: :ok

  defp check_parent(%Nodes.Table{}, %Nodes.Quote{shadow_root: true}, _opts), do: :ok

  defp check_parent(%Nodes.Table{}, _other_parent, _opts),
    do: {:error, "a table is valid only under the root, a quote of blocks or a footnote"}

  # A footnote is valid only under the root.
  defp check_parent(%Nodes.FootnoteDefinition{}, %Nodes.Root{}, _opts), do: :ok

  defp check_parent(%Nodes.FootnoteDefinition{}, _other_parent, _opts),
    do: {:error, "a footnote is valid only under the root"}

  # A gallery under the root holds attachments.
  defp check_parent(%Nodes.Attachment{}, %Nodes.Gallery{}, _opts), do: :ok

  defp check_parent(_node, %Nodes.Gallery{}, _opts),
    do: {:error, "a gallery holds only attachments"}

  defp check_parent(%Nodes.Gallery{}, %Nodes.Root{}, _opts), do: :ok

  defp check_parent(%Nodes.Gallery{}, _other_parent, _opts),
    do: {:error, "a gallery is valid only under the root"}

  defp check_parent(_node, nil, _opts), do: :ok
  defp check_parent(_node, %Nodes.List{}, _opts), do: {:error, "a list holds only list items"}

  # One nested list per list item, by position: two lists at the same
  # level render as unknown even when they are identical.
  defp check_parent(%Nodes.List{}, %Nodes.ListItem{children: children}, opts) do
    index = Keyword.get(opts, :index)

    case Enum.find_index(children, &match?(%Nodes.List{}, &1)) do
      ^index -> :ok
      _other -> {:error, "a list item holds only one nested list"}
    end
  end

  defp check_parent(%module{}, %Nodes.Code{}, _opts) do
    if module in [Nodes.CodeHighlight, Nodes.Text, Nodes.LineBreak, Nodes.Tab],
      do: :ok,
      else: {:error, "a code block holds only code, text, line breaks and tabs"}
  end

  # Block decorators are valid only under the root, a list item or a table
  # cell. The
  # children of the root node have the root struct as their parent, not
  # `nil` (only the root node's own check has a `nil` parent).
  defp check_parent(%module{}, parent, _opts)
       when module in [Nodes.HorizontalRule, Nodes.Attachment] do
    case parent do
      %Nodes.Root{} ->
        :ok

      %Nodes.ListItem{} ->
        :ok

      %Nodes.TableCell{} ->
        :ok

      %Nodes.Quote{shadow_root: true} ->
        :ok

      %Nodes.FootnoteDefinition{} ->
        :ok

      _other ->
        {:error,
         "a #{module.type()} node is valid only under the root, a list item, a table cell, a quote of blocks or a footnote"}
    end
  end

  defp check_parent(%link{}, %parent{}, _opts)
       when link in [Nodes.Link, Nodes.AutoLink] and parent in [Nodes.Link, Nodes.AutoLink],
       do: {:error, "a link holds no other link"}

  # A quote of blocks holds blocks and inline nodes, as a table cell does.
  defp check_parent(_node, %Nodes.Quote{shadow_root: true}, _opts), do: :ok

  defp check_parent(%module{}, %parent{}, _opts)
       when parent in [
              Nodes.ListItem,
              Nodes.Paragraph,
              Nodes.Heading,
              Nodes.Quote,
              Nodes.Link,
              Nodes.AutoLink
            ] do
    if module.kind() == :block,
      do: {:error, "a #{parent.type()} node holds only inline nodes and decorators"},
      else: :ok
  end

  defp check_parent(_node, _parent, _opts), do: :ok
end
