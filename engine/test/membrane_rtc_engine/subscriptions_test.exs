defmodule Membrane.RTC.EngineTest do
  use ExUnit.Case

  alias Membrane.RTC.Engine.Track
  alias Membrane.RTC.Engine.Subscriptions.State

  defmodule MockEngine do
    use GenServer

    @spec start_link(map()) :: {:ok, pid()} | {:error, term()}
    def start_link(tracks) do
      GenServer.start_link(__MODULE__, tracks)
    end

    @impl true
    def init(init_arg) do
      {:ok, init_arg}
    end

    @impl true
    def handle_info({:subscribe, {endpoint_pid, ref}, _endpoint_id, _track_id, _opts}, state) do
      send(endpoint_pid, {ref, :ok})
      {:noreply, state}
    end

    def handle_info({:add_track, track}, state) do
      {:noreply, [track | state]}
    end

    @impl true
    def handle_call(:get_tracks, _from, state) do
      {:reply, state, state}
    end
  end

  test "Manual subscriptions state" do
    track1 = create_track("test1")
    track1_id = track1.id
    track2 = create_track("test2")
    track3 = create_track("test3")
    track3_id = track3.id
    inital_tracks = [track1, track2]

    assert {:ok, mock_engine} = MockEngine.start_link(inital_tracks)

    state = %State{subscribe_mode: :manual, endpoint_id: "test-endpoint", rtc_engine: mock_engine}

    assert %{tracks: %{}} = State.handle_new_tracks([track1], state)

    assert %{tracks: %{^track1_id => ^track1} = tracks, endpoints: endpoints} =
             state = State.add_endpoints(["test1"], state)

    endpoints_set = MapSet.new(["test1"])

    assert MapSet.equal?(endpoints, endpoints_set)

    endpoints_set = MapSet.put(endpoints_set, "test3")

    assert %{endpoints: endpoints, tracks: ^tracks} =
             state = State.add_endpoints(["test3"], state)

    assert MapSet.equal?(endpoints, endpoints_set)

    send(mock_engine, {:add_track, track3})

    assert %{tracks: %{^track1_id => ^track1, ^track3_id => ^track3}} =
             State.handle_new_tracks([track3], state)
  end

  test "Automatic subscriptions state" do
    track1 = create_track("test1")
    track1_id = track1.id
    track2 = create_track("test2")
    inital_tracks = [track1, track2]

    assert {:ok, mock_engine} = MockEngine.start_link(inital_tracks)

    state = %State{subscribe_mode: :auto, endpoint_id: "test-endpoint", rtc_engine: mock_engine}

    assert %{tracks: %{^track1_id => ^track1}} = state = State.handle_new_tracks([track1], state)

    assert ^state = State.add_endpoints(["test1"], state)
  end

  defp create_track(endpoint_id) do
    Track.new(:video, Track.stream_id(), endpoint_id, :VP8, nil, nil)
  end
end
