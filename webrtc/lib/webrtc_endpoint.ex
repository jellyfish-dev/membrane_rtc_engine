defmodule Membrane.RTC.Engine.Endpoint.WebRTC do
  @moduledoc """
  An Endpoint responsible for communicatiing with WebRTC client.

  It is responsible for sending and receiving media tracks from other WebRTC clients (e.g. web browsers).

  ## Signalling
  In order to operate correctly, this endpoint requires that the business logic implements
  the signalling channel to the client it represents. Implementation details are not important to
  endpoint.

  Signalling in WebRTC is used to eg. facilitate SDP negotiation or send notifications regarding the session.
  This endpoint uses an abstraction of Media Events to achieve this.
  A Media Event is a black box message sent between the Client Library and this endpoint.

  The business logic will receive an encoded media event in binary form from both the endpoint and the client library.
  It's only responsibility is to feed the binary to either the endpoint or the client library.

  ### Message Protocol Definition
  The business logic must receive `t:media_event_message_t/0` message from the endpoint and forward it to the client
  over the implemented signalling channel. Mind you, this message will be wrapped with `t:Membrane.RTC.Engine.Message.EndpointMessage.t/0`

  **Example**
  ```elixir
  @impl GenServer
  def handle_info(%Membrane.RTC.Engine.Message.EndpointMessage{endpoint_id: endpoint, message: {:media_event, _event} = message}, state) do
    send state.channels[endpoint], message
    {:noreply, state}
  end
  ```

  Simmilarily, it must forward all media events it receives over the signalling channel to the endpoint
  by sending a `t:media_event_message_t/0` to it.

  Example.
  ```elixir
  @impl GenServer
  def handle_info({:media_event, origin, event}, state) do
    endpoint_id = state.client_channel_to_endpoint_id[origin]
    Engine.message_endpoint(endpoint_id, {:media_event, event})
    {:noreply, state}
  end
  ```

  ### Client libraries
  The following client libraries for handling signalling messages are available:
  * [Typescript library intended for use in web browsers](https://github.com/membraneframework/membrane-webrtc-js)
  * [Android native library](https://github.com/membraneframework/membrane-webrtc-android)
  * [IOS native library](https://github.com/membraneframework/membrane-webrtc-ios)

  ## Monitoring track activity
  WebRTC Endpoint only monitors simulcast tracks activity, meaning that it never emits `Membrane.RTC.Engine.Event.TrackVariantPaused` event
  for non-simulcast tracks. The main reason is that it's impossible to tell if the screensharing track is inactive or not sending any packets because it contains static content.
  """
  use Membrane.Bin

  import Membrane.RTC.Utils

  require Membrane.Logger
  require Membrane.TelemetryMetrics

  alias ExSDP.Attribute.FMTP
  alias ExSDP.Attribute.RTPMapping
  alias Membrane.RTC.Engine

  alias __MODULE__.{
    MediaEvent,
    Metrics,
    SimulcastConfig,
    TrackReceiver,
    TrackSender
  }

  alias Membrane.RTC.Engine.Notifications.TrackNotification
  alias Membrane.RTC.Engine.{Track}
  alias Membrane.WebRTC
  alias Membrane.WebRTC.{EndpointBin, SDP}

  @track_metadata_event [Membrane.RTC.Engine.Endpoint.WebRTC, :track, :metadata, :event]
  @endpoint_metadata_event [Membrane.RTC.Engine.Endpoint.WebRTC, :endpoint, :metadata, :event]

  @life_span_id "webrtc_endpoint.life_span"

  defmacrop bitrate_notification(estimation) do
    {:bitrate_estimation, estimation}
  end

  @type encoding_t() :: String.t()

  @typedoc """
  Type describing message format used to send media events both to the business logic
  and by the business logic to this endpoint.
  """
  @type media_event_message_t() :: {:media_event, binary()}

  def_options rtc_engine: [
                spec: pid(),
                description: "Pid of parent Engine"
              ],
              direction: [
                spec: EndpointBin.direction(),
                default: :sendrecv,
                description: """
                Direction of WebRTC Endpoint. Determines whether
                EndpointBin can send, receive or both send and receive media.
                For more information refer to t:EndpointBin.direction/0.
                """
              ],
              ice_name: [
                spec: String.t(),
                description: "Ice name is used in creating credentials for ice connnection"
              ],
              handshake_opts: [
                type: :list,
                spec: Keyword.t(),
                default: [],
                description: """
                Keyword list with options for handshake module. For more information please
                refer to `Membrane.ICE.Bin`
                """
              ],
              filter_codecs: [
                spec: ({RTPMapping.t(), FMTP.t() | nil} -> boolean()),
                default: &SDP.filter_encodings(&1),
                description: "Defines function which will filter SDP m-line by codecs"
              ],
              log_metadata: [
                spec: :list,
                spec: Keyword.t(),
                default: [],
                description: "Logger metadata used for endpoint bin and all its descendants"
              ],
              webrtc_extensions: [
                spec: [module()],
                default: [],
                description: """
                List of WebRTC extensions to use.

                Each module has to implement `Membrane.WebRTC.Extension.t()`.
                See `membrane_webrtc_plugin` documentation for a list of possible extensions.
                """
              ],
              extensions: [
                spec: %{
                  (encoding_name :: atom() | :any) => [Membrane.RTP.SessionBin.extension_t()]
                },
                default: %{},
                description: """
                A map pointing from encoding names to lists of extensions that should be used for given encodings.
                Encoding "`:any`" indicates that extensions should be applied regardless of encoding.

                A sample usage would be to add silence discarder to OPUS tracks when VAD extension is enabled.
                It can greatly reduce CPU usage in rooms when there are a lot of people but only a few of
                them are actively speaking.
                """
              ],
              integrated_turn_domain: [
                spec: binary() | nil,
                default: nil,
                description: "Domain address of integrated TURN Servers. Required for TLS TURN"
              ],
              integrated_turn_options: [
                spec: Membrane.ICE.Endpoint.integrated_turn_options_t(),
                default: []
              ],
              owner: [
                spec: pid(),
                description: """
                Pid of parent all notifications will be send to.

                To see possible notifications please refer to module docs.
                """
              ],
              video_tracks_limit: [
                spec: integer() | nil,
                default: nil,
                description: """
                Maximal number of video tracks that will be sent to the the browser at the same time.

                This variable indicates how many video tracks should be sent to the browser at the same time.
                If `nil` all video tracks this `#{inspect(__MODULE__)}` receives will be sent.
                """
              ],
              rtcp_receiver_report_interval: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                description:
                  "Receiver reports's generation interval, set to nil to avoid reports generation"
              ],
              rtcp_sender_report_interval: [
                spec: Membrane.Time.t() | nil,
                default: nil,
                description:
                  "Sender reports's generation interval, set to nil to avoid reports generation"
              ],
              simulcast_config: [
                spec: SimulcastConfig.t(),
                default: %SimulcastConfig{},
                description: "Simulcast configuration"
              ],
              metadata: [
                spec: any(),
                default: nil,
                description: "Endpoint metadata"
              ],
              telemetry_label: [
                spec: Membrane.TelemetryMetrics.label(),
                default: [],
                description: "Label passed to Membrane.TelemetryMetrics functions"
              ],
              toilet_capacity: [
                spec: pos_integer(),
                default: 200,
                description: "TrackReceiver toilet capacity"
              ]

  def_input_pad :input,
    accepted_format: _any,
    availability: :on_request

  def_output_pad :output,
    accepted_format: _any,
    availability: :on_request

  @impl true
  def handle_init(ctx, opts) do
    {:endpoint, endpoint_id} = ctx.name

    opts = Map.update!(opts, :telemetry_label, &(&1 ++ [endpoint_id: endpoint_id]))

    Membrane.TelemetryMetrics.register(@endpoint_metadata_event, opts.telemetry_label)
    Metrics.register_bandwidth_event(opts.telemetry_label)

    Membrane.TelemetryMetrics.execute(
      @endpoint_metadata_event,
      %{metadata: opts.metadata},
      %{},
      opts.telemetry_label
    )

    connection_allocator_module =
      if opts.simulcast_config.enabled,
        do: __MODULE__.RTPConnectionAllocator,
        else: __MODULE__.NoOpConnectionAllocator

    state =
      opts
      |> Map.from_struct()
      |> Map.merge(%{
        outbound_tracks: %{},
        inbound_tracks: %{},
        display_manager: nil,
        connection_prober: nil,
        connection_allocator_module: connection_allocator_module
      })

    {:ok, connection_prober} = state.connection_allocator_module.create()

    Membrane.ResourceGuard.register(ctx.resource_guard, fn ->
      state.connection_allocator_module.destroy(connection_prober)
    end)

    log_metadata = state.log_metadata ++ [webrtc_endpoint: endpoint_id]

    endpoint_bin = %EndpointBin{
      handshake_opts: state.handshake_opts,
      log_metadata: log_metadata,
      filter_codecs: state.filter_codecs,
      direction: state.direction,
      extensions: state.webrtc_extensions || [],
      integrated_turn_options: state.integrated_turn_options,
      trace_context: state.trace_context,
      trace_metadata: [ice_name: state.ice_name],
      rtcp_receiver_report_interval: state.rtcp_receiver_report_interval,
      rtcp_sender_report_interval: state.rtcp_sender_report_interval,
      simulcast?: state.simulcast_config.enabled,
      telemetry_label: state.telemetry_label
    }

    spec = {child(:endpoint_bin, endpoint_bin), log_metadata: log_metadata}
    {[spec: spec], %{state | log_metadata: log_metadata, connection_prober: connection_prober}}
  end

  @impl true
  def handle_child_notification(
        {:voice_activity_changed, vad},
        {:track_receiver, track_id},
        _ctx,
        state
      ) do
    event = to_media_event({:voice_activity, track_id, vad}) |> MediaEvent.encode()
    {[notify_parent: {:forward_to_parent, {:media_event, event}}], state}
  end

  @impl true
  def handle_child_notification(
        {:estimation, estimations},
        {:track_sender, track_id},
        _ctx,
        state
      ) do
    notification = %TrackNotification{
      track_id: track_id,
      notification: bitrate_notification(estimations)
    }

    {[notify_parent: {:publish, notification}], state}
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :endpoint_bin, ctx, state) do
    {:endpoint, endpoint_id} = ctx.name

    tracks =
      Enum.map(tracks, fn track ->
        metadata = Map.get(state.track_id_to_metadata, track.id)
        to_rtc_track(track, endpoint_id, metadata)
      end)

    inbound_tracks = update_tracks(tracks, state.inbound_tracks)

    send_if_not_nil(state.display_manager, {:add_inbound_tracks, ctx.name, tracks})

    {[notify_parent: {:publish, {:new_tracks, tracks}}],
     %{state | inbound_tracks: inbound_tracks}}
  end

  @impl true
  def handle_child_notification({:removed_tracks, tracks}, :endpoint_bin, ctx, state) do
    tracks = Enum.map(tracks, &to_rtc_track(&1, Map.get(state.inbound_tracks, &1.id)))
    inbound_tracks = update_tracks(tracks, state.inbound_tracks)

    track_senders =
      tracks
      |> Enum.map(&{:track_sender, &1.id})
      |> Enum.filter(&Map.has_key?(ctx.children, &1))

    actions = [
      remove_children: track_senders,
      notify_parent: {:publish, {:removed_tracks, tracks}}
    ]

    {actions, %{state | inbound_tracks: inbound_tracks}}
  end

  @impl true
  def handle_child_notification(
        {:new_track, track_id, rid, ssrc, encoding, _depayloading_filter},
        _from,
        _ctx,
        state
      ) do
    track_telemetry_label = state.telemetry_label ++ [track_id: "#{track_id}:#{rid}"]

    Membrane.TelemetryMetrics.register(
      @track_metadata_event,
      track_telemetry_label
    )

    Membrane.TelemetryMetrics.execute(
      @track_metadata_event,
      %{metadata: Map.get(state.track_id_to_metadata, track_id)},
      %{},
      track_telemetry_label
    )

    variant = to_track_variant(rid)

    Membrane.Logger.info("New incoming WebRTC track #{track_id} with SSRC #{inspect(ssrc)}")

    {[notify_parent: {:track_ready, track_id, variant, encoding}], state}
  end

  @impl true
  def handle_child_notification({:negotiation_done, new_outbound_tracks}, _from, ctx, state) do
    new_outbound_tracks =
      Enum.map(new_outbound_tracks, &to_rtc_track(&1, Map.get(state.outbound_tracks, &1.id)))

    {:endpoint, endpoint_id} = ctx.name

    Enum.each(new_outbound_tracks, fn track ->
      case Engine.subscribe(state.rtc_engine, endpoint_id, track.id) do
        :ok ->
          :ok

        {:error, :invalid_track_id} ->
          Membrane.Logger.debug("""
          Couldn't subscribe to the track: #{inspect(track.id)}. No such track.
          It was probably removed before we restarted ICE. Ignoring.
          """)

        {:error, reason} ->
          raise "Couldn't subscribe to the track: #{inspect(track.id)}. Reason: #{inspect(reason)}"
      end
    end)

    send_if_not_nil(state.display_manager, {:subscribe_tracks, ctx.name, new_outbound_tracks})
    {[], state}
  end

  @impl true
  def handle_child_notification(
        {:signal, {:offer_data, media_count, turns}},
        _element,
        _ctx,
        state
      ) do
    turns = get_turn_configs(turns, state)

    media_event =
      to_media_event({:signal, {:offer_data, media_count, turns}})
      |> MediaEvent.encode()

    {[notify_parent: {:forward_to_parent, {:media_event, media_event}}], state}
  end

  @impl true
  def handle_child_notification(
        {:signal, _notification} = media_event_data,
        _element,
        _ctx,
        state
      ) do
    media_event = to_media_event(media_event_data) |> MediaEvent.encode()

    {[notify_parent: {:forward_to_parent, {:media_event, media_event}}], state}
  end

  @impl true
  def handle_child_notification(
        {:variant_switched, new_variant, reason},
        {:track_receiver, track_id},
        _ctx,
        state
      ) do
    track = Map.fetch!(state.outbound_tracks, track_id)

    reason = if reason == :variant_inactive, do: :encoding_inactive, else: reason

    media_event =
      track.origin
      |> MediaEvent.encoding_switched(track_id, to_rid(new_variant), reason)
      |> MediaEvent.encode()

    {[notify_parent: {:forward_to_parent, {:media_event, media_event}}], state}
  end

  @impl true
  def handle_child_notification({:bandwidth_estimation, estimation} = msg, _from, _ctx, state) do
    Metrics.emit_bandwidth_event(estimation, state.telemetry_label)

    state.connection_allocator_module.update_bandwidth_estimation(
      state.connection_prober,
      estimation
    )

    media_event = to_media_event(msg) |> MediaEvent.encode()

    {[notify_parent: {:forward_to_parent, {:media_event, media_event}}], state}
  end

  @impl true
  def handle_child_pad_removed(_child, _pad, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_parent_notification({:ready, other_endpoints}, ctx, state) do
    # We've received confirmation from the RTC Engine that our endpoint is ready
    # alongside information about other endpoints and tracks present in the room.
    # Forward this information to the client

    # FIXME: I don't think we actually need information about tracks in this media event
    {:endpoint, endpoint_id} = ctx.name

    event =
      endpoint_id
      |> MediaEvent.connected(other_endpoints)
      |> MediaEvent.encode()

    {[notify_parent: {:forward_to_parent, {:media_event, event}}], state}
  end

  @impl true
  def handle_parent_notification({:new_endpoint, endpoint}, _ctx, state) do
    event = MediaEvent.endpoint_added(endpoint) |> MediaEvent.encode()
    {[notify_parent: {:forward_to_parent, {:media_event, event}}], state}
  end

  @impl true
  def handle_parent_notification({:endpoint_removed, endpoint_id}, _ctx, state) do
    event = MediaEvent.endpoint_removed(endpoint_id) |> MediaEvent.encode()
    {[notify_parent: {:forward_to_parent, {:media_event, event}}], state}
  end

  @impl true
  def handle_parent_notification({:track_metadata_updated, track}, _ctx, state) do
    event =
      MediaEvent.track_updated(track.origin, track.id, track.metadata)
      |> MediaEvent.encode()

    state = put_in(state, [:outbound_tracks, track.id, :metadata], track.metadata)

    {[notify_parent: {:forward_to_parent, {:media_event, event}}], state}
  end

  @impl true
  def handle_parent_notification({:endpoint_metadata_updated, endpoint}, _ctx, state) do
    event = MediaEvent.endpoint_updated(endpoint) |> MediaEvent.encode()
    # TODO: update metadata in the state
    {[notify_parent: {:forward_to_parent, {:media_event, event}}], state}
  end

  @impl true
  def handle_parent_notification(
        %TrackNotification{
          track_id: track_id,
          notification: bitrate_notification(_estimation) = notification
        },
        _ctx,
        state
      ) do
    # Forward the data to the Track Receiver
    {[notify_child: {{:track_receiver, track_id}, notification}], state}
  end

  @impl true
  def handle_parent_notification({:tracks_priority, tracks}, _ctx, state) do
    media_event = MediaEvent.tracks_priority(tracks) |> MediaEvent.encode()
    {[notify_parent: {:forward_to_parent, {:media_event, media_event}}], state}
  end

  @impl true
  def handle_parent_notification({:new_tracks, tracks}, ctx, state) do
    # Don't subscribe to new tracks yet.
    # We will do this after ice restart is finished.
    # Notification :negotiation_done will inform us about it
    webrtc_tracks =
      Enum.map(
        tracks,
        &to_webrtc_track(&1)
      )

    outbound_tracks = update_tracks(tracks, state.outbound_tracks)

    media_event_actions =
      tracks
      |> Enum.group_by(& &1.origin)
      |> Enum.map(fn {origin, tracks} ->
        media_event =
          origin
          |> MediaEvent.tracks_added(tracks)
          |> MediaEvent.encode()

        {:notify_parent, {:forward_to_parent, {:media_event, media_event}}}
      end)

    state = %{state | outbound_tracks: outbound_tracks}
    {media_event_actions ++ forward(:endpoint_bin, {:add_tracks, webrtc_tracks}, ctx), state}
  end

  @impl true
  def handle_parent_notification({:remove_tracks, tracks} = msg, ctx, state) do
    media_event_actions =
      tracks
      |> Enum.group_by(& &1.origin)
      |> Enum.map(fn {origin, tracks} ->
        ids = Enum.map(tracks, & &1.id)
        event = origin |> MediaEvent.tracks_removed(ids) |> MediaEvent.encode()
        {:notify_parent, {:forward_to_parent, {:media_event, event}}}
      end)

    {media_event_actions ++ forward(:endpoint_bin, msg, ctx), state}
  end

  @impl true
  def handle_parent_notification({:display_manager, display_manager_pid}, ctx, state) do
    send_if_not_nil(
      display_manager_pid,
      {:register_endpoint, ctx.name, state.video_tracks_limit}
    )

    {[], %{state | display_manager: display_manager_pid}}
  end

  @impl true
  def handle_parent_notification({:media_event, event}, ctx, state) do
    case deserialize(event) do
      {:ok, data} ->
        handle_media_event(data, ctx, state)

      {:error, :invalid_media_event} ->
        Membrane.Logger.warning("Invalid media event #{inspect(event)}. Ignoring.")
        {[], state}
    end
  end

  @impl true
  def handle_parent_notification(msg, ctx, state) do
    {forward(:endpoint_bin, msg, ctx), state}
  end

  @impl true
  def handle_info({:display_manager, display_manager_pid}, ctx, state) do
    send_if_not_nil(
      display_manager_pid,
      {:register_endpoint, ctx.name, state.video_tracks_limit}
    )

    {[], %{state | display_manager: display_manager_pid}}
  end

  @impl true
  def handle_info({:enable_negotiability, track_id}, ctx, state) do
    track_receiver = {:track_receiver, track_id}

    forward_actions =
      if Map.has_key?(ctx.children, track_receiver),
        do: [notify_child: {track_receiver, {:set_negotiable, true}}],
        else: []

    {forward_actions, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, _ctx, state) do
    track = Map.fetch!(state.outbound_tracks, track_id)
    initial_target_variant = state.simulcast_config.initial_target_variant.(track)

    spec = {
      bin_input(pad)
      |> child({:track_receiver, track_id}, %TrackReceiver{
        track: track,
        initial_target_variant: initial_target_variant,
        connection_allocator: state.connection_prober,
        connection_allocator_module: state.connection_allocator_module,
        telemetry_label: state.telemetry_label
      })
      |> via_in(pad, options: [use_payloader?: false], toilet_capacity: state.toilet_capacity)
      |> get_child(:endpoint_bin),
      log_metadata: state.log_metadata
    }

    {[spec: spec], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, {track_id, variant}) = pad, _ctx, state) do
    %Track{encoding: encoding} = track = Map.get(state.inbound_tracks, track_id)
    extensions = Map.get(state.extensions, encoding, []) ++ Map.get(state.extensions, :any, [])

    # EndpointBin expects `rid` to be nil for non simulcast tracks
    # assume that tracks with [:high] variants are non-simulcast
    rid = if state.inbound_tracks[track_id].variants == [:high], do: nil, else: to_rid(variant)

    spec = {
      get_child(:endpoint_bin)
      |> via_out(Pad.ref(:output, {track_id, rid}),
        options: [extensions: extensions, use_depayloader?: false]
      )
      |> via_in(Pad.ref(:input, {track_id, variant}))
      |> child(
        {:track_sender, track_id},
        %TrackSender{
          track: track,
          variant_bitrates: Map.fetch!(state.track_id_to_bitrates, track_id)
        },
        get_if_exists: true
      )
      |> via_out(pad)
      |> bin_output(pad),
      log_metadata: state.log_metadata
    }

    {[spec: spec], state}
  end

  @impl true
  def handle_element_start_of_stream({:track_receiver, track_id}, _pad, _ctx, state) do
    track = Map.fetch!(state.outbound_tracks, track_id)

    if length(track.variants) > 1 do
      # Allocation negotiability is only applicable to simulcast tracks
      # We wait 500ms to enable it to enable reaching a target variant at the beginning of the stream
      # for better user experience.
      # We're starting the timer in `handle_element_start_of_stream` to facilitate
      # clients that don't send media right after SDP negotiation
      Process.send_after(self(), {:enable_negotiability, track_id}, 500)
    end

    {[], state}
  end

  @impl true
  def handle_element_start_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:input, track_id), _ctx, state) do
    {[remove_children: {:track_receiver, track_id}], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:output, {_track_id, _variant}), _ctx, state) do
    {[], state}
  end

  @spec to_rid(:high | :medium | :low) :: String.t()
  def to_rid(:high), do: "h"
  def to_rid(:medium), do: "m"
  def to_rid(:low), do: "l"

  defp handle_media_event(%{type: :connect, data: %{metadata: metadata}}, _ctx, state) do
    {[notify_parent: {:ready, metadata}], state}
  end

  defp handle_media_event(%{type: :disconnect}, _ctx, state) do
    # TODO: handle this media event
    # send message to engine to remove this endpoint
    # update signalling protocol diagram accordingly
    {[], state}
  end

  defp handle_media_event(
         %{type: :update_track_metadata, data: %{track_id: track_id, track_metadata: metadata}},
         _ctx,
         state
       ) do
    state = put_in(state, [:inbound_tracks, track_id, :metadata], metadata)
    {[notify_parent: {:update_track_metadata, track_id, metadata}], state}
  end

  defp handle_media_event(
         %{type: :update_endpoint_metadata, data: %{metadata: metadata}},
         _ctx,
         state
       ) do
    {[notify_parent: {:update_endpoint_metadata, metadata}], state}
  end

  defp handle_media_event(%{type: :sdp_offer, data: data}, ctx, state) do
    state =
      state
      |> Map.put(:track_id_to_metadata, data.track_id_to_track_metadata)
      |> Map.put(:track_id_to_bitrates, data.track_id_to_track_bitrates)

    msg = {:signal, {:sdp_offer, data.sdp_offer.sdp, data.mid_to_track_id}}
    {forward(:endpoint_bin, msg, ctx), state}
  end

  defp handle_media_event(%{type: :track_variant_bitrates, data: data}, ctx, state) do
    state = put_in(state, [:track_id_to_bitrates, data.track_id], data.variant_bitrates)
    msg = {:variant_bitrates, data.variant_bitrates}

    {forward({:track_sender, data.track_id}, msg, ctx), state}
  end

  defp handle_media_event(%{type: :candidate, data: data}, ctx, state) do
    msg = {:signal, {:candidate, data.candidate}}
    {forward(:endpoint_bin, msg, ctx), state}
  end

  defp handle_media_event(%{type: :renegotiate_tracks}, ctx, state) do
    msg = {:signal, :renegotiate_tracks}
    {forward(:endpoint_bin, msg, ctx), state}
  end

  defp handle_media_event(%{type: :set_target_track_variant, data: data}, ctx, state) do
    msg = {:set_target_variant, to_track_variant(data.variant)}
    {forward({:track_receiver, data.track_id}, msg, ctx), state}
  end

  defp handle_media_event(%{type: :prioritize_track, data: data}, ctx, state) do
    msg = {:prioritize_track, ctx.name, data.track_id}
    send_if_not_nil(state.display_manager, msg)
    {[], state}
  end

  defp handle_media_event(%{type: :unprioritize_track, data: data}, ctx, state) do
    msg = {:unprioritize_track, ctx.name, data.track_id}
    send_if_not_nil(state.display_manager, msg)
    {[], state}
  end

  defp handle_media_event(%{type: :prefered_video_sizes, data: data}, _ctx, state) do
    msg =
      {:prefered_video_sizes, data.big_screens, data.medium_screens, data.small_screens,
       data.same_size?}

    send_if_not_nil(state.display_manager, msg)
    {[], state}
  end

  defp get_turn_configs(turn_servers, state) do
    Enum.map(turn_servers, fn
      %{secret: secret} = turn_server ->
        {username, password} = generate_turn_credentials(state.ice_name, secret)

        case state.integrated_turn_domain do
          nil -> turn_server
          domain -> Map.put(turn_server, :domain_name, domain)
        end
        |> Map.delete(:secret)
        |> Map.put(:username, username)
        |> Map.put(:password, password)

      other ->
        other
    end)
  end

  defp update_tracks(tracks, track_id_to_track),
    do:
      Enum.reduce(tracks, track_id_to_track, fn track, acc ->
        Map.put(acc, track.id, track)
      end)

  defp to_media_event({:signal, {:sdp_answer, answer, mid_to_track_id}}),
    do: MediaEvent.sdp_answer(answer, mid_to_track_id)

  defp to_media_event({:signal, {:offer_data, tracks_types, turns}}),
    do: MediaEvent.offer_data(tracks_types, turns)

  defp to_media_event({:signal, {:candidate, candidate, sdp_m_line_index}}),
    do: MediaEvent.candidate(candidate, sdp_m_line_index)

  defp to_media_event({:signal, {:sdp_offer, offer}}),
    do: MediaEvent.sdp_offer(offer)

  defp to_media_event({:voice_activity, track_id, vad}),
    do: MediaEvent.voice_activity(track_id, vad)

  defp to_media_event({:bandwidth_estimation, estimation}),
    do: MediaEvent.bandwidth_estimation(estimation)

  defp deserialize(string) when is_binary(string) do
    case MediaEvent.decode(string) do
      {:ok, %{type: :custom, data: data}} -> {:ok, data}
      {:ok, event} -> {:ok, event}
      {:error, _reason} = error -> error
    end
  end

  defp to_rtc_track(%WebRTC.Track{} = track, %Engine.Track{} = original_track) do
    to_rtc_track(track, original_track.origin, original_track.metadata)
  end

  defp to_rtc_track(%WebRTC.Track{} = track, origin, metadata) do
    extension_key = WebRTC.Extension

    variants = Enum.map(track.rids || [nil], &to_track_variant(&1))

    Engine.Track.new(
      track.type,
      track.stream_id,
      origin,
      track.selected_encoding_key,
      track.selected_encoding.clock_rate,
      track.selected_encoding.format_params,
      id: track.id,
      variants: variants,
      active?: track.status != :disabled,
      metadata: metadata,
      ctx: %{extension_key => track.extmaps},
      payload_type: track.selected_encoding.payload_type
    )
  end

  defp to_webrtc_track(%Engine.Track{} = track) do
    track = if track.active?, do: track, else: Map.put(track, :status, :disabled)
    extmaps = Map.get(track.ctx, WebRTC.Extension, [])
    track = Map.put(track, :extmaps, extmaps)
    WebRTC.Track.new(track.type, track.stream_id, to_keyword_list(track))
  end

  defp to_keyword_list(%Engine.Track{} = struct),
    do: Map.from_struct(struct) |> to_keyword_list()

  defp to_keyword_list(%{} = map) do
    Enum.map(map, fn
      {:encoding, value} -> {:selected_encoding_key, value}
      {key, value} -> {key, value}
    end)
  end

  defp to_track_variant(rid) when rid in ["h", nil], do: :high
  defp to_track_variant("m"), do: :medium
  defp to_track_variant("l"), do: :low
end
