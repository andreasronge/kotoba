# Backlog

Known gaps in Kotoba, each to become an issue.


## Markdown

- **List items that hold blocks.** A Markdown list item can hold several
  paragraphs, a code block, a quote or a table; a Lexical list item holds
  inline content and one nested list. `Kotoba.Content.from_markdown/2`
  joins the paragraphs of such an item with line breaks, and puts the
  other blocks after the list, with no text lost. Lexical's quote has an
  opt-in for blocks (`shadowRoot`), its list item has none: wait for
  Lexical rather than give the list item our own container and editing.
- **Formats that Markdown has no syntax for.** Underline, highlight and
  text colors, subscript and superscript are left out of
  `Kotoba.Renderer.to_markdown/2` (the text stays). MDEx reads extended
  syntaxes for some of them (`^sup^`, `~sub~`, `==mark==`, `__underline__`
  with options that change CommonMark's meaning of `__`); writing and
  reading them would need an option, as they are not CommonMark.
- **Mentions** are their label in Markdown, and come back as text.
- **A line break in a heading** is a space in Markdown, and **a line break
  in a table cell** is `<br>`, which reads back as text (Kotoba passes no
  HTML through).
- **Editor commands for footnotes and images.** They come from pasted or
  imported Markdown, and from the server; the editor has no button or
  Markdown shortcut to make one yet.
