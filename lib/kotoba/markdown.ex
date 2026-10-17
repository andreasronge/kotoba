defmodule Kotoba.Markdown do
  @moduledoc false
  # Small helpers for the Markdown output of the built-in nodes.

  alias Kotoba.Nodes.Text

  # The block syntax at the start of a line (after at most three spaces):
  # an ATX heading, a quote, a bullet, a thematic break or setext underline
  # of `-` or `=`, and an ordered list marker. `*`, `_`, `` ` `` and `~`
  # (bullets, rules and fences too) are escaped everywhere by the inline
  # rule.
  @line_start ~r/^([ \t]{0,3})(?:(\d{1,9})([.)])(?=[ \t]|$)|(\#{1,6}(?=[ \t]|$)|>|[-+](?=[ \t]|$)|-(?=[- \t]*$)|=(?=[= \t]*$)))/m

  @doc """
  Escapes the characters that have a meaning in inline Markdown, and the
  block syntax at the start of a line, so that the text reads as text.
  """
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace(~r/[\\`*_\[\]~<&]/, "\\\\\\0")
    |> then(
      &Regex.replace(@line_start, &1, fn _all, lead, digits, mark, symbol ->
        escape_line_start(lead, digits, mark, symbol)
      end)
    )
    # A tab or four spaces at the start of a line would start a code block.
    |> String.replace(~r/^(\t| (?=   ))/m, fn
      "\t" -> "&#9;"
      " " -> "&#32;"
    end)
    # `!` before a link would make it an image.
    |> String.replace(~r/!\z/, "\\!")
  end

  defp escape_line_start(lead, "", _mark, symbol), do: lead <> "\\" <> symbol
  defp escape_line_start(lead, digits, mark, _symbol), do: lead <> digits <> "\\" <> mark

  @doc """
  Joins a run of inline Markdown items, with the markers of their formats.

  Each item is `{formats, markdown}`, where `formats` are the formats of
  `Kotoba.Nodes.Text.markdown_formats/1`, or `{:neutral, markdown}` for an
  item that keeps the open formats as they are (a line break, an image).
  A format opens before the first item that has it and closes after the
  last one, so formats nest. White space at the edges of an item goes
  outside the markers, as CommonMark wants. `open` are formats already open
  around the run, whose markers are not written.
  """
  @spec formatted([{[atom()] | :neutral, String.t()}], [atom()]) :: String.t()
  def formatted(items, open \\ []) do
    indexed = Enum.with_index(items)

    {out, stack, pending} =
      Enum.reduce(indexed, {[], open, ""}, fn
        {{:neutral, body}, _index}, {out, stack, pending} ->
          {[out, pending, body], stack, ""}

        {{formats, body}, index}, {out, stack, pending} ->
          case Regex.run(~r/\A(\s*)(.*?)(\s*)\z/su, body, capture: :all_but_first) do
            [_lead, "", _trail] ->
              {out, stack, pending <> body}

            [lead, core, trail] ->
              {closes, stack} = close_until(stack, formats, length(open))
              # The format that lasts longer opens first, so it is the
              # outer one (`***foo** bar*`).
              opens =
                formats
                |> Enum.reject(&(&1 in stack))
                |> Enum.sort_by(&(-reach(items, index, &1)))

              {[out, closes, pending, lead, Enum.map(opens, &marker/1), core], stack ++ opens,
               trail}
          end
      end)

    closes = stack |> Enum.drop(length(open)) |> Enum.reverse() |> Enum.map(&marker/1)
    IO.iodata_to_binary([out, closes, pending])
  end

  # How many items from `index` on have the format (an item that keeps the
  # formats, such as a line break, does not end it).
  defp reach(items, index, format) do
    items
    |> Enum.drop(index)
    |> Enum.take_while(fn
      {:neutral, _body} -> true
      {formats, _body} -> format in formats
    end)
    |> length()
  end

  # Closes the formats of the stack from the first one that the next item
  # does not have, inner first. The first `keep` formats (open around the
  # run) stay open.
  defp close_until(stack, formats, keep) do
    index =
      stack
      |> Enum.with_index()
      |> Enum.find_value(fn {format, index} ->
        index >= keep and format not in formats and index
      end)

    case index do
      nil ->
        {[], stack}

      index ->
        {kept, closed} = Enum.split(stack, index)
        {closed |> Enum.reverse() |> Enum.map(&marker/1), kept}
    end
  end

  defp marker(format), do: Text.markdown_marker(format)

  @doc "Returns a code span with a fence that is longer than the backticks in the text."
  @spec code_span(String.t()) :: String.t()
  def code_span(text) do
    fence = String.duplicate("`", longest_run(text, "`") + 1)
    # CommonMark strips one space from each side of a span that has a space
    # on both sides, so such a span (and one that starts or ends with a
    # backtick) gets one more.
    pad =
      if String.starts_with?(text, "`") or String.ends_with?(text, "`") or
           (String.starts_with?(text, " ") and String.ends_with?(text, " ") and
              String.trim(text) != ""),
         do: " ",
         else: ""

    fence <> pad <> text <> pad <> fence
  end

  @doc "Returns the length of the longest run of `char` in the text."
  @spec longest_run(String.t(), String.t()) :: non_neg_integer()
  def longest_run(text, char) do
    ~r/#{Regex.escape(char)}+/
    |> Regex.scan(text)
    |> Enum.map(fn [run] -> String.length(run) end)
    |> Enum.max(fn -> 0 end)
  end

  @doc "Wraps the text in a marker, with the outer white space outside the marker."
  @spec wrap(String.t(), String.t()) :: String.t()
  def wrap(text, marker) do
    case Regex.run(~r/\A(\s*)(.*?)(\s*)\z/su, text, capture: :all_but_first) do
      [_lead, "", _trail] -> text
      [lead, core, trail] -> lead <> marker <> core <> marker <> trail
    end
  end

  # A URL with no scheme whose first part (before `/`, `?` or `#`) has a
  # character reference, such as `javascript&#58;alert(1)`: a Markdown
  # renderer that decodes it could see a scheme.
  @scheme ~r/\A[a-zA-Z][a-zA-Z0-9+.\-]*:/
  @reference_in_first_part ~r/\A[^\/?#]*&[#a-zA-Z]/

  @doc """
  Returns the Markdown link destination for a URL that
  `Kotoba.Sanitizer.link_url/2` accepted, or `nil` when the URL must be
  text: a URL with no scheme and a character reference before its first
  `/`, `?` or `#`.
  """
  @spec destination(String.t()) :: String.t() | nil
  def destination(url) do
    if not Regex.match?(@scheme, url) and Regex.match?(@reference_in_first_part, url),
      do: nil,
      else: url(url)
  end

  @doc """
  Returns the title of a Markdown link or image, with its leading space, or
  `""` for no title. The title is in double quotes, with `"` and `\\`
  escaped.
  """
  @spec title(String.t() | nil) :: String.t()
  def title(nil), do: ""
  def title(""), do: ""
  def title(title), do: " \"" <> String.replace(title, ~r/["\\]/, "\\\\\\0") <> "\""

  @doc """
  Returns a footnote label for `[^label]`, with `]`, `[` and `\\` escaped.
  """
  @spec footnote_label(String.t()) :: String.t()
  def footnote_label(label), do: String.replace(label, ~r/[\[\]\\]/, "\\\\\\0")

  @doc """
  Returns a URL for a Markdown link destination.

  `\\`, `&`, `<` and `>` get a backslash, so that a CommonMark renderer
  reads them as literal characters and decodes no entity. Spaces and
  parentheses are percent-encoded.
  """
  @spec url(String.t()) :: String.t()
  def url(url) do
    escaped = String.replace(url, ~r/[\\&<>]/, "\\\\\\0")
    if Regex.match?(~r/[\s()]/, url), do: "<" <> escaped <> ">", else: escaped
  end
end
