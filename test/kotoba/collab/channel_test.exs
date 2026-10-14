defmodule KotobaTest.CollabChannel do
  use Kotoba.Collab.Channel, supervisor: KotobaTest.CollabSupervisor

  def authorize(socket, _id, action) do
    if Agent.get(socket.assigns.access, & &1) and
         socket.assigns.kotoba_collab_user["id"] == "alice" and action in [:read, :write],
       do: :ok,
       else: {:error, :forbidden}
  end
end

defmodule KotobaTest.CollabSocket do
  use Phoenix.Socket
  channel("kotoba:*", KotobaTest.CollabChannel)
  def connect(_params, socket, _info), do: {:ok, socket}
  def id(_socket), do: nil
end

defmodule Kotoba.Collab.ChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest
  @endpoint KotobaTest.Endpoint

  setup do
    store = start_supervised!(Kotoba.Collab.Store.Memory)

    start_supervised!(
      {Kotoba.Collab.Supervisor,
       name: KotobaTest.CollabSupervisor, store: {Kotoba.Collab.Store.Memory, store}}
    )

    access = start_supervised!({Agent, fn -> true end})
    socket = socket(KotobaTest.CollabSocket, "alice", %{access: access})
    %{socket: socket, access: access}
  end

  defp credentials(role),
    do: Kotoba.Collab.token(@endpoint, "shared", user: %{id: "alice", name: "Alice"}, role: role)

  defp join_params(role),
    do: %{"token" => credentials(role)["token"], "session" => "alice:session", "pending" => []}

  test "credentials name the join mode only when the editor joins on visibility" do
    refute Map.has_key?(credentials(:write), "join")

    visible =
      Kotoba.Collab.token(@endpoint, "shared", user: %{id: "alice"}, join: :visible)

    assert %{"join" => "visible", "park_after" => 30_000} = visible

    assert %{"park_after" => 5} =
             Kotoba.Collab.token(@endpoint, "shared",
               user: %{id: "alice"},
               join: :visible,
               park_after: 5
             )

    assert_raise ArgumentError, fn ->
      Kotoba.Collab.token(@endpoint, "shared", user: %{id: "alice"}, join: :focus)
    end

    assert_raise ArgumentError, fn ->
      Kotoba.Collab.token(@endpoint, "shared", user: %{id: "alice"}, park_after: 0)
    end
  end

  test "signed credentials are document scoped and checked against application access", %{
    socket: socket,
    access: access
  } do
    assert {:error, _} =
             subscribe_and_join(
               socket,
               KotobaTest.CollabChannel,
               "kotoba:other",
               join_params(:write)
             )

    assert {:error, _} =
             subscribe_and_join(socket, KotobaTest.CollabChannel, "kotoba:shared", %{
               "token" => "forged",
               "session" => "session"
             })

    Agent.update(access, fn _ -> false end)

    assert {:error, _} =
             subscribe_and_join(
               socket,
               KotobaTest.CollabChannel,
               "kotoba:shared",
               join_params(:write)
             )
  end

  test "read tokens cannot transact but can flush", %{socket: socket} do
    assert {:ok, %{"role" => "read"}, joined} =
             subscribe_and_join(
               socket,
               KotobaTest.CollabChannel,
               "kotoba:shared",
               join_params(:read)
             )

    ref = push(joined, "transaction", %{})
    assert_reply(ref, :error, _)
    ref = push(joined, "flush", %{})
    assert_reply(ref, :ok, %{"state" => %{"revision" => 0}})
  end

  test "revoked access stops future document broadcasts", %{socket: socket, access: access} do
    Process.flag(:trap_exit, true)

    assert {:ok, _, joined} =
             subscribe_and_join(
               socket,
               KotobaTest.CollabChannel,
               "kotoba:shared",
               join_params(:write)
             )

    assert_push("presence", _)
    monitor = Process.monitor(joined.channel_pid)
    Agent.update(access, fn _ -> false end)
    send(joined.channel_pid, {:kotoba_collab, "transaction", %{"revision" => 1}})
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    refute_push("transaction", _)
  end
end
