defmodule Membrane.RTC.Engine.Endpoint.SIP.FileSinks do
  @moduledoc false
  # Endpoint responsible for saving received track to file.

  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.File.Sink, as: FileSink
  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.WebRTC.TrackReceiver
  alias Membrane.RTC.Engine.Track

  @type encoding_t() :: String.t()

  def_options(
    rtc_engine: [
      spec: pid(),
      description: "Pid of parent Engine"
    ],
    dir_path: [
      spec: Path.t(),
      description: "Path to directory with files"
    ]
  )

  def_input_pad(:input,
    demand_unit: :buffers,
    accepted_format: _any,
    availability: :on_request
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = opts |> Map.from_struct() |> Map.merge(%{tracks: %{}})

    {[notify_parent: {:ready, nil}], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, _ctx, state) do
    track = Map.fetch!(state.tracks, track_id)

    spec = [
      bin_input(pad)
      |> get_depayloading_track_spec(track)
      |> child({:file_sink, track.id}, %FileSink{
        location: Path.join([state.dir_path, "#{track.id}.aac"])
      })
    ]

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_removed(pad, _ctx, state) do
    {notify({:end_of_stream, pad}), state}
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
  def handle_parent_notification({:new_tracks, tracks}, ctx, state) do
    {:endpoint, endpoint_id} = ctx.name

    state =
      Enum.reduce(tracks, state, fn track, state ->
        case Engine.subscribe(state.rtc_engine, endpoint_id, track.id) do
          :ok ->
            Membrane.Logger.info("Sucesfully subscribed on track: #{inspect(track)}")
            put_in(state, [:tracks, track.id], track)

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

    {notify(:tracks_subscribed), state}
  end

  @impl true
  def handle_parent_notification({:remove_tracks, _list}, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(:file_sink, _pad, _ctx, state) do
    {[notify_parent: {:forward_to_parent, :finished}], state}
  end

  @impl true
  def handle_element_end_of_stream(_other, _pad, _ctx, state) do
    {[], state}
  end

  defp notify(payload) do
    [notify_parent: {:forward_to_parent, payload}]
  end

  defp get_depayloading_track_spec(link_builder, track),
    do:
      link_builder
      |> child({:track_receiver, track.id}, %TrackReceiver{
        track: track,
        initial_target_variant: :high
      })
      |> child({:depayloader, track.id}, get_depayloader(track))
      |> child({:decoder, track.id}, Membrane.Opus.Decoder)
      |> child({:encoder, track.id}, Membrane.AAC.FDK.Encoder)

  defp get_depayloader(track) do
    track
    |> Track.get_depayloader()
    |> tap(&unless &1, do: raise("Couldn't find depayloader for track #{inspect(track)}"))
  end
end
