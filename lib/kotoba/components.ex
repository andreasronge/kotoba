defmodule Kotoba.Components do
  @moduledoc """
  Function components for the Kotoba editor and for rendered content.

      import Kotoba.Components

      <.form for={@form} phx-change="validate" phx-submit="save">
        <label id="post-body-label">Body</label>
        <.kotoba field={@form[:body]} id="post-body" label_id="post-body-label" />
      </.form>

      <.kotoba_content content={@post.body} />

  The editor needs the `Kotoba` hook in the LiveSocket and the Kotoba CSS
  (see the README). It pushes `kotoba:change` only with `change={true}`.
  """

  use Phoenix.Component

  alias Kotoba.{CodeLanguages, Content, Document, Features, Prompts, Renderer, Sanitizer}
  alias Phoenix.HTML.FormField

  @commands [
    {"bold", "Bold", "Text"},
    {"italic", "Italic", "Text"},
    {"underline", "Underline", "Text"},
    {"strikethrough", "Strikethrough", "Text"},
    {"highlight", "Highlight", "Text"},
    {"code", "Inline code", "Text"},
    {"subscript", "Subscript", "Text"},
    {"superscript", "Superscript", "Text"},
    {"link", "Link", "Text"},
    {"h1", "Heading 1", "Blocks"},
    {"h2", "Heading 2", "Blocks"},
    {"h3", "Heading 3", "Blocks"},
    {"h4", "Heading 4", "Blocks"},
    {"quote", "Quote", "Blocks"},
    {"bullet", "Bulleted list", "Lists"},
    {"number", "Numbered list", "Lists"},
    {"check", "Check list", "Lists"},
    {"code-block", "Code block", "Insert"},
    {"rule", "Horizontal rule", "Insert"},
    {"table", "Table", "Insert"},
    {"upload", "Attach a file", "Insert"},
    {"assist", "Assist", "Assist"},
    {"code-language", "Code language", "Code"},
    {"table-row-before", "Insert row above", "Table"},
    {"table-row-after", "Insert row below", "Table"},
    {"table-column-before", "Insert column before", "Table"},
    {"table-column-after", "Insert column after", "Table"},
    {"table-header-row", "Header row", "Table"},
    {"table-header-column", "Header column", "Table"},
    {"table-delete-row", "Delete row", "Table"},
    {"table-delete-column", "Delete column", "Table"},
    {"table-delete", "Delete table", "Table"},
    {"gallery", "Gallery", "Image"},
    {"image-previous", "Move image left", "Image"},
    {"image-next", "Move image right", "Image"},
    {"undo", "Undo", "History"},
    {"redo", "Redo", "History"}
  ]

  @command_names Enum.map(@commands, &elem(&1, 0))

  @selection_commands ~w(bold italic underline strikethrough code highlight link)

  @doc """
  Returns the names of the toolbar commands, in toolbar order.

  ## Examples

      iex> "bold" in Kotoba.Components.toolbar_commands()
      true

  """
  @spec toolbar_commands() :: [String.t()]
  def toolbar_commands, do: @command_names

  @doc """
  Renders the rich-text editor for a form field.

  It renders:

    * a hidden input with the field's `name` and, as its value, the JSON of
      the field's value cast to `Kotoba.Content` (or of an empty document).
      The editor writes the document to it on every change, so a plain
      form submit posts it. It is outside the editor element, so a
      LiveView patch can update it;
    * the editor element, with `phx-hook="Kotoba"` and `phx-update="ignore"`.
      The hook builds the toolbar and the editable area in it;
    * the LiveView file input of `uploads`, visually hidden, when
      `uploads` is given. The toolbar's attach button, a drop and a paste
      of files hand the files to it.

  The editor always has an accessible name: `aria-labelledby` with
  `label_id` (the id of a visible label, the best choice), else
  `aria-label` with `label`, else the field name in words.

  Attributes that are not declared (`phx-target`, …) go on the editor
  element. `aria-describedby` and `aria-invalid` go on the editable area
  (the `textbox`), and follow the field: a new value in a later render
  reaches it, and a value that goes away is removed. In a LiveComponent, give `phx-target={@myself}`,
  so that the editor's events go to the component.

  The form posts the document, so a LiveView needs no editor event for a
  form. With `change`, the editor also pushes `kotoba:change` with
  `%{"id", "doc", "v"}` on each change (debounced), for example to save a
  draft; the LiveView must then handle it.

  A change of `readonly` or `change` in a later render reaches the editor. To change
  the document after the first render, use `Kotoba.Live.push_content/3`:
  the editor reads the hidden input only when it mounts.
  """
  attr :field, FormField, required: true, doc: "the form field, for example `@form[:body]`"

  attr :id, :string,
    default: nil,
    doc: "the id of the editor element. The default is the field's id with `_editor`"

  attr :label_id, :string,
    default: nil,
    doc:
      "the id of the element that labels the editor (`aria-labelledby`). Without it, the editor gets `aria-label` from `label`"

  attr :label, :string,
    default: nil,
    doc:
      "the accessible name when there is no `label_id` (`aria-label`). The default is the field name in words, for example \"Body\""

  attr :placeholder, :string, default: nil, doc: "the text of an empty editor"

  attr :collab, :map,
    default: nil,
    doc: "credentials from Kotoba.Collab.token/3; enables the optional collaboration bundle"

  attr :nodes, :list,
    default: [],
    doc: "app nodes: `{module, js_url}` tuples, or JavaScript module URLs"

  attr :features, :list,
    default: nil,
    doc: "the built-in features of the editor, see `Kotoba.Features`; every feature by default"

  attr :extensions, :list,
    default: [],
    doc:
      "the URLs of the app's extension modules, see the Extensions guide; in the editor, after the features"

  attr :prompts, :list,
    default: [],
    doc:
      "the prompt list, see `Kotoba.Prompts`: a search callback, or options (`label`, `spaces`, `items`, `insert`...)"

  attr :assist, :any,
    default: nil,
    doc:
      "suggestions that the person asks for: a list of actions for the toolbar's Assist menu (`[rewrite: \"Rewrite\"]`), or `true` for no menu; the LiveView then handles `kotoba:assist` and `kotoba:suggestion`, see the Suggestions guide"

  attr :code_languages, :list,
    default: nil,
    doc:
      "the ids of the languages of the code language picker, see `Kotoba.CodeLanguages`; every language by default"

  attr :uploads, Phoenix.LiveView.UploadConfig,
    default: nil,
    doc: "an upload config, for example `@uploads.attachments`"

  attr :upload_label, :string, default: "Attach files", doc: "the label of the file input"

  attr :readonly, :boolean,
    default: false,
    doc:
      "when `true`, the editor shows the document and cannot change it; a change in a later render reaches the editor"

  attr :blank_lines, :atom,
    default: :keep,
    values: [:keep, :collapse],
    doc:
      "`:keep` saves the blank lines a person types (empty paragraphs between blocks), as a word processor does; `:collapse` leaves them out of the saved document"

  attr :paste_markdown, :boolean,
    default: true,
    doc:
      "when `true`, pasted plain text that reads as Markdown becomes rich text, read on the server by `Kotoba.MarkdownPaste`, which the editor renders with no code of the app; `false` renders no LiveComponent, for a template that cannot have one"

  attr :change, :boolean,
    default: false,
    doc:
      "when `true`, the editor pushes `kotoba:change` with the document on each change, and the LiveView (or the `phx-target` component) must handle it"

  attr :debounce, :integer,
    default: nil,
    doc: "milliseconds between `kotoba:change` pushes; 300 when not given"

  attr :selection_menu, :any,
    default: false,
    doc:
      "a menu over the selected text: `true` for the default commands (#{Enum.join(@selection_commands, ", ")}), or a list of commands, see `toolbar_commands/0`. The `selection` slot gives the app's own menu"

  attr :class, :any, default: nil, doc: "classes for the wrapper element"
  attr :rest, :global, doc: "attributes for the editor element"

  slot :selection,
    doc:
      "the app's own selection menu, for example `<.kotoba_selection_menu>` with the app's icons"

  slot :toolbar,
    doc:
      "a custom toolbar, for example `<.kotoba_toolbar>`; the default toolbar has the commands of the editor's features, but `subscript` and `superscript`"

  def kotoba(assigns) do
    %FormField{} = field = assigns.field
    input_id = field.id
    id = assigns.id || "#{field.id}_editor"

    assigns =
      assign(assigns,
        id: id,
        input_id: input_id,
        value: field_json(field.value),
        collab: assigns.collab && JSON.encode!(assigns.collab),
        node_urls: node_urls(assigns.nodes),
        triggers: json_map(Prompts.triggers(assigns.prompts)),
        prompt_labels: json_map(Prompts.labels(assigns.prompts)),
        prompt_config: json_map(Prompts.config(assigns.prompts)),
        assist: assist_actions(assigns.assist),
        selection_menu: selection_menu(assigns.selection_menu),
        code_languages: code_languages(assigns.code_languages),
        features: assigns.features && Enum.join(Features.names!(assigns.features), ","),
        feature_list:
          if(assigns.features, do: Features.names!(assigns.features), else: Features.all()),
        extension_urls: extension_urls(assigns.extensions),
        link_schemes: Enum.join(Sanitizer.allowed_schemes(), ","),
        aria_label: aria_label(assigns, field),
        upload_id: assigns.uploads && assigns.uploads.ref,
        described_by: assigns.rest[:"aria-describedby"],
        invalid: aria_state(assigns.rest[:"aria-invalid"]),
        rest: Map.drop(assigns.rest, [:"aria-describedby", :"aria-invalid"])
      )

    ~H"""
    <div class={["kotoba-field" | List.wrap(@class)]}>
      <input type="hidden" id={@input_id} name={@field.name} value={@value} />
      <div
        id={@id}
        phx-hook="Kotoba"
        phx-update="ignore"
        data-input={@input_id}
        data-collab={@collab}
        data-readonly={to_string(@readonly)}
        data-change={to_string(@change)}
        data-placeholder={@placeholder}
        data-nodes={@node_urls}
        data-prompts={@triggers}
        data-prompt-labels={@prompt_labels}
        data-prompt-config={@prompt_config}
        data-assist={@assist}
        data-selection-menu={@selection_menu}
        data-code-languages={@code_languages}
        data-features={@features}
        data-extensions={@extension_urls}
        data-upload={@upload_id}
        data-debounce={@debounce}
        data-link-schemes={@link_schemes}
        data-markdown={@paste_markdown && @id <> "-markdown"}
        data-blank-lines={if @blank_lines == :collapse, do: "collapse"}
        data-aria-describedby={@described_by}
        data-aria-invalid={@invalid}
        aria-labelledby={@label_id}
        aria-label={@aria_label}
        {@rest}
      >
        {render_slot(@toolbar)}
        {render_slot(@selection)}
      </div>
      <.live_component
        :if={@paste_markdown}
        module={Kotoba.MarkdownPaste}
        id={@id <> "-markdown"}
        features={@feature_list}
        nodes={node_modules(@nodes)}
      />
      <div :if={@uploads} class="kotoba-visually-hidden">
        <label for={@upload_id}>{@upload_label}</label>
        <.live_file_input upload={@uploads} tabindex="-1" />
      </div>
    </div>
    """
  end

  # LiveView patches only the data attributes of a `phx-update="ignore"`
  # element, so the state of the field goes in data attributes, and the
  # hook puts it on the editable area at mount and on every update.
  defp aria_state(value) when value in [nil, false, "false"], do: nil
  defp aria_state(value), do: to_string(value)

  # The editor always has an accessible name: the element of `label_id`, an
  # `aria-label` in the other attributes, `label`, or the field name.
  defp aria_label(%{label_id: id}, _field) when is_binary(id) and id != "", do: nil

  defp aria_label(assigns, field) do
    if Map.has_key?(assigns.rest, :"aria-label"),
      do: nil,
      else: assigns.label || Phoenix.Naming.humanize(field.field)
  end

  # No rendering here: this runs on every render of the form.
  defp field_json(value) do
    {:ok, doc} =
      with :error <- Content.to_doc(value), do: Content.to_doc(nil)

    JSON.encode!(doc)
  end

  defp node_urls([]), do: nil

  defp node_urls(nodes) do
    Enum.map_join(nodes, ",", fn
      {module, url} when is_atom(module) and is_binary(url) ->
        url

      url when is_binary(url) ->
        url

      other ->
        raise ArgumentError, "a Kotoba node must be {module, js_url}, got: #{inspect(other)}"
    end)
  end

  # The app node modules of `nodes`, for the registry of pasted Markdown.
  defp node_modules(nodes), do: for({module, _url} <- nodes, is_atom(module), do: module)

  defp extension_urls([]), do: nil

  defp extension_urls(urls) do
    Enum.map_join(urls, ",", fn
      url when is_binary(url) and url != "" ->
        if String.contains?(url, ","),
          do: raise(ArgumentError, "a Kotoba extension URL cannot have a comma: #{inspect(url)}"),
          else: url

      other ->
        raise ArgumentError, "a Kotoba extension must be a module URL, got: #{inspect(other)}"
    end)
  end

  defp code_languages(nil), do: nil

  defp code_languages([]),
    do: raise(ArgumentError, "code_languages needs at least one language, or nil for every one")

  defp code_languages(names), do: names |> CodeLanguages.ids!() |> Enum.join(",")

  # `data-assist`: the JSON of the Assist menu's actions, "[]" for `true`.
  defp assist_actions(nil), do: nil
  defp assist_actions(false), do: nil
  defp assist_actions(true), do: "[]"

  defp assist_actions(actions) when is_list(actions) do
    actions |> Enum.map(&assist_action!/1) |> JSON.encode!()
  end

  defp assist_actions(other),
    do: raise(ArgumentError, "assist must be true, or a list of actions, got: #{inspect(other)}")

  defp assist_action!({id, label}) when (is_atom(id) or is_binary(id)) and is_binary(label) do
    id = to_string(id)

    if id == "" or String.trim(label) == "",
      do:
        raise(
          ArgumentError,
          "an assist action needs an id and a label, got: #{inspect({id, label})}"
        )

    %{id: id, label: label}
  end

  defp assist_action!(%{id: id, label: label}), do: assist_action!({id, label})

  defp assist_action!(other) do
    raise ArgumentError,
          "an assist action is {id, label} or %{id: id, label: label}, got: #{inspect(other)}"
  end

  # `data-selection-menu`: "true" for the default commands, or the commands.
  defp selection_menu(value) when value in [nil, false], do: nil
  defp selection_menu(true), do: "true"
  defp selection_menu([]), do: nil

  defp selection_menu(commands) when is_list(commands),
    do: Enum.map_join(commands, ",", &command!(to_string(&1)))

  defp selection_menu(other) do
    raise ArgumentError,
          "selection_menu must be true, false or a list of commands, got: #{inspect(other)}"
  end

  defp json_map(map) when map_size(map) == 0, do: nil
  defp json_map(map), do: JSON.encode!(map)

  @doc """
  Renders a custom toolbar for an editor.

  Inside the `toolbar` slot of `kotoba/1`, it needs no `for`. Elsewhere on
  the page, give the editor's id as `for`: the toolbar then has
  `phx-update="ignore"` (and the id `<for>-toolbar`), so that a LiveView
  patch does not undo the state that the editor puts on its buttons.

  With no `button` slots, it renders one text button for each of
  `commands`. With `button` slots, it renders them, for example with the
  app's own icons:

      <.kotoba_toolbar for="post-body">
        <:button command="bold"><.icon name="hero-bold" /></:button>
        <:button command="link" label="Add a link"><.icon name="hero-link" /></:button>
      </.kotoba_toolbar>

  The editor adds `role="toolbar"`, the roving tabindex, `aria-pressed`
  and `aria-disabled`. The commands are the ones of `toolbar_commands/0`;
  or the command of an extension's control, `"<extension>:<command>"` (give
  it a `label`); another command raises `ArgumentError`. The editor hides
  the buttons of the features that it does not have (see
  `Kotoba.Features`), and the buttons of the `table-*` commands (the ones that act on the table at the selection)
  when the selection is not in a table, and the buttons of `gallery`,
  `image-previous` and `image-next` (the ones that act on the selected
  image) when no image is selected. `code-language` renders a
  `<select>`, the code language picker: the editor fills its options, and
  hides it when the selection is not in a code block. `highlight` opens the
  color palette of the editor (`aria-haspopup="dialog"`).
  """
  attr :for, :string, default: nil, doc: "the id of the editor, when the toolbar is outside it"
  attr :commands, :list, default: @command_names, doc: "the commands, when there are no buttons"
  attr :label, :string, default: "Formatting", doc: "the accessible name of the toolbar"
  attr :class, :any, default: nil, doc: "classes for the toolbar element"
  attr :rest, :global, doc: "attributes for the toolbar element"

  slot :button do
    attr :command, :string, required: true
    attr :label, :string
    attr :class, :any
  end

  def kotoba_toolbar(assigns) do
    assigns =
      assign(assigns,
        buttons: buttons(assigns),
        toolbar_id: assigns.for && "#{assigns.for}-toolbar"
      )

    ~H"""
    <div
      id={@toolbar_id}
      data-kotoba-toolbar={@for || ""}
      phx-update={@for && "ignore"}
      aria-label={@label}
      class={["kotoba-toolbar" | List.wrap(@class)]}
      {@rest}
    >
      <.command_button :for={button <- @buttons} button={button} />
    </div>
    """
  end

  @doc """
  Renders the app's own selection menu: the menu that floats over the
  selected text. Put it in the `selection` slot of `kotoba/1`:

      <.kotoba field={@form[:body]} id="post-body">
        <:selection>
          <.kotoba_selection_menu class="my-menu">
            <:button command="bold"><.icon name="hero-bold" /></:button>
            <:button command="italic"><.icon name="hero-italic" /></:button>
            <:button command="link" label="Add a link"><.icon name="hero-link" /></:button>
          </.kotoba_selection_menu>
        </:selection>
      </.kotoba>

  With no `button` slots, it renders one text button for each of
  `commands`. The commands, and what the editor does with the buttons, are
  the ones of `kotoba_toolbar/1`. The editor shows the menu over a
  selection of text, gives it the `kotoba-selection-menu` class and
  `data-placement` (`"top"` or `"bottom"`), and moves the focus to it with
  Alt+F10.
  """
  attr :commands, :list,
    default: @selection_commands,
    doc: "the commands, when there are no buttons"

  attr :label, :string,
    default: "Selection formatting",
    doc: "the accessible name of the menu"

  attr :class, :any, default: nil, doc: "classes for the menu element"
  attr :rest, :global, doc: "attributes for the menu element"

  slot :button do
    attr :command, :string, required: true
    attr :label, :string
    attr :class, :any
  end

  def kotoba_selection_menu(assigns) do
    assigns = assign(assigns, :buttons, buttons(assigns))

    ~H"""
    <div
      data-kotoba-selection-menu
      aria-label={@label}
      class={["kotoba-selection-menu" | List.wrap(@class)]}
      hidden
      {@rest}
    >
      <.command_button :for={button <- @buttons} button={button} />
    </div>
    """
  end

  defp buttons(%{button: [], commands: commands}),
    do: Enum.map(commands, &%{command: command!(&1), label: label(&1), slot: nil})

  defp buttons(%{button: slots}) do
    Enum.map(slots, fn slot ->
      command = command!(slot.command)
      %{command: command, label: slot[:label] || label(command), slot: slot}
    end)
  end

  attr :button, :map, required: true

  defp command_button(%{button: %{command: "code-language"}} = assigns) do
    ~H"""
    <select
      class={["kotoba-toolbar-select" | List.wrap(@button.slot && @button.slot[:class])]}
      data-kotoba-command={@button.command}
      aria-label={@button.label}
      title={@button.label}
    >
    </select>
    """
  end

  defp command_button(assigns) do
    ~H"""
    <button
      type="button"
      class={["kotoba-toolbar-button" | List.wrap(@button.slot && @button.slot[:class])]}
      data-kotoba-command={@button.command}
      aria-label={@button.slot && @button.label}
      title={@button.label}
    >
      {if @button.slot, do: render_slot(@button.slot), else: @button.label}
    </button>
    """
  end

  defp command!(command) when command in @command_names, do: command

  # An extension's control: `<extension>:<command>`.
  defp command!(command) when is_binary(command) do
    if Regex.match?(~r/\A[a-z][a-z0-9-]*:[a-z][a-z0-9-]*\z/, command),
      do: command,
      else: unknown_command!(command)
  end

  defp command!(command), do: unknown_command!(command)

  defp unknown_command!(command) do
    raise ArgumentError,
          "unknown Kotoba toolbar command #{inspect(command)}, use one of #{inspect(@command_names)} " <>
            "or an extension's \"<extension>:<command>\""
  end

  for {command, label, _group} <- @commands do
    defp label(unquote(command)), do: unquote(label)
  end

  defp label(command), do: command

  @doc """
  Renders a `Kotoba.Content` as safe HTML.

  The cached `:html` of the content is used when its cache version is the
  current one (`Kotoba.Content.cache_version/0`), the policy is `:default`
  and no extra `nodes` are given: this is the HTML that `Kotoba.Renderer`
  made when the content was cast. In every other case, the document is
  rendered again with `Kotoba.Renderer` (a document that no longer parses
  renders as nothing). `nil` renders an empty wrapper.
  """
  attr :content, :any, required: true, doc: "a `Kotoba.Content`, or `nil`"

  attr :policy, :any,
    default: :default,
    doc: "`:default` or `:untrusted`, see `Kotoba.Sanitizer`"

  attr :nodes, :list,
    default: [],
    doc:
      "extra node modules, `{module, js_url}` tuples, or JavaScript module URLs (the same list as `kotoba/1`; a URL has no module to render)"

  attr :class, :any, default: nil, doc: "classes for the wrapper, for example `\"prose\"`"
  attr :rest, :global, doc: "attributes for the wrapper"

  def kotoba_content(assigns) do
    assigns =
      assign(
        assigns,
        :html,
        content_html(assigns.content, assigns.policy, modules(assigns.nodes))
      )

    ~H"""
    <div class={["kotoba-content" | List.wrap(@class)]} {@rest}>{@html}</div>
    """
  end

  defp content_html(nil, _policy, _nodes), do: ""

  defp content_html(%Content{} = content, policy, nodes) do
    if cached?(content, policy, nodes),
      do: {:safe, content.html},
      else: render_doc(content.doc, policy, nodes)
  end

  defp content_html(other, _policy, _nodes) do
    raise ArgumentError, "kotoba_content needs a Kotoba.Content or nil, got: #{inspect(other)}"
  end

  defp cached?(%Content{html: html, version: version}, policy, nodes) do
    is_binary(html) and version == Content.cache_version() and nodes == [] and
      Sanitizer.policy(policy) == Sanitizer.policy(:default)
  end

  defp render_doc(doc, policy, nodes) do
    case Document.parse(doc, nodes: nodes) do
      {:ok, parsed} -> Renderer.to_html(parsed, policy: policy)
      {:error, _messages} -> ""
    end
  end

  # The `nodes` of `kotoba/1` can also hold a plain URL (an editor-only
  # node), which has no module to render.
  defp modules(nodes) do
    Enum.flat_map(nodes, fn
      {module, _url} when is_atom(module) -> [module]
      module when is_atom(module) -> [module]
      url when is_binary(url) -> []
    end)
  end
end
