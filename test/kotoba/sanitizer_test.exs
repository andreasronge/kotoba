defmodule Kotoba.SanitizerTest do
  use ExUnit.Case, async: false

  alias Kotoba.Nodes
  alias Kotoba.Sanitizer

  doctest Kotoba.Sanitizer

  describe "link_url/2" do
    test "accepts http, https and mailto URLs, in any case" do
      for url <- ["http://a.b", "https://a.b/c?d=e#f", "mailto:a@b.c", "HTTPS://A.B"] do
        assert Sanitizer.link_url(url) == url
      end
    end

    test "accepts relative URLs" do
      for url <- [
            "/a",
            "a/b",
            "../c",
            "#top",
            "?q=1",
            "//a.b/c",
            "/a:b"
          ] do
        assert Sanitizer.link_url(url) == url
      end
    end

    test "trims the URL" do
      assert Sanitizer.link_url("  https://a.b  ") == "https://a.b"
    end

    test "refuses other schemes" do
      for url <- [
            "javascript:alert(1)",
            "JAVASCRIPT:alert(1)",
            " javascript:alert(1)",
            "vbscript:x",
            "data:text/html;base64,PHNjcmlwdD4=",
            "file:///etc/passwd",
            "tel:+100"
          ] do
        assert Sanitizer.link_url(url) == nil, url
      end
    end

    test "refuses control characters, empty and long URLs, and values that are not strings" do
      for url <- [
            "java\tscript:alert(1)",
            "java\nscript:x",
            "/a\u0000b",
            "/a\u0085b",
            "",
            "   ",
            nil,
            1
          ] do
        assert Sanitizer.link_url(url) == nil
      end

      assert Sanitizer.link_url("/" <> String.duplicate("a", 2047))
      refute Sanitizer.link_url("/" <> String.duplicate("a", 2048))
    end

    test "reads the schemes from the options, then from the config" do
      assert Sanitizer.link_url("tel:+100", schemes: ["TEL"]) == "tel:+100"
      refute Sanitizer.link_url("https://a.b", schemes: ["tel"])

      Application.put_env(:kotoba, :allowed_link_schemes, ~w(https tel))
      on_exit(fn -> Application.delete_env(:kotoba, :allowed_link_schemes) end)

      assert Sanitizer.link_url("tel:+100") == "tel:+100"
      refute Sanitizer.link_url("mailto:a@b.c")
    end
  end

  describe "policy/1" do
    test "the two policies" do
      assert Sanitizer.policy(:default) == %{name: :default, links: true, attachments: true}
      assert Sanitizer.policy(:untrusted) == %{name: :untrusted, links: false, attachments: false}
    end

    test "returns a policy map with no change" do
      policy = Sanitizer.policy(:untrusted)
      assert Sanitizer.policy(policy) == policy
    end

    test "raises for an unknown policy" do
      assert_raise ArgumentError, fn -> Sanitizer.policy(:none) end
    end
  end

  describe "check/3" do
    test "accepts a valid node in a valid parent" do
      item = %Nodes.ListItem{children: [%Nodes.Text{text: "a"}]}
      assert :ok = Sanitizer.check(item, %Nodes.List{list_type: "bullet", tag: "ul"})
      assert :ok = Sanitizer.check(%Nodes.Root{}, nil)
      assert :ok = Sanitizer.check(%Nodes.Unknown{type: "x", raw: %{}}, %Nodes.Code{})
    end

    test "refuses a node that is not valid" do
      assert {:error, "text is required"} = Sanitizer.check(%Nodes.Text{}, nil)
    end

    test "bounds the labels and the URLs" do
      mention = %Nodes.Mention{kind: "p", id: "1", label: String.duplicate("a", 200)}
      assert :ok = Sanitizer.check(mention, nil)

      assert {:error, "label is longer than 200 characters"} =
               Sanitizer.check(%{mention | label: mention.label <> "a"}, nil)

      attachment = %Nodes.Attachment{
        key: String.duplicate("k", 2049),
        url: "/a",
        name: "a",
        content_type: "text/plain",
        bytes: 1
      }

      assert {:error, "key is longer than 2048 characters"} = Sanitizer.check(attachment, nil)
    end

    test "the text of a text node is not bounded" do
      assert :ok = Sanitizer.check(%Nodes.Text{text: String.duplicate("a", 5000) <> "\t"}, nil)
    end

    test "refuses an attachment with a URL that is not safe" do
      attachment = %Nodes.Attachment{
        key: "k",
        url: "javascript:x",
        name: "a",
        content_type: "text/plain",
        bytes: 1
      }

      assert {:error, "url is not a safe URL"} = Sanitizer.check(attachment, nil)
    end

    test "checks the nesting" do
      list = %Nodes.List{list_type: "bullet", tag: "ul"}
      text = %Nodes.Text{text: "a"}

      assert {:error, "a list holds only list items"} = Sanitizer.check(text, list)
      assert {:error, _reason} = Sanitizer.check(%Nodes.Paragraph{}, %Nodes.Code{})
      assert :ok = Sanitizer.check(%Nodes.LineBreak{}, %Nodes.Code{})
      assert {:error, _reason} = Sanitizer.check(%Nodes.Quote{}, %Nodes.Paragraph{})

      assert {:error, "a link holds no other link"} =
               Sanitizer.check(%Nodes.Link{url: "/a"}, %Nodes.AutoLink{url: "/b"})
    end

    test "a tab is allowed in a code block" do
      assert :ok = Sanitizer.check(%Nodes.Tab{}, %Nodes.Code{})
    end

    test "a horizontal rule and an attachment are valid only under the root, a list item or a table cell" do
      attachment = %Nodes.Attachment{key: "k", url: "/a", name: "a", content_type: "t", bytes: 1}
      rule = %Nodes.HorizontalRule{}

      # The children of the root node have the root struct as their
      # parent, not `nil` (only the root node's own check has a `nil`
      # parent) — see `Kotoba.RendererTest` for the end-to-end HTML check.
      assert :ok = Sanitizer.check(rule, %Nodes.Root{})
      assert :ok = Sanitizer.check(attachment, %Nodes.Root{})
      assert :ok = Sanitizer.check(rule, %Nodes.ListItem{})
      assert :ok = Sanitizer.check(attachment, %Nodes.ListItem{})
      assert :ok = Sanitizer.check(rule, %Nodes.TableCell{})
      assert :ok = Sanitizer.check(attachment, %Nodes.TableCell{})

      for parent <- [%Nodes.Paragraph{}, %Nodes.Heading{tag: "h1"}, %Nodes.Quote{}] do
        assert {:error, _reason} = Sanitizer.check(rule, parent)
        assert {:error, _reason} = Sanitizer.check(attachment, parent)
      end
    end

    test "a gallery is valid only under the root, and holds only attachments" do
      attachment = %Nodes.Attachment{key: "k", url: "/a", name: "a", content_type: "t", bytes: 1}
      gallery = %Nodes.Gallery{}

      assert :ok = Sanitizer.check(gallery, %Nodes.Root{})
      assert :ok = Sanitizer.check(attachment, gallery)

      for parent <- [%Nodes.ListItem{}, %Nodes.TableCell{}, %Nodes.Quote{}, %Nodes.Gallery{}] do
        assert {:error, _reason} = Sanitizer.check(gallery, parent)
      end

      for child <- [%Nodes.Paragraph{}, %Nodes.Text{text: "a"}, %Nodes.HorizontalRule{}] do
        assert {:error, "a gallery holds only attachments"} = Sanitizer.check(child, gallery)
      end
    end

    test "a table is valid only under the root, and holds only rows" do
      table = %Nodes.Table{}
      row = %Nodes.TableRow{}
      cell = %Nodes.TableCell{}

      assert :ok = Sanitizer.check(table, %Nodes.Root{})

      for parent <- [%Nodes.TableCell{}, %Nodes.ListItem{}, %Nodes.Quote{}, %Nodes.Paragraph{}] do
        assert {:error, "a table is valid only under the root" <> _rest} =
                 Sanitizer.check(table, parent)
      end

      assert :ok = Sanitizer.check(row, table)

      assert {:error, "a table holds only table rows"} =
               Sanitizer.check(%Nodes.Paragraph{}, table)

      assert {:error, "a table cell must be inside a table row"} = Sanitizer.check(cell, table)
    end

    test "a table row is valid only in a table, and holds only cells" do
      row = %Nodes.TableRow{}

      assert :ok = Sanitizer.check(%Nodes.TableCell{}, row)

      assert {:error, "a table row holds only table cells"} =
               Sanitizer.check(%Nodes.Text{text: "x"}, row)

      for parent <- [nil, %Nodes.Root{}, %Nodes.TableCell{}, %Nodes.ListItem{}] do
        assert {:error, "a table row must be inside a table"} = Sanitizer.check(row, parent)
      end
    end

    test "a table cell holds blocks and inline nodes" do
      cell = %Nodes.TableCell{}

      for node <- [
            %Nodes.Paragraph{},
            %Nodes.Heading{tag: "h2"},
            %Nodes.Quote{},
            %Nodes.List{list_type: "bullet", tag: "ul"},
            %Nodes.Code{},
            %Nodes.Text{text: "x"}
          ] do
        assert :ok = Sanitizer.check(node, cell)
      end

      assert {:error, "a table cell must be inside a table row"} =
               Sanitizer.check(cell, %Nodes.Root{})
    end

    test "a table cell checks its header state and spans" do
      row = %Nodes.TableRow{}

      assert :ok =
               Sanitizer.check(
                 %Nodes.TableCell{header_state: 3, col_span: 2, row_span: 1000},
                 row
               )

      assert {:error, "headerState must be one of: 0, 1, 2, 3"} =
               Sanitizer.check(%Nodes.TableCell{header_state: 4}, row)

      assert {:error, "colSpan must be from 1 to 1000"} =
               Sanitizer.check(%Nodes.TableCell{col_span: 0}, row)

      assert {:error, "rowSpan must be from 1 to 1000"} =
               Sanitizer.check(%Nodes.TableCell{row_span: 1001}, row)
    end

    test "a list item holds only one nested list, by position, even when the lists are identical" do
      inner = %Nodes.List{list_type: "bullet", tag: "ul", children: [%Nodes.ListItem{}]}
      item = %Nodes.ListItem{children: [inner, inner]}

      assert :ok = Sanitizer.check(inner, item, index: 0)

      assert {:error, "a list item holds only one nested list"} =
               Sanitizer.check(inner, item, index: 1)
    end

    test "a list item outside a list is refused" do
      assert {:error, "a list item must be inside a list"} =
               Sanitizer.check(%Nodes.ListItem{}, nil)

      assert {:error, "a list item must be inside a list"} =
               Sanitizer.check(%Nodes.ListItem{}, %Nodes.Paragraph{})

      assert :ok = Sanitizer.check(%Nodes.ListItem{}, %Nodes.List{list_type: "bullet", tag: "ul"})
    end
  end
end
