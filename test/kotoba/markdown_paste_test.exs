defmodule Kotoba.MarkdownPasteTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Kotoba.MarkdownPaste
  alias KotobaTest.EditorLive

  @endpoint KotobaTest.Endpoint
  @editor EditorLive.editor_id()

  test "the editor has the component that reads pasted Markdown, with no code of the app" do
    {:ok, view, html} = live(build_conn(), "/editor")
    assert html =~ ~s(data-markdown="#{@editor}-markdown")

    view
    |> with_target("##{@editor}-markdown")
    |> render_hook("kotoba:markdown", %{"v" => 1, "markdown" => "# Title\n\n- **a**\n- b"})

    assert_reply(view, %{nodes: [%{"type" => "heading", "tag" => "h1"}, %{"type" => "list"}]})
  end

  test "Markdown that is too long gets no nodes" do
    {:ok, view, _html} = live(build_conn(), "/editor")

    view
    |> with_target("##{@editor}-markdown")
    |> render_hook("kotoba:markdown", %{"markdown" => String.duplicate("a", 1_000_001)})

    assert_reply(view, %{nodes: nil})
  end

  test "the nodes have only the features of the editor" do
    assert [%{"type" => "paragraph", "children" => [%{"text" => "Title"}]}] =
             MarkdownPaste.nodes("# Title", %{features: [:bold], nodes: []})
  end
end
