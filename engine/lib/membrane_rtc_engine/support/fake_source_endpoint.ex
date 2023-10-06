defmodule Membrane.RTC.Engine.Support.FakeSourceEndpoint do
  @moduledoc false

  # Endpoint that publishes synthetic data.
  # Starts publishing data on receiving `:start` message.

  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Support.{StaticTrackSender, TestSource}

  @type encoding_t() :: String.t()

  def_options rtc_engine: [
                spec: pid(),
                description: "Pid of parent Engine"
              ],
              track: [
                spec: Engine.Track.t(),
                description: "Track to publish"
              ]

  def_output_pad :output,
    demand_unit: :buffers,
    accepted_format: _any,
    availability: :on_request

  @impl true
  def handle_init(_ctx, opts) do
    {[notify_parent: {:ready, nil}], Map.from_struct(opts)}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[
       notify_parent: {:publish, {:new_tracks, [state.track]}},
       notify_parent: {:forward_to_parent, :tracks_added}
     ], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, {_track_id, _rid}) = pad, _ctx, state) do
    is_keyframe = fn _buffer, _track -> true end

    spec = [
      child(:source, %TestSource{
        stream_format: %Membrane.RTP{},
        output: [],
        fast_start: true
      })
      |> child(:track_sender, %StaticTrackSender{
        track: state.track,
        is_keyframe: is_keyframe
      })
      |> bin_output(pad)
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_parent_notification({:ready, _other_endpoints}, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:new_endpoint, _endpoint}, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:endpoint_removed, _endpoint_id}, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:new_tracks, _list}, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:remove_tracks, _list}, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification(:start, _ctx, state) do
    track_ready = {:track_ready, state.track.id, :high, state.track.encoding}
    {[notify_parent: track_ready], state}
  end
end
