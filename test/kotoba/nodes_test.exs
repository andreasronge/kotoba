defmodule Kotoba.NodesTest do
  use ExUnit.Case, async: false

  alias Kotoba.Nodes

  doctest Kotoba.Nodes.Text
  doctest Kotoba.Nodes.Attachment

  defmodule Chip do
    use Kotoba.Node, type: "chip", kind: :decorator
    field :label, :string, required: true

    @impl Kotoba.Node
    def render_html(node, _opts), do: Phoenix.HTML.html_escape(node.label)

    @impl Kotoba.Node
    def render_text(node, _opts), do: node.label
  end

  defmodule OtherChip do
    use Kotoba.Node, type: "chip", kind: :decorator

    @impl Kotoba.Node
    def render_html(_node, _opts), do: ""

    @impl Kotoba.Node
    def render_text(_node, _opts), do: ""
  end

  defmodule FakeMention do
    use Kotoba.Node, type: "mention", kind: :decorator

    @impl Kotoba.Node
    def render_html(_node, _opts), do: ""

    @impl Kotoba.Node
    def render_text(_node, _opts), do: ""
  end

  defmodule FakeUnknown do
    use Kotoba.Node, type: "kotoba-unknown", kind: :decorator

    @impl Kotoba.Node
    def render_html(_node, _opts), do: ""

    @impl Kotoba.Node
    def render_text(_node, _opts), do: ""
  end

  defmodule FakeUpload do
    use Kotoba.Node, type: "kotoba-upload", kind: :decorator

    @impl Kotoba.Node
    def render_html(_node, _opts), do: ""

    @impl Kotoba.Node
    def render_text(_node, _opts), do: ""
  end

  setup do
    on_exit(fn -> Application.delete_env(:kotoba, :nodes) end)
  end

  test "the registry maps each built-in type to its module" do
    registry = Nodes.registry()

    assert Map.keys(registry) |> Enum.sort() ==
             Enum.sort(
               ~w(root paragraph heading quote list listitem text tab linebreak link autolink code
                          code-highlight horizontalrule attachment gallery mention table tablerow tablecell
                          image footnotereference footnotedefinition)
             )

    assert registry["listitem"] == Nodes.ListItem
  end

  test "the registry adds a given node" do
    assert Nodes.registry([Chip])["chip"] == Chip
    assert Nodes.registry([Chip])["mention"] == Nodes.Mention
  end

  test "the registry reads the application config" do
    Application.put_env(:kotoba, :nodes, [Chip])
    assert Nodes.registry()["chip"] == Chip
  end

  test "a given node replaces a configured node of the same type" do
    Application.put_env(:kotoba, :nodes, [Chip])
    assert Nodes.registry([OtherChip])["chip"] == OtherChip
  end

  test "the reserved types are the built-in types and the editor's own types" do
    assert "paragraph" in Nodes.reserved_types()
    assert "mention" in Nodes.reserved_types()
    assert "kotoba-unknown" in Nodes.reserved_types()
    assert "kotoba-upload" in Nodes.reserved_types()
  end

  test "the registry refuses a given node with a built-in type" do
    message =
      ~s(Kotoba.NodesTest.FakeMention has the type "mention", which is reserved for a built-in node; give it another type)

    assert_raise ArgumentError, message, fn -> Nodes.registry([FakeMention]) end
  end

  test "the registry refuses a configured node with a built-in type" do
    Application.put_env(:kotoba, :nodes, [FakeMention])
    assert_raise ArgumentError, ~r/FakeMention has the type "mention"/, fn -> Nodes.registry() end

    assert_raise ArgumentError, ~r/reserved for a built-in node/, fn ->
      Kotoba.Content.cast(%{"type" => "root", "children" => []})
    end
  end

  test "the registry refuses the editor's kotoba-unknown type" do
    assert_raise ArgumentError, ~r/"kotoba-unknown"/, fn -> Nodes.registry([FakeUnknown]) end
  end

  test "the reserved types include the editor's own types of assets/src/protocol.ts" do
    protocol = File.read!(Path.expand("../../assets/src/protocol.ts", __DIR__))

    for constant <- ~w(UNKNOWN_TYPE UPLOAD_MARKER_TYPE) do
      [type] =
        Regex.run(~r/export const #{constant} = "([^"]+)";/, protocol, capture: :all_but_first)

      assert type in Nodes.reserved_types(), "#{constant} (#{type}) is not reserved"
    end
  end

  test "registry/1 refuses an app node with the type kotoba-upload" do
    [{module, _binary}] =
      Code.compile_string("""
      defmodule Kotoba.NodesTest.ProbeUpload do
        use Kotoba.Node, type: "kotoba-upload", kind: :inline
        @impl Kotoba.Node
        def render_html(_node, _opts), do: ""
        @impl Kotoba.Node
        def render_text(_node, _opts), do: ""
      end
      """)

    assert_raise ArgumentError, ~r/has the type "kotoba-upload", which is reserved/, fn ->
      Nodes.registry([module])
    end
  end

  test "the registry refuses the editor's kotoba-upload type" do
    assert_raise ArgumentError, ~r/"kotoba-upload"/, fn ->
      Nodes.registry([FakeUpload])
    end
  end

  test "the registry refuses a module that is not a node" do
    assert_raise ArgumentError, ~r/not a Kotoba.Node module/, fn -> Nodes.registry([String]) end
  end

  describe "Kotoba.Nodes.Text" do
    test "formats/1 reads every bit" do
      assert Nodes.Text.formats(2047) ==
               [
                 :bold,
                 :italic,
                 :strikethrough,
                 :underline,
                 :code,
                 :subscript,
                 :superscript,
                 :highlight,
                 :lowercase,
                 :uppercase,
                 :capitalize
               ]

      assert Nodes.Text.formats(0) == []
    end

    test "bitmask/1 is the reverse of formats/1" do
      for bitmask <- 0..2047,
          do: assert(Nodes.Text.bitmask(Nodes.Text.formats(bitmask)) == bitmask)
    end
  end
end
