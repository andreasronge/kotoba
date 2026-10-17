defmodule Kotoba.LiveTest do
  # The local storage root is application config.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Kotoba.{Content, TestJSON}
  alias KotobaTest.EditorLive

  @endpoint KotobaTest.Endpoint
  @editor EditorLive.editor_id()
  @png <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", 40::32, 30::32, 8, 6, 0, 0, 0>>

  setup do
    root = Path.join(System.tmp_dir!(), "kotoba-live-#{System.unique_integer([:positive])}")
    Application.put_env(:kotoba, Kotoba.Storage.Local, root: root, url_prefix: "/files")

    on_exit(fn ->
      Application.delete_env(:kotoba, Kotoba.Storage.Local)
      File.rm_rf!(root)
    end)

    {:ok, view, html} = live(build_conn(), "/editor")
    %{view: view, html: html, root: root}
  end

  test "the page renders the editor with its prompts and upload input", %{html: html} do
    doc = LazyHTML.from_document(html)
    editor = LazyHTML.query(doc, "##{@editor}")

    assert LazyHTML.attribute(editor, "phx-hook") == ["Kotoba"]
    assert LazyHTML.attribute(editor, "aria-labelledby") == ["body-label"]

    assert [prompts] = LazyHTML.attribute(editor, "data-prompts")

    assert JSON.decode!(prompts) == %{
             "@" => "people",
             "#" => "work",
             "!" => "broken",
             "+" => "slow",
             "~" => "slow_broken",
             ":" => "emoji"
           }

    assert [config] = LazyHTML.attribute(editor, "data-prompt-config")

    assert JSON.decode!(config) == %{
             "slow" => %{"spaces" => true},
             "emoji" => %{
               "insert" => "text",
               "items" => [%{"id" => "tada", "label" => "tada", "text" => "🎉"}]
             }
           }

    assert [upload] = LazyHTML.attribute(editor, "data-upload")
    assert LazyHTML.query(doc, "input[type=file]##{upload}") |> Enum.count() == 1
  end

  describe "handle_prompt/3" do
    test "pushes the items of the prompt, with the editor id and the query", %{view: view} do
      render_hook(view, "kotoba:prompt", %{
        "v" => 1,
        "id" => @editor,
        "prompt" => "people",
        "query" => "ada"
      })

      assert_push_event(view, "kotoba:prompt_results", %{
        v: 1,
        id: @editor,
        prompt: "people",
        query: "ada",
        items: [%{id: "1", label: "Ada Lovelace", hint: "Engineering"}]
      })
    end

    test "gives the socket to a callback of arity 2", %{view: view} do
      render_hook(view, "kotoba:prompt", %{"id" => @editor, "prompt" => "work", "query" => "q"})

      assert_push_event(view, "kotoba:prompt_results", %{prompt: "work", items: [item]})
      assert item.label == "Work: q"
      assert "w-phx-" <> _rest = item.id
    end

    test "gives no items for a callback that raises, and the LiveView stays alive", %{
      view: view
    } do
      log =
        capture_log(fn ->
          render_hook(view, "kotoba:prompt", %{
            "id" => @editor,
            "prompt" => "broken",
            "query" => "a"
          })

          assert_push_event(view, "kotoba:prompt_results", %{
            id: @editor,
            prompt: "broken",
            items: []
          })
        end)

      assert log =~ ~s(the Kotoba prompt "broken" failed)
      assert Process.alive?(view.pid)

      render_hook(view, "kotoba:prompt", %{
        "id" => @editor,
        "prompt" => "people",
        "query" => "ada"
      })

      assert_push_event(view, "kotoba:prompt_results", %{prompt: "people", items: [_ada]})
    end

    test "a failed search has error: true", %{view: view} do
      capture_log(fn ->
        render_hook(view, "kotoba:prompt", %{
          "id" => @editor,
          "prompt" => "broken",
          "query" => "a"
        })

        assert_push_event(view, "kotoba:prompt_results", %{prompt: "broken", error: true})
      end)
    end

    test "runs an async search in a task, and pushes its items from handle_async", %{view: view} do
      render_hook(view, "kotoba:prompt", %{
        "id" => @editor,
        "prompt" => "slow",
        "query" => "ada love"
      })

      assert_push_event(view, "kotoba:prompt_results", %{
        id: @editor,
        prompt: "slow",
        query: "ada love",
        items: [%{id: pid, label: "Slow: ada love"}]
      })

      refute pid == inspect(view.pid)
    end

    test "an async search that fails pushes error: true", %{view: view} do
      log =
        capture_log(fn ->
          render_hook(view, "kotoba:prompt", %{
            "id" => @editor,
            "prompt" => "slow_broken",
            "query" => "a"
          })

          assert_push_event(view, "kotoba:prompt_results", %{
            prompt: "slow_broken",
            query: "a",
            items: [],
            error: true
          })
        end)

      assert log =~ ~s(the Kotoba prompt "slow_broken" failed)
      assert Process.alive?(view.pid)
    end

    test "an async search that exits pushes error: true, with its query", %{view: view} do
      log =
        capture_log(fn ->
          send(
            view.pid,
            {:async_result, {:kotoba_prompt, @editor, "slow", "q"}, {:exit, :killed}}
          )

          assert_push_event(view, "kotoba:prompt_results", %{
            id: @editor,
            prompt: "slow",
            query: "q",
            items: [],
            error: true
          })
        end)

      assert log =~ ~s(the Kotoba prompt "slow" exited: :killed)
    end

    test "gives no items for an unknown prompt", %{view: view} do
      render_hook(view, "kotoba:prompt", %{"id" => @editor, "prompt" => "nope", "query" => "a"})
      assert_push_event(view, "kotoba:prompt_results", %{prompt: "nope", items: []})
    end

    test "gives no items for a query that is too long", %{view: view} do
      query = String.duplicate("a", 65)

      render_hook(view, "kotoba:prompt", %{
        "id" => @editor,
        "prompt" => "people",
        "query" => query
      })

      assert_push_event(view, "kotoba:prompt_results", %{query: ^query, items: []})
    end

    test "ignores a payload without a prompt", %{view: view} do
      render_hook(view, "kotoba:prompt", %{"id" => @editor})
      refute_push_event(view, "kotoba:prompt_results", %{})
    end
  end

  describe "server pushes" do
    test "push_content/3 pushes set_content with the document", %{view: view} do
      content = Content.from_markdown("Hello")
      send(view.pid, {:push_content, content})

      assert_push_event(view, "set_content", %{v: 1, id: @editor, doc: doc})
      assert doc == content.doc
    end

    test "push_content/3 casts a document envelope", %{view: view} do
      envelope = TestJSON.envelope([TestJSON.paragraph([TestJSON.text("x")])])
      send(view.pid, {:push_content, envelope})

      assert_push_event(view, "set_content", %{id: @editor, doc: %{"kotoba" => 1}})
    end

    test "insert_node/3 pushes the node in its JSON form", %{view: view} do
      node = %Kotoba.Nodes.Attachment{
        key: "k",
        url: "/files/k",
        name: "a.pdf",
        content_type: "application/pdf",
        bytes: 3
      }

      send(view.pid, {:insert_node, node})

      assert_push_event(view, "insert_node", %{v: 1, id: @editor, node: json})

      assert json == %{
               "type" => "attachment",
               "version" => 1,
               "key" => "k",
               "url" => "/files/k",
               "name" => "a.pdf",
               "contentType" => "application/pdf",
               "bytes" => 3
             }
    end

    test "insert_node/3 pushes a mention", %{view: view} do
      send(view.pid, {:insert_node, %Kotoba.Nodes.Mention{kind: "people", id: "1", label: "Ada"}})

      assert_push_event(view, "insert_node", %{
        node: %{"type" => "mention", "kind" => "people", "id" => "1", "label" => "Ada"}
      })
    end

    test "set_readonly/3, focus/2 and remove_marker/3", %{view: view} do
      send(view.pid, {:set_readonly, true})
      assert_push_event(view, "set_readonly", %{v: 1, id: @editor, readonly: true})

      send(view.pid, :focus)
      assert_push_event(view, "focus", %{v: 1, id: @editor})

      send(view.pid, {:remove_marker, "3"})
      assert_push_event(view, "remove_marker", %{v: 1, id: @editor, ref: "3"})
    end
  end

  describe "the stream functions" do
    test "push a suggestion's start, chunks, end and cancel", %{view: view} do
      send(
        view.pid,
        {:stream, :stream_start, ["r1", [at: :after, format: :text, label: "Rewrite"]]}
      )

      assert_push_event(view, "kotoba:stream", %{
        v: 1,
        id: @editor,
        ref: "r1",
        op: "start",
        at: "after",
        format: "text",
        label: "Rewrite"
      })

      send(view.pid, {:stream, :stream_start, ["r2", []]})

      assert_push_event(
        view,
        "kotoba:stream",
        %{
          ref: "r2",
          op: "start",
          at: "selection",
          format: "markdown"
        } = start
      )

      refute Map.has_key?(start, :label)

      send(view.pid, {:stream, :stream_chunk, ["r2", "Hello **wo"]})
      assert_push_event(view, "kotoba:stream", %{ref: "r2", op: "chunk", text: "Hello **wo"})

      send(view.pid, {:stream, :stream_end, ["r2"]})
      assert_push_event(view, "kotoba:stream", %{v: 1, id: @editor, ref: "r2", op: "end"})

      send(view.pid, {:stream, :stream_cancel, ["r1"]})
      assert_push_event(view, "kotoba:stream", %{ref: "r1", op: "cancel"})
    end

    test "refuse a target or a format that is not one" do
      socket = %Phoenix.LiveView.Socket{}

      assert_raise ArgumentError, ~r/:at must be one of/, fn ->
        Kotoba.Live.stream_start(socket, @editor, "r", at: :top)
      end

      assert_raise ArgumentError, ~r/:format must be one of/, fn ->
        Kotoba.Live.stream_start(socket, @editor, "r", format: :html)
      end
    end

    test "stream_ref/0 gives a new ref each time" do
      refs = for _ <- 1..50, do: Kotoba.Live.stream_ref()
      assert length(Enum.uniq(refs)) == 50
      assert Enum.all?(refs, &Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, &1))
    end
  end

  describe "consume_uploads/4" do
    test "stores an image and pushes an attachment node for its entry", %{view: view, root: root} do
      upload =
        file_input(view, "#post-form", :attachments, [
          %{name: "My cat.png", content: @png, type: "image/png"}
        ])

      [entry_ref] = entry_refs(upload)
      render_upload(upload, "My cat.png")

      assert_push_event(view, "insert_node", %{id: @editor, ref: ^entry_ref, node: node})

      assert %{
               "type" => "attachment",
               "name" => "My cat.png",
               "contentType" => "image/png",
               "bytes" => bytes,
               "width" => 40,
               "height" => 30,
               "key" => key,
               "url" => url
             } = node

      assert bytes == byte_size(@png)
      assert key =~ ~r"\A\d{4}/\d{2}/[0-9a-f-]{36}-My_cat\.png\z"
      assert url == "/files/" <> key
      assert File.read!(Path.join(root, key)) == @png
    end

    @tag :multi_upload
    test "stores files that finish one after the other, each once", %{view: view} do
      upload =
        file_input(view, "#post-form", :attachments, [
          %{name: "a.png", content: @png, type: "image/png"},
          %{name: "b.png", content: @png, type: "image/png"}
        ])

      [a, b] = entry_refs(upload)
      render_upload(upload, "a.png")
      assert_push_event(view, "insert_node", %{ref: ^a, node: %{"name" => "a.png"}})

      # A form change before LiveView drops the first entry, then the second
      # file: the first is not consumed again.
      view |> element("#post-form") |> render_change(%{"post" => %{"body" => ""}})
      render_upload(upload, "b.png")
      assert_push_event(view, "insert_node", %{ref: ^b, node: %{"name" => "b.png"}})
      refute_push_event(view, "insert_node", %{ref: ^a})
      assert Process.alive?(view.pid)
    end

    test ":preview gives the attachment a preview URL, made while the file is there" do
      {:ok, view, _html} = live(build_conn(), "/editor?preview=ok")

      upload =
        file_input(view, "#post-form", :attachments, [
          %{name: "cat.png", content: @png, type: "image/png"}
        ])

      render_upload(upload, "cat.png")
      assert_push_event(view, "insert_node", %{node: %{"preview" => "/previews/cat.png.jpg"}})
    end

    for {preview, reason} <- [{"unsafe", "unsafe_url"}, {"raise", "no renderer"}] do
      test ":preview that gives #{preview} leaves the attachment with no preview" do
        {:ok, view, _html} = live(build_conn(), "/editor?preview=#{unquote(preview)}")

        upload =
          file_input(view, "#post-form", :attachments, [
            %{name: "cat.png", content: @png, type: "image/png"}
          ])

        log =
          capture_log(fn ->
            render_upload(upload, "cat.png")
            assert_push_event(view, "insert_node", %{node: node})
            refute Map.has_key?(node, "preview")
          end)

        assert log =~ ~s(no preview for the upload "cat.png")
        assert log =~ unquote(reason)
      end
    end

    test "does not trust the browser's image type", %{view: view} do
      upload =
        file_input(view, "#post-form", :attachments, [
          %{name: "fake.png", content: "<svg onload=alert(1)>", type: "image/png"}
        ])

      render_upload(upload, "fake.png")

      assert_push_event(view, "insert_node", %{
        node: %{"contentType" => "application/octet-stream"} = node
      })

      refute Map.has_key?(node, "width")
      assert node["name"] == "fake.png"
      assert String.ends_with?(node["key"], "-fake.bin")
    end

    for {storage, reason, deleted?} <- [
          {"failing", ":disk_full", false},
          {"unsafe", "unsafe_url", true},
          {"broken", "invalid_storage_result", true}
        ] do
      test "logs and removes the marker when the #{storage} storage gives no valid attachment" do
        Process.register(self(), :kotoba_storage_test)
        {:ok, view, _html} = live(build_conn(), "/editor?storage=#{unquote(storage)}")

        upload =
          file_input(view, "#post-form", :attachments, [
            %{name: "notes.txt", content: "hello", type: "text/plain"}
          ])

        [entry_ref] = entry_refs(upload)

        log =
          capture_log(fn ->
            render_upload(upload, "notes.txt")
            assert_push_event(view, "remove_marker", %{id: @editor, ref: ^entry_ref})
          end)

        assert log =~ ~s(the upload "notes.txt" was not stored)
        assert log =~ unquote(reason)
        refute_push_event(view, "insert_node", %{})
        assert Process.alive?(view.pid)

        # A file that the adapter stored, with a result that gives no valid
        # attachment, is deleted. A failed put stored nothing.
        if unquote(deleted?) do
          assert_received {:deleted, key}
          assert String.ends_with?(key, "-notes.txt")
        else
          refute_received {:deleted, _key}
        end
      end
    end

    test "cancels an entry that fails validation and removes its marker", %{view: view} do
      upload =
        file_input(view, "#post-form", :attachments, [
          %{name: "big.txt", content: String.duplicate("a", 2_000), type: "text/plain"}
        ])

      [entry_ref] = entry_refs(upload)
      assert {:ok, %{errors: %{^entry_ref => [:too_large]}}} = preflight_upload(upload)

      view |> element("#post-form") |> render_change(%{"post" => %{"body" => ""}})

      assert_push_event(view, "remove_marker", %{id: @editor, ref: ^entry_ref})
      refute render(view) =~ "big.txt"
    end
  end

  defp entry_refs(upload), do: Enum.map(upload.entries, & &1["ref"])
end
