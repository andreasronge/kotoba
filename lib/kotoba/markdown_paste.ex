defmodule Kotoba.MarkdownPaste do
  @moduledoc """
  The server's half of pasted Markdown: a LiveComponent that
  `Kotoba.Components.kotoba/1` renders next to each editor, so an app needs
  no event handler for it.

  When a person pastes plain text that reads as Markdown, the editor sends
  it here (`kotoba:markdown`), and the reply is the nodes that
  `Kotoba.Content.from_markdown/2` builds for it, with the features of the
  editor: a pasted README looks as it does on GitHub. Markdown of more than
  1 MB is refused, and the editor pastes it as plain text.
  """
  use Phoenix.LiveComponent

  alias Kotoba.Content.MarkdownImport
  alias Kotoba.{Document, Features}

  @max_bytes 1_000_000

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} hidden></div>
    """
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     assign(socket,
       id: assigns.id,
       features: assigns[:features] || Features.all(),
       nodes: assigns[:nodes] || []
     )}
  end

  @impl Phoenix.LiveComponent
  def handle_event("kotoba:markdown", %{"markdown" => markdown}, socket)
      when is_binary(markdown) and byte_size(markdown) <= @max_bytes do
    {:reply, %{nodes: nodes(markdown, socket.assigns)}, socket}
  end

  def handle_event("kotoba:markdown", _params, socket), do: {:reply, %{nodes: nil}, socket}

  @doc """
  Returns the JSON of the nodes for pasted Markdown, with the features of
  the editor (see `Kotoba.Content.from_markdown/2`), or `nil` when they do
  not make a valid document.
  """
  @spec nodes(String.t(), %{features: [atom()], nodes: [module()]}) :: [map()] | nil
  def nodes(markdown, %{features: features, nodes: nodes}) do
    root = MarkdownImport.root(markdown, features: features)
    envelope = %{"kotoba" => 1, "lexical" => "0.51", "root" => root}

    case Document.parse(envelope, nodes: nodes) do
      {:ok, _doc} -> root["children"]
      {:error, _messages} -> nil
    end
  end
end
