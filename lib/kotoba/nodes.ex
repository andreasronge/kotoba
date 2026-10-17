defmodule Kotoba.Nodes do
  @moduledoc """
  The node registry.

  The registry maps each Lexical node type to the module that reads it. It
  has the built-in nodes, the nodes in the `:nodes` key of the `:kotoba`
  application config, and the nodes that the caller gives. An app node
  cannot have the type of a built-in node or of an editor node
  (`"kotoba-unknown"` or `"kotoba-upload"`, see `reserved_types/0`): the
  registry raises `ArgumentError`, as the editor refuses such a node. A caller node replaces a configured node with the
  same type:

      config :kotoba, nodes: [MyApp.Nodes.Pointer]

  `Kotoba.Document.parse/2`, `Kotoba.Content.rerender/2` and
  `Kotoba.Components.kotoba_content/1` take the caller's nodes as a
  `nodes` option. `Kotoba.Content.cast/1` uses the built-in and the
  configured nodes only, so put a node that stored content uses in the
  config. `mix kotoba.gen.node` writes a new node module and its editor
  half.
  """

  alias Kotoba.Nodes

  @built_in [
    Nodes.Root,
    Nodes.Paragraph,
    Nodes.Heading,
    Nodes.Quote,
    Nodes.List,
    Nodes.ListItem,
    Nodes.Text,
    Nodes.Tab,
    Nodes.LineBreak,
    Nodes.Link,
    Nodes.AutoLink,
    Nodes.Code,
    Nodes.CodeHighlight,
    Nodes.HorizontalRule,
    Nodes.Table,
    Nodes.TableRow,
    Nodes.TableCell,
    Nodes.Attachment,
    Nodes.Gallery,
    Nodes.Mention,
    Nodes.Image,
    Nodes.FootnoteReference,
    Nodes.FootnoteDefinition
  ]

  # The editor's own node types: a node for a type it does not know, and
  # the marker of an upload in progress.
  @editor_types ["kotoba-unknown", "kotoba-upload"]

  @typedoc "A map from a node type to its module."
  @type registry :: %{String.t() => module()}

  @doc "Returns the built-in node modules."
  @spec built_in() :: [module()]
  def built_in, do: @built_in

  @doc """
  Returns the node types that an app node cannot have: the types of the
  built-in nodes, and the editor's own node types, `"kotoba-unknown"` (the
  node for a type it does not know) and `"kotoba-upload"` (the marker of
  an upload in progress).
  """
  @spec reserved_types() :: [String.t()]
  def reserved_types, do: Enum.map(@built_in, & &1.type()) ++ @editor_types

  @doc """
  Returns the registry for a list of extra node modules.

  Raises `ArgumentError` when a module does not use `Kotoba.Node`, or when
  the type of a configured node or of a node in `nodes` is a reserved type
  (see `reserved_types/0`).
  """
  @spec registry([module()]) :: registry()
  def registry(nodes \\ []) when is_list(nodes) do
    configured = Application.get_env(:kotoba, :nodes, [])
    built_in = Map.new(@built_in, &{&1.type(), &1})

    Enum.reduce(configured ++ nodes, built_in, fn module, registry ->
      type = app_type!(module)
      Map.put(registry, type, module)
    end)
  end

  defp app_type!(module) do
    unless Kotoba.Node.node_module?(module) do
      raise ArgumentError, "#{inspect(module)} is not a Kotoba.Node module"
    end

    type = module.type()

    if type in reserved_types() do
      raise ArgumentError,
            "#{inspect(module)} has the type #{inspect(type)}, which is reserved for a " <>
              "built-in node; give it another type"
    end

    type
  end
end
