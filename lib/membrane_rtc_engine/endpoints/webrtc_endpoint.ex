if Code.ensure_loaded?(Membrane.WebRTC.EndpointBin) do
  defmodule Membrane.RTC.Engine.Endpoint.WebRTC do
    @moduledoc """
    An Endpoint responsible for communicatiing with WebRTC peer.

    It is responsible for sending and receiving media tracks from other WebRTC peer (e.g. web browser).
    """
    use Membrane.Bin

    import Membrane.RTC.Utils

    alias Membrane.WebRTC.{SDP, EndpointBin}
    alias Membrane.WebRTC
    alias Membrane.RTC.Engine
    alias ExSDP.Attribute.FMTP
    alias ExSDP.Attribute.RTPMapping

    require Membrane.Logger

    @type stun_server_t() :: ExLibnice.stun_server()
    @type turn_server_t() :: ExLibnice.relay_info()
    @type encoding_t() :: String.t()

    def_options rtc_engine: [
                  spec: pid(),
                  description: "Pid of parent Engine"
                ],
                ice_name: [
                  spec: String.t(),
                  description: "Ice name is used in creating credentials for ice connnection"
                ],
                stun_servers: [
                  type: :list,
                  spec: [ExLibnice.stun_server()],
                  default: [],
                  description: "List of stun servers"
                ],
                turn_servers: [
                  type: :list,
                  spec: [ExLibnice.relay_info()],
                  default: [],
                  description: "List of turn servers"
                ],
                port_range: [
                  spec: Range.t(),
                  default: 0..0,
                  description: "Port range to be used by `Membrane.ICE.Bin`"
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
                  default: &SDP.filter_mappings(&1),
                  description: "Defines function which will filter SDP m-line by codecs"
                ],
                log_metadata: [
                  spec: :list,
                  spec: Keyword.t(),
                  default: [],
                  description: "Logger metadata used for endpoint bin and all its descendants"
                ],
                webrtc_extensions: [
                  spec: [Membrane.WebRTC.Extension.t()],
                  default: [],
                  description: """
                  List of WebRTC extensions to use.

                  At this moment only VAD (RFC 6464) is supported.
                  Enabling it will cause RTC Engine sending `{:vad_notification, val, endpoint_id}` messages.
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
                use_integrated_turn: [
                  spec: boolean(),
                  default: false,
                  description: "Set to `true`, to use integrated TURN instead of libnice"
                ],
                integrated_turn_domain: [
                  spec: binary() | nil,
                  default: nil,
                  description: "Domain address of integrated TURN Servers. Required for TLS TURN"
                ],
                integrated_turn_options: [
                  spec: Membrane.TURN.Endpoint.integrated_turn_options_t(),
                  default: []
                ],
                owner: [
                  spec: pid(),
                  description: """
                  Pid of parent all notifications will be send to.

                  To see possible notifications please refer to module docs.
                  """
                ],
                trace_context: [
                  spec: :list,
                  default: [],
                  description: "Trace context for otel propagation"
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
                ]

    def_input_pad :input,
      demand_unit: :buffers,
      caps: :any,
      availability: :on_request

    def_output_pad :output,
      demand_unit: :buffers,
      caps: :any,
      availability: :on_request

    @impl true
    def handle_init(opts) do
      endpoint_bin = %EndpointBin{
        stun_servers: opts.stun_servers,
        turn_servers: opts.turn_servers,
        handshake_opts: opts.handshake_opts,
        log_metadata: opts.log_metadata,
        filter_codecs: opts.filter_codecs,
        inbound_tracks: [],
        outbound_tracks: [],
        extensions: opts.webrtc_extensions || [],
        use_integrated_turn: opts.use_integrated_turn,
        integrated_turn_options: opts.integrated_turn_options,
        trace_context: opts.trace_context,
        trace_metadata: [name: opts.ice_name],
        rtcp_receiver_report_interval: opts.rtcp_receiver_report_interval,
        rtcp_sender_report_interval: opts.rtcp_sender_report_interval
      }

      spec = %ParentSpec{
        children: %{endpoint_bin: endpoint_bin}
      }

      state = %{
        rtc_engine: opts.rtc_engine,
        ice_name: opts.ice_name,
        outbound_tracks: %{},
        inbound_tracks: %{},
        extensions: opts.extensions || %{},
        use_integrated_turn: opts.use_integrated_turn,
        integrated_turn_options: opts.integrated_turn_options,
        integrated_turn_domain: opts.integrated_turn_domain,
        owner: opts.owner,
        video_tracks_limit: opts.video_tracks_limit
      }

      {{:ok, spec: spec, log_metadata: opts.log_metadata}, state}
    end

    @impl true
    def handle_notification({:new_tracks, tracks}, _from, ctx, state) do
      tracks = Enum.map(tracks, &to_rtc_track(&1, state.track_id_to_metadata))
      inbound_tracks = update_tracks(tracks, state.inbound_tracks)

      send_if_not_nil(state.display_manager, {:add_inbound_tracks, ctx.name, tracks})

      {{:ok, notify: {:publish, {:new_tracks, tracks}}},
       %{state | inbound_tracks: inbound_tracks}}
    end

    @impl true
    def handle_notification({:removed_tracks, tracks}, _from, _ctx, state) do
      tracks = Enum.map(tracks, &to_rtc_track(&1, state.track_id_to_metadata))
      inbound_tracks = update_tracks(tracks, state.inbound_tracks)

      {{:ok, notify: {:publish, {:removed_tracks, tracks}}},
       %{state | inbound_tracks: inbound_tracks}}
    end

    @impl true
    def handle_notification(
          {:new_track, track_id, rid, encoding, depayloading_filter},
          _from,
          _ctx,
          state
        ) do
      {{:ok, notify: {:track_ready, track_id, rid, encoding, depayloading_filter}}, state}
    end

    @impl true
    def handle_notification({:negotiation_done, new_outbound_tracks}, _from, ctx, state) do
      new_outbound_tracks =
        Enum.map(new_outbound_tracks, &to_rtc_track(&1, state.track_id_to_metadata))

      subscriptions = Enum.map(new_outbound_tracks, fn track -> {track.id, :RTP} end)

      {:endpoint, endpoint_id} = ctx.name

      case Engine.subscribe(state.rtc_engine, subscriptions, endpoint_id) do
        :ok ->
          send_if_not_nil(
            state.display_manager,
            {:subscribe_tracks, ctx.name, new_outbound_tracks}
          )

          {:ok, state}

        {:error, track_id, reason} ->
          raise "Couldn't subscribe for track: #{inspect(track_id)}. Reason: #{inspect(reason)}"

        {:error, :timeout} ->
          raise "Timeout subscribing on track in Engine with pid #{inspect(state.rtc_engine)}"
      end
    end

    @impl true
    def handle_notification({:vad, val}, :endpoint_bin, ctx, state) do
      send(state.owner, {:vad_notification, val, ctx.name})

      send_if_not_nil(state.display_manager, {:vad_notification, ctx.name, val})

      {:ok, state}
    end

    @impl true
    def handle_notification(
          {:signal, {:offer_data, media_count, turns}},
          _element,
          _ctx,
          state
        ) do
      turns = get_turn_configs(turns, state)
      enforce_turns? = state.use_integrated_turn || false

      media_event_data = {:signal, {:offer_data, media_count, turns, enforce_turns?}}
      {{:ok, notify: {:custom_media_event, serialize(media_event_data)}}, state}
    end

    @impl true
    def handle_notification(
          {:signal, _notification} = media_event_data,
          _element,
          _ctx,
          state
        ) do
      {{:ok, notify: {:custom_media_event, serialize(media_event_data)}}, state}
    end

    @impl true
    def handle_notification(notification, _element, _ctx, state),
      do: {{:ok, notify: notification}, state}

    @impl true
    def handle_other({:new_tracks, tracks}, ctx, state) do
      # Don't subscribe for new tracks yet.
      # We will do this after ice restart is finished.
      # Notification :negotiation_done  will inform us about it

      webrtc_tracks =
        Enum.map(
          tracks,
          &to_webrtc_track(&1)
        )

      outbound_tracks = update_tracks(tracks, state.outbound_tracks)

      {{:ok, forward(:endpoint_bin, {:add_tracks, webrtc_tracks}, ctx)},
       %{state | outbound_tracks: outbound_tracks}}
    end

    @impl true
    def handle_other({:display_manager, display_manager_pid}, ctx, state) do
      send_if_not_nil(
        display_manager_pid,
        {:register_endpoint, ctx.name, state.video_tracks_limit}
      )

      {:ok, Map.put(state, :display_manager, display_manager_pid)}
    end

    @impl true
    def handle_other({:custom_media_event, event}, ctx, state) do
      case deserialize(event) do
        {:ok, data} ->
          handle_custom_media_event(data, ctx, state)

        {:error, :invalid_media_event} ->
          Membrane.Logger.warn("Invalid media event #{inspect(event)}. Ignoring.")
          {:ok, state}
      end
    end

    @impl true
    def handle_other(msg, ctx, state) do
      {{:ok, forward(:endpoint_bin, msg, ctx)}, state}
    end

    @impl true
    def handle_pad_added(Pad.ref(:input, _track_id) = pad, _ctx, state) do
      links = [
        link_bin_input(pad)
        |> via_in(pad, options: [use_payloader?: false])
        |> to(:endpoint_bin)
      ]

      {{:ok, spec: %ParentSpec{links: links}}, state}
    end

    @impl true
    def handle_pad_added(Pad.ref(:output, {track_id, _rid}) = pad, _ctx, state) do
      %{encoding: encoding} = Map.get(state.inbound_tracks, track_id)
      extensions = Map.get(state.extensions, encoding, []) ++ Map.get(state.extensions, :any, [])

      spec = %ParentSpec{
        links: [
          link(:endpoint_bin)
          |> via_out(pad,
            options: [
              extensions: extensions,
              use_depayloader?: false
            ]
          )
          |> to_bin_output(pad)
        ]
      }

      {{:ok, spec: spec}, state}
    end

    defp handle_custom_media_event(%{type: :sdp_offer, data: data}, ctx, state) do
      state = Map.put(state, :track_id_to_metadata, data.track_id_to_track_metadata)
      msg = {:signal, {:sdp_offer, data.sdp_offer.sdp, data.mid_to_track_id}}
      {{:ok, forward(:endpoint_bin, msg, ctx)}, state}
    end

    defp handle_custom_media_event(%{type: :candidate, data: data}, ctx, state) do
      msg = {:signal, {:candidate, data.candidate}}
      {{:ok, forward(:endpoint_bin, msg, ctx)}, state}
    end

    defp handle_custom_media_event(%{type: :renegotiate_tracks}, ctx, state) do
      msg = {:signal, :renegotiate_tracks}
      {{:ok, forward(:endpoint_bin, msg, ctx)}, state}
    end

    defp handle_custom_media_event(%{type: :prioritize_track, data: data}, ctx, state) do
      msg = {:prioritize_track, ctx.name, data.track_id}
      send_if_not_nil(state.display_manager, msg)
      {:ok, state}
    end

    defp handle_custom_media_event(%{type: :unprioritize_track, data: data}, ctx, state) do
      msg = {:unprioritize_track, ctx.name, data.track_id}
      send_if_not_nil(state.display_manager, msg)
      {:ok, state}
    end

    defp handle_custom_media_event(%{type: :prefered_video_sizes, data: data}, _ctx, state) do
      msg =
        {:prefered_video_sizes, data.big_screens, data.medium_screens, data.small_screens,
         data.same_size?}

      send_if_not_nil(state.display_manager, msg)
      {:ok, state}
    end

    defp handle_custom_media_event(%{type: :select_encoding, data: data}, _ctx, state) do
      {{:ok, notify: {:select_encoding, {data.peer_id, data.track_id, data.encoding}}}, state}
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

    defp serialize({:signal, {:sdp_answer, answer, mid_to_track_id}}),
      do: %{
        type: "sdpAnswer",
        data: %{
          type: "answer",
          sdp: answer,
          midToTrackId: mid_to_track_id
        }
      }

    defp serialize({:signal, {:offer_data, tracks_types, turns, enforce_turns?}}) do
      integrated_turn_servers =
        Enum.map(turns, fn turn ->
          addr =
            if turn.relay_type == :tls and turn[:domain_name],
              do: turn[:domain_name],
              else: :inet.ntoa(turn.mocked_server_addr) |> to_string()

          %{
            serverAddr: addr,
            serverPort: turn.server_port,
            transport: turn.relay_type,
            password: turn.password,
            username: turn.username
          }
        end)

      %{
        type: "offerData",
        data: %{
          tracksTypes: tracks_types,
          integratedTurnServers: integrated_turn_servers,
          iceTransportPolicy: if(enforce_turns?, do: "relay", else: "all")
        }
      }
    end

    defp serialize({:signal, {:candidate, candidate, sdp_m_line_index}}),
      do: %{
        type: "candidate",
        data: %{
          candidate: candidate,
          sdpMLineIndex: sdp_m_line_index,
          sdpMid: nil,
          usernameFragment: nil
        }
      }

    defp serialize({:signal, {:sdp_offer, offer}}),
      do: %{
        type: "sdpOffer",
        data: %{
          type: "offer",
          sdp: offer
        }
      }

    defp deserialize(%{"type" => "renegotiateTracks"}) do
      {:ok, %{type: :renegotiate_tracks}}
    end

    defp deserialize(%{"type" => "prioritizeTrack"} = event) do
      case event do
        %{"type" => "prioritizeTrack", "data" => %{"trackId" => track_id}} ->
          {:ok, %{type: :prioritize_track, data: %{track_id: track_id}}}
      end
    end

    defp deserialize(%{"type" => "unprioritizeTrack"} = event) do
      case event do
        %{"type" => "unprioritizeTrack", "data" => %{"trackId" => track_id}} ->
          {:ok, %{type: :unprioritize_track, data: %{track_id: track_id}}}
      end
    end

    defp deserialize(%{"type" => "preferedVideoSizes"} = event) do
      case event do
        %{
          "type" => "preferedVideoSizes",
          "data" => %{
            "bigScreens" => big_screens,
            "mediumScreens" => medium_screens,
            "smallScreens" => small_screens,
            "allSameSize" => same_size?
          }
        } ->
          {:ok,
           %{
             type: :prefered_video_sizes,
             data: %{
               big_screens: big_screens,
               medium_screens: medium_screens,
               small_screens: small_screens,
               same_size?: same_size?
             }
           }}
      end
    end

    defp deserialize(%{"type" => "candidate"} = event) do
      case event do
        %{
          "type" => "candidate",
          "data" => %{
            "candidate" => candidate,
            "sdpMLineIndex" => sdp_m_line_index
          }
        } ->
          {:ok,
           %{
             type: :candidate,
             data: %{
               candidate: candidate,
               sdp_m_line_index: sdp_m_line_index
             }
           }}

        _other ->
          {:error, :invalid_media_event}
      end
    end

    defp deserialize(%{"type" => "sdpOffer"} = event) do
      case(event) do
        %{
          "type" => "sdpOffer",
          "data" => %{
            "sdpOffer" => %{
              "type" => "offer",
              "sdp" => sdp
            },
            "trackIdToTrackMetadata" => track_id_to_track_metadata,
            "midToTrackId" => mid_to_track_id
          }
        } ->
          {:ok,
           %{
             type: :sdp_offer,
             data: %{
               sdp_offer: %{
                 type: :offer,
                 sdp: sdp
               },
               track_id_to_track_metadata: track_id_to_track_metadata,
               mid_to_track_id: mid_to_track_id
             }
           }}

        _other ->
          {:error, :invalid_media_event}
      end
    end

    defp deserialize(%{"type" => "selectEncoding"} = event) do
      case event do
        %{
          "type" => "selectEncoding",
          "data" => %{
            "peerId" => peer_id,
            "trackId" => track_id,
            "encoding" => encoding
          }
        } ->
          {:ok,
           %{
             type: :select_encoding,
             data: %{peer_id: peer_id, track_id: track_id, encoding: encoding}
           }}

        _other ->
          {:error, :invalid_media_event}
      end
    end

    defp to_rtc_track(%WebRTC.Track{} = track, track_id_to_metadata) do
      extension_key = WebRTC.Extension

      %Engine.Track{
        type: track.type,
        stream_id: track.stream_id,
        id: track.id,
        encoding: track.encoding,
        simulcast_encodings: track.rids,
        clock_rate: track.rtp_mapping.clock_rate,
        format: [:RTP, :raw],
        fmtp: track.fmtp,
        active?: track.status != :disabled,
        metadata: Map.get(track_id_to_metadata, track.id),
        ctx: %{extension_key => track.extmaps, :clock_rate => track.rtp_mapping.clock_rate}
      }
    end

    defp to_webrtc_track(%Engine.Track{} = track) do
      track = if track.active?, do: track, else: Map.put(track, :status, :disabled)
      extmaps = Map.get(track.ctx, WebRTC.Extension, [])
      track = Map.put(track, :extmaps, extmaps)
      WebRTC.Track.new(track.type, track.stream_id, to_keyword_list(track))
    end

    defp to_keyword_list(%Engine.Track{} = struct),
      do: Map.from_struct(struct) |> to_keyword_list()

    defp to_keyword_list(%{} = map), do: Enum.map(map, fn {key, value} -> {key, value} end)
  end
end
