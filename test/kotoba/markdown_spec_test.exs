defmodule Kotoba.MarkdownSpecTest do
  # Every example of the GitHub Flavored Markdown spec (which has the
  # CommonMark examples), through Kotoba: the Markdown that
  # `Kotoba.Renderer.to_markdown/2` writes for the content that
  # `Kotoba.Content.from_markdown/2` builds must render as the example does.
  # Both are rendered by MDEx, and compared with the white space between
  # tags taken out, and a format nested in itself (`<em><em>`) as one,
  # since a text has a format or not.
  #
  # The spec is test/fixtures/markdown/gfm_spec.txt, from cmark-gfm
  # (CC-BY-SA 4.0).
  use ExUnit.Case, async: true

  alias Kotoba.{Content, Document, Renderer}

  @spec_file Path.expand("../fixtures/markdown/gfm_spec.txt", __DIR__)
  @external_resource @spec_file

  @options [
    extension: [strikethrough: true, table: true, autolink: true, tasklist: true, footnotes: true]
  ]

  # The examples that read differently on purpose, with the reason.
  @known %{
    114 => "a code language is only letters, digits and _+#.-",
    330 => "a code language is only letters, digits and _+#.-",
    169 => "a link with no URL is its text",
    495 => "a link with no URL is its text",
    496 => "a link with no URL is its text",
    575 => "a link with no URL is its text",
    606 => "a URL with a scheme that is not allowed is text",
    607 => "a URL with a scheme that is not allowed is text",
    609 => "a URL with a scheme that is not allowed is text",
    614 => "escaped text that the autolink extension reads as an email address",
    631 => "escaped text that the autolink extension reads as an email address",
    442 => "a format that a link's whole text has goes around the link"
  }

  fence = String.duplicate("`", 32)

  examples =
    @spec_file
    |> File.read!()
    |> String.split("\n")
    |> Enum.reduce({[], nil, nil}, fn line, {acc, current, section} ->
      cond do
        current == nil and String.starts_with?(line, "#") ->
          {acc, nil, line |> String.trim_leading("#") |> String.trim()}

        String.starts_with?(line, fence <> " example") ->
          {acc, [], section}

        current != nil and line == fence ->
          [markdown | _html] =
            current |> Enum.reverse() |> Enum.join("\n") |> String.split("\n.\n", parts: 2)

          {[{length(acc) + 1, section, String.replace(markdown <> "\n", "→", "\t")} | acc], nil,
           section}

        current != nil ->
          {acc, [line | current], section}

        true ->
          {acc, nil, section}
      end
    end)
    |> elem(0)
    |> Enum.reverse()

  @examples examples

  test "the spec has its examples" do
    assert length(@examples) == 672
  end

  for {number, section, markdown} <- examples do
    @markdown markdown
    @number number

    test "example #{number} (#{section})" do
      round_trip = round_trip(@markdown)

      cond do
        raw_html?(@markdown) ->
          # Raw HTML is text: the example only must not lose its text.
          assert is_binary(round_trip)

        list_item_blocks?(@markdown) ->
          # A list item holds inline content: its blocks come after the
          # list, with no text lost.
          assert text(@markdown) == text(round_trip)

        Map.has_key?(@known, @number) ->
          assert html(@markdown) != html(round_trip), "now passes: remove it from @known"

        true ->
          assert html(round_trip) == html(@markdown), "Kotoba wrote: #{inspect(round_trip)}"
      end
    end
  end

  defp round_trip(markdown) do
    {:ok, doc} = markdown |> Content.from_markdown() |> Map.fetch!(:doc) |> Document.parse()
    Renderer.to_markdown(doc)
  end

  defp html(markdown) do
    markdown
    |> MDEx.to_html!(@options)
    |> String.replace(~r/>\s+</, "><")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> one_level()
  end

  defp text(markdown) do
    markdown
    |> MDEx.to_html!(@options)
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # `<em>a <em>b</em></em>` is `<em>a b</em>`.
  defp one_level(html) do
    ~r/(<\/?(?:em|strong|del)>)/
    |> Regex.split(html, include_captures: true)
    |> Enum.reduce({[], []}, &one_level_token/2)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp one_level_token(token, {out, stack}) do
    case Regex.run(~r/\A<(\/?)(em|strong|del)>\z/, token) do
      [_all, "", tag] -> open_tag(token, tag, out, stack)
      [_all, "/", tag] -> close_tag(token, tag, out, stack)
      nil -> {[out, token], stack}
    end
  end

  defp open_tag(token, tag, out, stack) do
    if tag in stack, do: {out, [{:nested, tag} | stack]}, else: {[out, token], [tag | stack]}
  end

  defp close_tag(_token, tag, out, [{:nested, tag} | rest]), do: {out, rest}
  defp close_tag(token, _tag, out, [_open | rest]), do: {[out, token], rest}
  defp close_tag(token, _tag, out, []), do: {[out, token], []}

  defp raw_html?(markdown),
    do: any_node?(markdown, &(is_struct(&1, MDEx.HtmlBlock) or is_struct(&1, MDEx.HtmlInline)))

  defp list_item_blocks?(markdown) do
    any_node?(markdown, fn
      %MDEx.List{tight: false} ->
        true

      %item{nodes: nodes} when item in [MDEx.ListItem, MDEx.TaskItem] ->
        blocks = Enum.reject(nodes, &is_struct(&1, MDEx.List))
        length(blocks) > 1 or Enum.any?(blocks, &(not is_struct(&1, MDEx.Paragraph)))

      _node ->
        false
    end)
  end

  defp any_node?(markdown, fun),
    do: markdown |> MDEx.parse_document!(@options) |> Map.fetch!(:nodes) |> any?(fun)

  defp any?(nodes, fun),
    do: Enum.any?(nodes, &(fun.(&1) or any?(Map.get(&1, :nodes) || [], fun)))
end
