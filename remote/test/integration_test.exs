defmodule Membrane.RTC.RemoteEndpointTest do
  use ExUnit.Case, async: false

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.Remote
  alias Membrane.Testing
  alias Membrane.Testing.Pipeline

  @pub_sub_name Membrane.RTC.Engine.Remote.PubSub
  @room_id "room"
  @named_process :Engine

  test "happy path" do
    nodes =
      LocalCluster.start_nodes("cluster", 2,
        files: [__ENV__.file],
        applications: [:membrane_rtc_engine_remote, :membrane_rtc_engine]
      )

    [node1, node2] = nodes

    true = Node.connect(node1)
    assert Node.ping(node1) == :pong
    assert Node.ping(node2) == :pong

    myself = self()

    engine = spawn_engine(node1, @room_id, myself)

    :ok = Phoenix.PubSub.subscribe(@pub_sub_name, Remote.pubsub_topic(@room_id, Node.self()))

    :ok =
      Engine.add_endpoint(
        {@named_process, node1},
        %Remote{
          rtc_engine: engine,
          room_id: @room_id
        },
        id: Remote.id()
      )

    :ok = Engine.message_endpoint({@named_process, node1}, Remote.id(), {:new_node, Node.self()})

    assert :pong == Node.ping(node1)

    receive do
      msg ->
        IO.inspect(msg)
    after
      5_000 -> raise "Don't receive message"
    end
  end

  defp spawn_engine(node, room_id, caller) do
    Node.spawn(node, fn ->
      {:ok, pid} = Engine.start([id: room_id], name: @named_process)
      :ok = Engine.register(pid, self())
      send(caller, {:engine, pid})
    end)

    receive do
      {:engine, pid} -> pid
    after
      5_000 -> raise "Don't receive message with engine pid"
    end
  end
end
