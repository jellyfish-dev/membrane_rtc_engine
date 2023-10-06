defmodule Membrane.RTC.Engine.Endpoint.Remote do
  @moduledoc """
  A Remote Endpoint
  """

  use Membrane.Bin

  require Membrane.Logger
  alias Phoenix.PubSub
  alias Membrane.RTC.Engine

  def_input_pad :input,
    demand_unit: :buffers,
    accepted_format: _any,
    availability: :on_request

  def_output_pad :remote_output,
    demand_unit: :buffers,
    accepted_format: _any,
    availability: :on_request

  def_options rtc_engine: [
                spec: pid(),
                description: "Pid of parent Engine"
              ],
              room_id: [
                spec: String.t(),
                description: "Id of Room"
              ]

  @pub_sub Membrane.RTC.Engine.Remote.PubSub

  @spec id() :: binary()
  def id() do
    to_string(__MODULE__)
  end

  @impl true
  def handle_init(_ctx, opts) do
    :ok = PubSub.subscribe(@pub_sub, pubsub_topic(opts.room_id))
    :ok = PubSub.subscribe(@pub_sub, pubsub_topic(opts.room_id, Node.self()))

    {[notify_parent: :ready],
     %{
       rtc_engine: opts.rtc_engine,
       room_id: opts.room_id,
       inbound_tracks: %{},
       outbound_tracks: %{}
     }}
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
  def handle_parent_notification({:new_tracks, tracks}, _ctx, state) do
    state =
      Enum.reduce(tracks, state, fn track, state ->
        case Engine.subscribe(state.rtc_engine, id(), track.id) do
          :ok ->
            put_in(state, [:inbound_tracks, track.id], track)

          {:error, :invalid_track_id} ->
            Membrane.Logger.debug("""
            Couldn't subscribe to the track: #{inspect(track.id)}. No such track.
            It had to be removed just after publishing it. Ignoring.
            """)

            state

          {:error, reason} ->
            raise "Couldn't subscribe to the track: #{inspect(track.id)}. Reason: #{inspect(reason)}"
        end
      end)

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

  @impl true
  def handle_parent_notification({:new_node, node}, _ctx, state) do
    unless Enum.empty?(state.inbound_tracks) do
      :ok =
        PubSub.broadcast(
          @pub_sub,
          pubsub_topic(state.room_id, node),
          {to_string(Node.self()), state.inbound_tracks}
        )
    end

    {[], state}
  end

  @spec pubsub_topic(room_id :: binary()) :: binary()
  def pubsub_topic(room_id) do
    "#{__MODULE__}:#{room_id}"
  end

  @spec pubsub_topic(room_id :: binary(), node :: Node.t()) :: binary()
  def pubsub_topic(room_id, node) do
    "#{__MODULE__}:#{room_id}:#{to_string(node)}"
  end
end
