defmodule Membrane.RTC.Engine.Endpoint.Recording do
  @moduledoc """
  An Endpoint responsible for saving incoming tracks to pointed storages.
  """

  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.Recording.Reporter
  alias Membrane.RTC.Engine.Endpoint.WebRTC.TrackReceiver

  @type storage_opts :: any()

  @doc """
  Implementation of `Membrane.RTC.Engine.Endpoint.Recording.Storage` behaviour
  """
  @type storage :: module()

  @track_children [:track_receiver, :serializer, :tee]

  def_input_pad :input,
    accepted_format: Membrane.RTP,
    availability: :on_request

  def_options rtc_engine: [
                spec: pid(),
                description: "Pid of parent Engine"
              ],
              stores: [
                spec: [{storage(), storage_opts()}],
                description: """
                A list of stores that the recorded streams will be uploaded to.
                Should implement `Membrane.RTC.Engine.Endpoint.Recording.Storage` behaviour.
                """
              ],
              output_dir: [
                spec: Path.t(),
                default: "output",
                description: """
                Directory that contains output files. For S3, this is the object's path prefix.
                """
              ],
              recording_id: [
                spec: String.t(),
                description: """
                Recording id that will be saved along with report
                """
              ]

  @impl true
  def handle_init(ctx, options) do
    {:ok, reporter} = Reporter.start(options.recording_id)

    Membrane.ResourceGuard.register(ctx.resource_guard, fn ->
      save_reports(reporter, options.stores, options.output_dir)
    end)

    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        tracks: %{},
        reporter: reporter,
        start_timestamp: nil
      })

    {[notify_parent: :ready], state}
  end

  @impl true
  def handle_parent_notification({:new_tracks, tracks}, ctx, state) do
    {:endpoint, endpoint_id} = ctx.name

    {valid_tracks, _invalid_tracks} =
      Enum.split_with(tracks, fn track ->
        case Engine.subscribe(state.rtc_engine, endpoint_id, track.id) do
          :ok ->
            true

          {:error, :invalid_track_id} ->
            Membrane.Logger.debug("""
            Couldn't subscribe to the track: #{track.id} (no such track). Ignoring.
            """)

            false

          {:error, reason} ->
            reason = inspect(reason)

            Membrane.Logger.error(%{
              error: reason,
              message: "Couldn't subscribe to track",
              track: track
            })

            raise "Subscription to track #{track.id} failed with reason: `#{reason}`"
        end
      end)

    tracks = Map.new(valid_tracks, &{&1.id, &1})
    state = Map.update!(state, :tracks, &Map.merge(&1, tracks))

    {[], state}
  end

  def handle_parent_notification(_notification, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, _ctx, state) do
    {offset, state} = calculate_offset(state)

    track = Map.get(state.tracks, track_id)
    spec = spawn_track(track, state) ++ link_track(track, pad, state)

    Reporter.add_track(state.reporter, track, filename(track), offset)

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, track_id), ctx, state) do
    track_elements =
      @track_children
      |> Enum.map(&{&1, track_id})
      |> Enum.filter(&Map.has_key?(ctx.children, &1))

    track_sinks =
      state.stores
      |> Enum.map(fn {storage, _opts} -> {:sink, track_id, storage} end)
      |> Enum.filter(&Map.has_key?(ctx.children, &1))

    track_children = track_elements ++ track_sinks
    {_track, state} = pop_in(state, [:tracks, track_id])
    {[remove_children: track_children], state}
  end

  @impl true
  def handle_crash_group_down({:track_group, track_id}, _ctx, state) do
    Membrane.Logger.error("Track #{track_id} pipeline crashed")
    # TODO implement
    {[], state}
  end

  @impl true
  def handle_crash_group_down({:sink_group, track_id, module}, _ctx, state) do
    Membrane.Logger.error("Sink #{inspect(module)} of track #{track_id} crashed")
    # TODO implement
    {[], state}
  end

  defp spawn_track(track, state) do
    [
      {
        [
          child({:track_receiver, track.id}, %TrackReceiver{
            track: track,
            initial_target_variant: :high
          })
          |> child({:serializer, track.id}, Membrane.Stream.Serializer)
          |> child({:tee, track.id}, Membrane.Tee.Parallel)
        ] ++ spawn_sinks(track, state),
        group: {:track_group, track.id}, crash_group_mode: :temporary
      }
    ]
  end

  defp link_track(track, pad, state) do
    [
      bin_input(pad)
      |> get_child({:track_receiver, track.id})
    ] ++ link_sinks(track, state)
  end

  defp spawn_sinks(track, state) do
    config = %{
      track: track,
      path_prefix: state.output_dir,
      filename: filename(track)
    }

    Enum.map(state.stores, fn {storage, opts} ->
      {child({:sink, track.id, storage}, storage.get_sink(config, opts)),
       group: {:sink_group, track.id, storage}, crash_group_mode: :temporary}
    end)
  end

  defp link_sinks(track, state) do
    Enum.map(state.stores, fn {storage, _opts} ->
      get_child({:tee, track.id})
      |> get_child({:sink, track.id, storage})
    end)
  end

  defp save_reports(reporter, stores, output_dir) do
    Reporter.get_report(reporter)

    report_json =
      reporter
      |> Reporter.get_report()
      |> Jason.encode!()

    Enum.each(stores, fn {storage, opts} ->
      config = %{
        object: report_json,
        path_prefix: output_dir,
        filename: "report.json"
      }

      unless storage.save_object(config, opts) == :ok do
        Membrane.Logger.error(%{
          message: "Failed to save report",
          object: "report.json",
          storage: storage
        })
      end
    end)

    Reporter.stop(reporter)
  end

  defp calculate_offset(%{start_timestamp: nil} = state),
    do: {0, %{state | start_timestamp: System.monotonic_time()}}

  defp calculate_offset(state), do: {System.monotonic_time() - state.start_timestamp, state}

  defp filename(track), do: "#{track.type}_#{String.replace(track.id, ":", "_")}.msr"
end
