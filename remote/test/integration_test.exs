defmodule Membrane.RTC.RemoteEndpointTest do
  use ExUnit.Case, async: false

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.Remote
  alias Membrane.RTC.Engine.Support.FakeSourceEndpoint
  alias Membrane.Testing
  alias Membrane.Testing.Pipeline

  @pub_sub_name Membrane.RTC.Engine.Remote.PubSub
  @room_id "room"
  @named_process :Engine

  @stream_id "stream"
  @track_id "video-track"
  @endpoint_id :video_source

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

    video_track =
      Engine.Track.new(
        :video,
        @stream_id,
        @endpoint_id,
        :H264,
        90_000,
        %ExSDP.Attribute.FMTP{
          pt: 96
        },
        id: @track_id
      )

    remote_id = Remote.id()
    assert_receive %Engine.Message.EndpointAdded{endpoint_type: Remote, endpoint_id: remote_id}

    :ok =
      Engine.add_endpoint(
        {@named_process, node1},
        %FakeSourceEndpoint{rtc_engine: engine, track: video_track},
        id: @endpoint_id
      )

    assert_receive %Engine.Message.EndpointAdded{
                     endpoint_type: FakeSourceEndpoint,
                     endpoint_id: @endpoint_id
                   },
                   1_0000

    assert_receive %Engine.Message.EndpointMessage{
                     endpoint_id: @endpoint_id,
                     message: :tracks_added
                   },
                   1_000

    :ok = Engine.message_endpoint({@named_process, node1}, @endpoint_id, :start)

    :ok = Engine.message_endpoint({@named_process, node1}, Remote.id(), {:new_node, Node.self()})

    node_name = to_string(node1)

    assert_receive {^node_name, %{@track_id => video_track}}, 5_000
  end

  defp spawn_engine(node, room_id, caller) do
    Node.spawn(node, fn ->
      {:ok, pid} = Engine.start([id: room_id], name: @named_process)
      send(caller, {:engine, pid})
    end)

    receive do
      {:engine, pid} ->
        :ok = Engine.register(pid, self())
        pid
    after
      5_000 -> raise "Don't receive message with engine pid"
    end
  end
end
