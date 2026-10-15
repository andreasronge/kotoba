# One shared text block of about 480 characters, typed one character per commit: the cost of
# Document.commit/3 and of JSON-encoding the state (what the size check does) as history grows.
#     mix run handover/journal_bench.exs

alias Kotoba.Collab.Document

{:ok, state} =
  Document.new(
    Kotoba.Content.from_markdown(String.duplicate("Today we worked on the autumn project. ", 15))
  )

{text_id, atoms} = Enum.max_by(state["texts"], fn {_k, v} -> length(v) end)
last = List.last(atoms)["id"]
attrs = List.last(atoms)["attrs"]

run = fn state, last, from, to ->
  Enum.reduce(from..to, {state, last, []}, fn n, {s, last, times} ->
    id = "a#{n}"

    tx = %{
      "v" => 1,
      "schema" => 1,
      "epoch" => s["epoch"],
      "id" => "t#{n}",
      "base_revision" => s["revision"],
      "ops" => [
        %{
          "op" => "insert_text",
          "id" => text_id,
          "after" => last,
          "atoms" => [%{"id" => id, "text" => "a", "attrs" => attrs}]
        }
      ]
    }

    {us, result} = :timer.tc(fn -> Document.commit(s, tx, "u") end)
    {:ok, s2, _c, _e} = with({:error, r} <- result, do: raise(inspect(r)))
    {us2, bin} = :timer.tc(fn -> JSON.encode!(s2) end)
    {s2, id, [{n, us, us2, byte_size(bin)} | times]}
  end)
end

Enum.reduce([{1, 100}, {101, 300}, {301, 600}, {601, 1000}, {1001, 2000}], {state, last}, fn {a,
                                                                                              b},
                                                                                             {s,
                                                                                              l} ->
  {s, l, times} = run.(s, l, a, b)
  recent = Enum.take(times, 50)
  avg = fn i -> div(Enum.sum(Enum.map(recent, &elem(&1, i))), length(recent)) end

  IO.puts(
    "after #{b} commits: commit #{avg.(1)} µs, encode #{avg.(2)} µs, document #{div(elem(hd(times), 3), 1024)} KB"
  )

  {s, l}
end)
