{:ok, _pid} = Phoenix.PubSub.Supervisor.start_link(name: KotobaTest.PubSub)
{:ok, _pid} = KotobaTest.Endpoint.start_link()
# The :build tests run `mix kotoba.build` (npm and network on the first
# run) and `mix hex.build`: `mix test --include build`.
#
# Before LiveView 1.2.10, the test client of `file_input/4` cannot upload
# a second file of one input after the first was consumed
# (phoenixframework/phoenix_live_view#3480); a browser can. The tests that
# need it are tagged :multi_upload and run on newer versions only.
live_view = Application.spec(:phoenix_live_view, :vsn) |> to_string()
multi_upload = if Version.match?(live_view, ">= 1.2.10"), do: [], else: [:multi_upload]

ExUnit.start(exclude: [:build | multi_upload])
