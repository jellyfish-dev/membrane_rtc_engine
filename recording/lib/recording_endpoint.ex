defmodule Membrane.RTC.Engine.Endpoint.Recording do
  @moduledoc """
  An Endpoint responsible for saving incoming tracks to pointed storages.
  """

  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.RTC.Engine
  alias Membrane.RTC.Engine.Endpoint.Recording.{EdgeTimestampSaver, Reporter}
  alias Membrane.RTC.Engine.Endpoint.WebRTC.TrackReceiver
  alias Membrane.RTC.Engine.Subscriptions

  @type storage_opts :: any()

  @doc """
  Implementation of `Membrane.RTC.Engine.Endpoint.Recording.Storage` behaviour
  """
  @type storage :: module()

  @track_children [:track_receiver, :serializer, :tee, :edge_timestamp_saver]

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
              recording_id: [
                spec: String.t(),
                description: """
                Recording id that will be saved along with report
                """
              ],
              subscribe_mode: [
                spec: :auto | :manual,
                default: :auto,
                description: """
                Whether tracks should be subscribed automatically when they're ready.
                If set to `:manual` hls endpoint will subscribe only to tracks from endpoints send using message:
                `{:subscribe, endpoints}`
                """
              ]

  @doc """
  Subscribe hls endpoint to tracks from endpoints.

  It is only valid to use when hls has `subscribe_mode` set to :manual.
  """
  @spec subscribe(engine :: pid(), endpoint_id :: any(), endpoints :: [any()]) :: :ok
  def subscribe(engine, endpoint_id, endpoints) do
    Engine.message_endpoint(engine, endpoint_id, {:subscribe, endpoints})
  end

  @impl true
  def handle_init(_context, options) when options.subscribe_mode not in [:auto, :manual] do
    raise("""
    Cannot initialize Recording endpoint.
    Invalid value for `:subscribe_mode`: #{options.subscribe_mode}.
    Please set `:subscribe_mode` to either `:auto` or `:manual`.
    """)
  end

  @impl true
  def handle_init(ctx, options) do
    {:endpoint, endpoint_id} = ctx.name

    subscriptions_state = %Subscriptions.State{
      subscribe_mode: options.subscribe_mode,
      endpoint_id: endpoint_id,
      rtc_engine: options.rtc_engine
    }

    {:ok, reporter} = Reporter.start(options.recording_id)

    Membrane.ResourceGuard.register(ctx.resource_guard, fn ->
      save_reports(reporter, options.stores, options.recording_id)
    end)

    state =
      options
      |> Map.from_struct()
      |> Map.merge(%{
        tracks: %{},
        start_timestamp: nil,
        reporter: reporter,
        subscriptions_state: subscriptions_state
      })

    {[notify_parent: :ready], state}
  end

  @impl true
  def handle_parent_notification({:new_tracks, tracks}, _ctx, state) do
    subscriptions_state = Subscriptions.State.handle_new_tracks(tracks, state.subscriptions_state)

    {[], %{state | subscriptions_state: subscriptions_state}}
  end

  @impl true
  def handle_parent_notification(
        {:subscribe, endpoints},
        _ctx,
        state
      ) do
    subscriptions_state = Subscriptions.State.add_endpoints(endpoints, state.subscriptions_state)
    {[], %{state | subscriptions_state: subscriptions_state}}
  end

  def handle_parent_notification(_notification, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, _ctx, state) do
    {offset, state} = calculate_offset(state)
    filename = generate_filename()

    track = Map.get(state.subscriptions_state.tracks, track_id)
    spec = spawn_track(track, filename, state) ++ link_track(track, pad, state)

    Reporter.add_track(state.reporter, track, filename, offset)

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
    {_track, state} = pop_in(state, [:subscriptions_state, :tracks, track_id])

    {[remove_children: track_children], state}
  end

  @impl true
  def handle_crash_group_down({:sink_group, track_id, module}, _ctx, state) do
    Membrane.Logger.error("Sink #{inspect(module)} of track #{track_id} crashed")
    # TODO implement
    {[], state}
  end

  defp spawn_track(track, filename, state) do
    [
      [
        child({:track_receiver, track.id}, %TrackReceiver{
          track: track,
          initial_target_variant: :high
        })
        |> child({:edge_timestamp_saver, track.id}, %EdgeTimestampSaver{
          reporter: state.reporter
        })
        |> child({:serializer, track.id}, Membrane.Stream.Serializer)
        |> child({:tee, track.id}, Membrane.Tee.Parallel)
      ] ++ spawn_sinks(track, filename, state)
    ]
  end

  defp link_track(track, pad, state) do
    [
      bin_input(pad)
      |> get_child({:track_receiver, track.id})
    ] ++ link_sinks(track, state)
  end

  defp spawn_sinks(track, filename, state) do
    config = %{
      track: track,
      recording_id: state.recording_id,
      filename: filename
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

  defp save_reports(reporter, stores, recording_id) do
    case Reporter.get_report(reporter) do
      %{tracks: tracks, recording_id: _recoridng_id} when tracks == %{} ->
        Membrane.Logger.warning("No tracks in report; not saving it to storage.")

      report ->
        report_json = Jason.encode!(report)

        Enum.each(stores, fn {storage, opts} ->
          config = %{
            object: report_json,
            recording_id: recording_id,
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
    end

    Reporter.stop(reporter)
  end

  defp calculate_offset(%{start_timestamp: nil} = state),
    do: {0, %{state | start_timestamp: System.monotonic_time()}}

  defp calculate_offset(state), do: {System.monotonic_time() - state.start_timestamp, state}
  defp generate_filename(), do: "#{UUID.uuid4()}.msr"
end
