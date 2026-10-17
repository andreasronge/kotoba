defmodule Kotoba.FeaturesTest do
  use ExUnit.Case, async: true

  import Kotoba.TestJSON

  alias Kotoba.Features

  doctest Kotoba.Features

  test "has the features of the editor, in its order" do
    source = File.read!(Path.expand("../../assets/src/features.ts", __DIR__))

    [list] =
      Regex.run(~r/export const FEATURES = \[(.*?)\] as const;/s, source, capture: :all_but_first)

    editor = ~r/"([a-z_]+)"/ |> Regex.scan(list, capture: :all_but_first) |> List.flatten()

    assert editor == Enum.map(Features.all(), &Atom.to_string/1)
  end

  describe "names!/1" do
    test "gives the features in order, once each" do
      assert Features.names!(["tables", :bold, :tables]) == [:bold, :tables]
      assert Features.names!([]) == []
      assert Features.names!(Features.all()) == Features.all()
    end

    test "refuses a name that is not a feature, and a feature without the one it needs" do
      assert_raise ArgumentError, ~r/unknown Kotoba feature "nope"/, fn ->
        Features.names!(["nope"])
      end

      assert_raise ArgumentError, ~r/unknown Kotoba feature :uppercase/, fn ->
        Features.names!([:uppercase])
      end

      assert_raise ArgumentError, ~r/:check_lists needs :lists/, fn ->
        Features.names!([:check_lists])
      end

      assert Features.names!([:check_lists, :lists]) == [:lists, :check_lists]
    end
  end

  describe "used/1" do
    test "finds every feature from its nodes and formats" do
      input = [
        heading("h2", [
          text("b", 1),
          text("i", 2),
          text("u", 8),
          text("s", 4),
          text("h", 128),
          text("sub", 32),
          text("sup", 64),
          text("c", 16)
        ]),
        quote_block([link("https://a.b", [text("l")]), autolink("https://c.d", [text("a")])]),
        list("check", [item([text("x")], %{"checked" => true})]),
        code([highlight("x")], "elixir"),
        hr(),
        table([table_row([table_cell([paragraph([mention("people", "1", "Ada")])])])]),
        attachment(),
        paragraph([image("https://a.b/c.png", "c"), footnote_reference("1")]),
        footnote_definition("1", [paragraph([text("Note")])])
      ]

      assert Features.used(doc(input)) == Features.all()
    end

    test "is empty for paragraphs of plain text, the formats that are not features, and app nodes" do
      input = [
        paragraph([text("u", 512), text("c", 1024), tab(), linebreak()]),
        unknown("x-chart")
      ]

      assert Features.used(doc(input)) == []
    end

    test "a gallery is attachments" do
      assert Features.used(doc([gallery([attachment()])])) == [:attachments]
    end

    test "a bulleted list is lists, not check_lists" do
      assert Features.used(doc([list("bullet", [item([text("x")])])])) == [:lists]
    end
  end

  test "the underline, highlight, subscript and superscript formats are features" do
    input = doc([paragraph([text("u", 8 + 128), text("s", 32)]), paragraph([text("p", 64)])])

    assert Features.used(input) == [:underline, :highlight, :subscript, :superscript]
    assert Features.check(input, [:underline]) == {:error, [:highlight, :subscript, :superscript]}
  end

  test "check/2 gives the features that a document uses and does not have" do
    input = doc([table([table_row([table_cell([paragraph([text("x", 1)])])])])])

    assert Features.check(input, [:bold, :tables]) == :ok
    assert Features.check(input, ~w(bold)) == {:error, [:tables]}
    assert Features.check(input, []) == {:error, [:bold, :tables]}
  end
end
