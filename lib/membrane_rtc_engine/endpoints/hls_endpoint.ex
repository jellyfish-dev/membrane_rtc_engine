if Enum.all?(
     [
       Membrane.H264.FFmpeg.Parser,
       Membrane.HTTPAdaptiveStream.SinkBin,
       Membrane.Opus.Decoder,
       Membrane.AAC.Parser,
       Membrane.AAC.FDK.Encoder
     ],
     &Code.ensure_loaded?/1
   ) do
  defmodule Membrane.RTC.Engine.Endpoint.HLS do
    @moduledoc """
    An Endpoint responsible for converting incoming tracks to HLS playlist.

    This module requires the following plugins to be present in your `mix.exs` for H264 & OPUS input:
    ```
    [
      :membrane_h264_ffmpeg_plugin,
      :membrane_http_adaptive_stream_plugin,
    ]
    ```

    It can perform transcoding (see `Membrane.RTC.Engine.Endpoint.HLS.TranscodingConfig`),
    in such case these plugins are also needed:
    ```
    [
      :membrane_ffmpeg_swscale_plugin,
      :membrane_framerate_converter_plugin
    ]
    ```

    Plus, optionally it supports OPUS audio input - for that, additional dependencies are needed:
    ```
    [
      :membrane_opus_plugin,
      :membrane_aac_plugin,
      :membrane_aac_fdk_plugin
    ]
    ```
    """
    use Membrane.Bin

    require Membrane.Logger

    alias Membrane.HTTPAdaptiveStream.Sink.SegmentDuration
    alias Membrane.RTC.Engine
    alias Membrane.RTC.Engine.Endpoint.HLS.{AudioMixerConfig, CompositorConfig}
    alias Membrane.RTC.Engine.Endpoint.WebRTC.TrackReceiver
    alias Membrane.RTC.Engine.Track
    alias Membrane.Time
    alias Membrane.VideoCompositor.RustStructs.VideoPlacement

    @compositor_deps [
      Membrane.H264.FFmpeg.Decoder,
      Membrane.H264.FFmpeg.Encoder,
      Membrane.FFmpeg.SWScale.Scaler,
      Membrane.FramerateConverter,
      Membrane.BlankVideoGenerator,
      Membrane.Realtimer
    ]
    @audio_mixer_deps [
      Membrane.AudioMixer,
      Membrane.AAC.Parser,
      Membrane.AAC.FDK.Encoder
    ]

    def_input_pad(:input,
      demand_unit: :buffers,
      caps: :any,
      availability: :on_request
    )

    def_options rtc_engine: [
                  spec: pid(),
                  description: "Pid of parent Engine"
                ],
                output_directory: [
                  spec: Path.t(),
                  description: "Path to directory under which HLS output will be saved",
                  default: "hls_output"
                ],
                owner: [
                  spec: pid(),
                  description: """
                  Pid of parent all notifications will be send to.

                  These notifications are:
                    * `{:playlist_playable, content_type}`
                    * `{:cleanup, clean_function}`
                  """
                ],
                hls_mode: [
                  spec: :separate_av | :muxed_av,
                  default: :separate_av,
                  description: """
                  Defines output mode for `Membrane.HTTPAdaptiveStream.SinkBin`.

                  - `:separate_av` - audio and video tracks will be separated
                  - `:muxed_av` - audio will be attached to every video track
                  """
                ],
                target_window_duration: [
                  type: :time,
                  spec: Membrane.Time.t() | :infinity,
                  default: Membrane.Time.seconds(20),
                  description: """
                  Max duration of stream that will be stored. Segments that are older than window duration will be removed.
                  """
                ],
                segment_duration: [
                  spec: SegmentDuration.t(),
                  default: SegmentDuration.new(Time.seconds(4), Time.seconds(5)),
                  description: """
                  Expected length of each segment. Setting it is not necessary, but
                  may help players achieve better UX.
                  """
                ],
                partial_segment_duration: [
                  spec: SegmentDuration.t() | nil,
                  default: SegmentDuration.new(Time.milliseconds(500), Time.milliseconds(550)),
                  description: """
                  Expected length of each partial segment. Setting it is not necessary, but
                  may help players achieve better UX.
                  """
                ],
                mixer_config: [
                  spec: %{audio: AudioMixerConfig.t(), video: CompositorConfig.t()} | nil,
                  default: nil,
                  description: """
                  Audio and video mixer configuration. If you don't want to use compositor pass nil.
                  """
                ],
                broadcast_mode: [
                  spec: :live | :vod,
                  default: :live,
                  description: """
                  Tells if the session is live or a vod type of broadcast. Use live when you generate HLS stream from real-time data.
                  Use vod when generating HLS from file.
                  """
                ]

    @impl true
    def handle_init(opts) do
      state = %{
        rtc_engine: opts.rtc_engine,
        tracks: %{},
        stream_ids: MapSet.new(),
        output_directory: opts.output_directory,
        owner: opts.owner,
        hls_mode: opts.hls_mode,
        target_window_duration: opts.target_window_duration,
        segment_duration: opts.segment_duration,
        partial_segment_duration: opts.partial_segment_duration,
        mixer_config: opts.mixer_config,
        broadcast_mode: opts.broadcast_mode,
        video_layout: nil,
        stream_beginning: nil
      }

      video_layout =
        if is_nil(opts.mixer_config),
          do: nil,
          else: state.mixer_config.video.layout_module.init(opts.mixer_config.video.caps)

      {:ok, %{state | video_layout: video_layout}}
    end

    @impl true
    def handle_other({:new_tracks, tracks}, ctx, state) do
      {:endpoint, endpoint_id} = ctx.name

      state =
        Enum.reduce(tracks, state, fn track, state ->
          case Engine.subscribe(state.rtc_engine, endpoint_id, track.id) do
            :ok ->
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

      {:ok, state}
    end

    @impl true
    def handle_other(msg, _ctx, state) do
      Membrane.Logger.warn("Unexpected message: #{inspect(msg)}. Ignoring.")
      {:ok, state}
    end

    def handle_notification(
          {:track_playable, content_type},
          :hls_sink_bin,
          _ctx,
          state
        ) do
      send(state.owner, {:playlist_playable, content_type, ""})
      {:ok, state}
    end

    def handle_notification(
          {:track_playable, {content_type, _track_id}},
          {:hls_sink_bin, stream_id},
          _ctx,
          state
        ) do
      send(state.owner, {:playlist_playable, content_type, stream_id})
      {:ok, state}
    end

    def handle_notification(
          {:cleanup, clean_function},
          children,
          _ctx,
          state
        ) do
      case children do
        :hls_sink_bin ->
          send(state.owner, {:cleanup, clean_function, ""})

        {:hls_sink_bin, stream_id} ->
          send(state.owner, {:cleanup, clean_function, stream_id})
      end

      {:ok, state}
    end

    @impl true
    def handle_notification(notification, _element, _context, state) do
      Membrane.Logger.warn("Unexpected notification: #{inspect(notification)}. Ignoring.")
      {:ok, state}
    end

    @impl true
    def handle_pad_removed(Pad.ref(:input, track_id), ctx, state) do
      track_children =
        [
          :opus_decoder,
          :aac_encoder,
          :aac_parser,
          :video_parser,
          :decoder,
          :framerate_converter,
          :track_receiver,
          :depayloader,
          :blank,
          :realtimer
        ]
        |> Enum.map(&{&1, track_id})
        |> Enum.filter(&Map.has_key?(ctx.children, &1))

      {removed_track, tracks} = Map.pop!(state.tracks, track_id)
      state = %{state | tracks: tracks}

      sink_bin_used? =
        Enum.any?(tracks, fn {_id, track} ->
          track.stream_id == removed_track.stream_id
        end)

      {state, children_to_remove} =
        cond do
          is_nil(state.mixer_config) and not sink_bin_used? ->
            {state, [{:hls_sink_bin, removed_track.stream_id}]}

          not is_nil(state.mixer_config) and tracks == %{} ->
            {%{state | stream_beginning: nil}, get_common_children(ctx)}

          true ->
            {state, []}
        end

      children_to_remove = track_children ++ children_to_remove

      {placements, video_layout} =
        if is_nil(state.mixer_config) or removed_track.type == :audio,
          do: {[], state.video_layout},
          else:
            state.mixer_config.video.layout_module.track_removed(
              state.video_layout,
              removed_track
            )

      state = %{state | video_layout: video_layout}

      update_action = update_layout_action(removed_track, placements, state)

      {{:ok, [remove_child: children_to_remove] ++ update_action}, state}
    end

    @impl true
    def handle_pad_added(Pad.ref(:input, track_id) = pad, ctx, state) do
      {offset, state} = get_track_offset(state)
      link_builder = link_bin_input(pad)
      track = Map.get(state.tracks, track_id)
      directory = get_hls_stream_directory(state, track)

      {placements, video_layout} =
        if is_nil(state.mixer_config) or track.type == :audio,
          do: {[], state.video_layout},
          else: state.mixer_config.video.layout_module.track_added(state.video_layout, track)

      state = %{state | video_layout: video_layout}

      initial_placements =
        placements
        |> Enum.filter(&filter_placements(&1, track))
        |> Enum.map(fn
          {Pad.ref(:input, {:blank, _id}), placement} -> {:blank, placement}
          {Pad.ref(:input, _id), placement} -> {:input, placement}
        end)
        |> Map.new()

      placements = Enum.reject(placements, &filter_placements(&1, track))

      spec = hls_links_and_children(initial_placements, offset, link_builder, track, state, ctx)

      {spec, state} =
        if hls_sink_bin_exists?(track, ctx, state) do
          {spec, state}
        else
          # remove directory if it already exists
          File.rm_rf(directory)
          File.mkdir_p!(directory)

          hls_sink_spec = get_hls_sink_spec(state, track, directory)

          {merge_parent_specs(spec, hls_sink_spec), state}
        end

      update_action = update_layout_action(track, placements, state)

      {{:ok, [spec: spec] ++ update_action}, state}
    end

    defp get_hls_sink_spec(state, track, directory) do
      hls_sink = %Membrane.HTTPAdaptiveStream.SinkBin{
        manifest_module: Membrane.HTTPAdaptiveStream.HLS,
        target_window_duration: state.target_window_duration,
        persist?: false,
        storage: %Membrane.HTTPAdaptiveStream.Storages.FileStorage{
          directory: directory
        },
        hls_mode: state.hls_mode,
        mode: state.broadcast_mode,
        mp4_parameters_in_band?: is_nil(state.mixer_config)
      }

      parent_spec_key =
        if is_nil(state.mixer_config), do: {:hls_sink_bin, track.stream_id}, else: :hls_sink_bin

      %ParentSpec{
        children: %{
          parent_spec_key => hls_sink
        }
      }
    end

    defp hls_links_and_children(
           _initial_placement,
           _offset,
           link_builder,
           %{encoding: :OPUS} = track,
           %{mixer_config: nil} = state,
           _ctx
         ) do
      %ParentSpec{
        children: %{
          {:track_receiver, track.id} => %TrackReceiver{
            track: track,
            initial_target_variant: :high
          },
          {:depayloader, track.id} => get_depayloader(track),
          {:opus_decoder, track.id} => Membrane.Opus.Decoder,
          {:aac_encoder, track.id} => Membrane.AAC.FDK.Encoder,
          {:aac_parser, track.id} => %Membrane.AAC.Parser{out_encapsulation: :none}
        },
        links: [
          link_builder
          |> to({:track_receiver, track.id})
          |> to({:depayloader, track.id})
          |> to({:opus_decoder, track.id})
          |> to({:aac_encoder, track.id})
          |> to({:aac_parser, track.id})
          |> via_in(Pad.ref(:input, {:audio, track.id}),
            options: [
              encoding: :AAC,
              segment_duration: state.segment_duration,
              partial_segment_duration: state.partial_segment_duration
            ]
          )
          |> to({:hls_sink_bin, track.stream_id})
        ]
      }
    end

    defp hls_links_and_children(
           _initital_placement,
           offset,
           link_builder,
           %{encoding: :OPUS} = track,
           state,
           ctx
         ) do
      parent_spec = %ParentSpec{
        children: %{
          {:track_receiver, track.id} => %TrackReceiver{
            track: track,
            initial_target_variant: :high
          },
          {:depayloader, track.id} => get_depayloader(track),
          {:opus_decoder, track.id} => Membrane.Opus.Decoder
        },
        links: [
          link_builder
          |> to({:track_receiver, track.id})
          |> to({:depayloader, track.id})
          |> to({:opus_decoder, track.id})
          |> via_in(Pad.ref(:input, {:extra, track.id}), options: [offset: offset])
          |> to(:audio_mixer)
        ]
      }

      state
      |> generate_audio_mixer(ctx)
      |> merge_parent_specs(generate_compositor(state, ctx))
      |> merge_parent_specs(parent_spec)
    end

    defp hls_links_and_children(
           _initial_placement,
           _offset,
           link_builder,
           %{encoding: :H264} = track,
           %{mixer_config: nil} = state,
           _ctx
         ) do
      %ParentSpec{
        children: %{
          {:track_receiver, track.id} => %TrackReceiver{
            track: track,
            initial_target_variant: :high,
            keyframe_request_interval: state.segment_duration.target
          },
          {:depayloader, track.id} => get_depayloader(track),
          {:video_parser, track.id} => %Membrane.H264.FFmpeg.Parser{
            alignment: :au,
            attach_nalus?: true
          }
        },
        links: [
          link_builder
          |> to({:track_receiver, track.id})
          |> to({:depayloader, track.id})
          |> to({:video_parser, track.id})
          |> via_in(Pad.ref(:input, {:video, track.id}),
            options: [
              encoding: :H264,
              segment_duration: state.segment_duration,
              partial_segment_duration: state.partial_segment_duration
            ]
          )
          |> to({:hls_sink_bin, track.stream_id})
        ]
      }
    end

    defp hls_links_and_children(
           initial_placement,
           offset,
           link_builder,
           %{encoding: :H264} = track,
           state,
           ctx
         ) do
      parent_spec = %ParentSpec{
        children: %{
          {:track_receiver, track.id} => %TrackReceiver{
            track: track,
            initial_target_variant: :high,
            keyframe_request_interval: state.segment_duration.target
          },
          {:depayloader, track.id} => get_depayloader(track),
          {:video_parser, track.id} => %Membrane.H264.FFmpeg.Parser{
            alignment: :au,
            attach_nalus?: true
          },
          {:framerate_converter, track.id} => %Membrane.FramerateConverter{
            framerate: state.mixer_config.video.caps.framerate
          }
        },
        links: [
          link_builder
          |> to({:track_receiver, track.id})
          |> to({:depayloader, track.id})
          |> to({:video_parser, track.id})
          |> to({:decoder, track.id}, Membrane.H264.FFmpeg.Decoder)
          |> to({:framerate_converter, track.id})
          |> via_in(Pad.ref(:input, track.id),
            options: [initial_placement: initial_placement.input, timestamp_offset: offset]
          )
          |> to(:compositor)
        ]
      }

      parent_spec =
        if track.metadata["mainPresenter"] do
          parent_spec
        else
          {width, height} = initial_placement.blank.display_size

          blank_spec = %ParentSpec{
            children: %{
              {:blank, track.id} => %Membrane.BlankVideoGenerator{
                caps: %Membrane.RawVideo{
                  width: width,
                  height: height,
                  pixel_format: :I420,
                  framerate: state.mixer_config.video.caps.framerate,
                  aligned: true
                },
                duration: :infinity
              },
              {:realtimer, track.id} => Membrane.Realtimer
            },
            links: [
              link({:blank, track.id})
              |> to({:realtimer, track.id})
              |> via_in(Pad.ref(:input, {:blank, track.id}),
                options: [initial_placement: initial_placement.blank, timestamp_offset: offset]
              )
              |> to(:compositor)
            ]
          }

          merge_parent_specs(parent_spec, blank_spec)
        end

      state
      |> generate_audio_mixer(ctx)
      |> merge_parent_specs(generate_compositor(state, ctx))
      |> merge_parent_specs(parent_spec)
    end

    if Enum.all?(@compositor_deps, &Code.ensure_loaded?/1) do
      defp generate_compositor(_state, ctx) when is_map_key(ctx.children, :compositor),
        do: %ParentSpec{children: %{}, links: []}

      defp generate_compositor(state, _ctx) do
        compositor = %Membrane.VideoCompositor{
          caps: state.mixer_config.video.caps,
          real_time: false
        }

        video_parser_out = %Membrane.H264.FFmpeg.Parser{
          alignment: :au,
          attach_nalus?: true
        }

        {frames_per_second, 1} = state.mixer_config.video.caps.framerate
        seconds_number = Membrane.Time.as_seconds(state.segment_duration.target)

        video_caps = state.mixer_config.video.caps

        initial_placement = %VideoPlacement{
          position: {0, 0},
          display_size: {video_caps.width, video_caps.height},
          z_value: 0.0
        }

        %ParentSpec{
          children: %{
            compositor: compositor,
            video_parser_out: video_parser_out,
            fake_source: %Membrane.BlankVideoGenerator{
              caps: %Membrane.RawVideo{
                width: video_caps.width,
                height: video_caps.height,
                pixel_format: :I420,
                framerate: video_caps.framerate,
                aligned: true
              },
              duration: :infinity
            },
            video_realtimer: Membrane.Realtimer
          },
          links: [
            link(:fake_source)
            |> to(:video_realtimer)
            |> via_in(:input, options: [initial_placement: initial_placement])
            |> to(:compositor),
            link(:compositor)
            |> to(:encoder, %Membrane.H264.FFmpeg.Encoder{
              profile: :baseline,
              gop_size: frames_per_second * seconds_number
            })
            |> to(:video_parser_out)
            |> via_in(Pad.ref(:input, :video),
              options: [
                encoding: :H264,
                segment_duration: state.segment_duration,
                partial_segment_duration: state.partial_segment_duration
              ]
            )
            |> to(:hls_sink_bin)
          ]
        }
      end
    else
      defp generate_compositor(_state, _ctx) do
        raise """
        Cannot find some of the modules required to use the video composer.
        Ensure that the following dependencies are added to the deps.
        #{merge_strings(@compositor_deps)}
        """
      end
    end

    if Enum.all?(@audio_mixer_deps, &Code.ensure_loaded?/1) do
      defp generate_audio_mixer(_state, ctx) when is_map_key(ctx.children, :audio_mixer),
        do: %ParentSpec{children: %{}, links: []}

      defp generate_audio_mixer(state, _ctx) do
        audio_mixer = %Membrane.AudioMixer{
          caps: %Membrane.RawAudio{
            channels: state.mixer_config.audio.channels,
            sample_rate: state.mixer_config.audio.sample_rate,
            sample_format: state.mixer_config.audio.sample_format
          },
          synchronize_buffers?: true
        }

        silence_generator = %Membrane.SilenceGenerator{
          caps: %Membrane.RawAudio{
            channels: state.mixer_config.audio.channels,
            sample_rate: state.mixer_config.audio.sample_rate,
            sample_format: state.mixer_config.audio.sample_format
          },
          duration: :infinity
        }

        %ParentSpec{
          children: %{
            silence_generator: silence_generator,
            audio_mixer: audio_mixer,
            aac_encoder: Membrane.AAC.FDK.Encoder,
            aac_parser: %Membrane.AAC.Parser{out_encapsulation: :none},
            audio_realtimer: Membrane.Realtimer
          },
          links: [
            link(:silence_generator)
            |> to(:audio_realtimer)
            |> to(:audio_mixer)
            |> to(:aac_encoder)
            |> to(:aac_parser)
            |> via_in(Pad.ref(:input, :audio),
              options: [
                encoding: :AAC,
                segment_duration: state.segment_duration,
                partial_segment_duration: state.partial_segment_duration
              ]
            )
            |> to(:hls_sink_bin)
          ]
        }
      end
    else
      defp generate_audio_mixer(_state, _ctx) do
        raise """
        Cannot find some of the modules required to use the audio mixer.
        Ensure that the following dependencies are added to the deps.
        #{merge_strings(@audio_mixer_deps)}
        """
      end
    end

    defp get_track_offset(%{stream_beginning: nil} = state),
      do: {0, Map.put(state, :stream_beginning, System.monotonic_time())}

    defp get_track_offset(state), do: {System.monotonic_time() - state.stream_beginning, state}

    defp hls_sink_bin_exists?(track, ctx, %{mixer_config: nil}),
      do: Map.has_key?(ctx.children, {:hls_sink_bin, track.stream_id})

    defp hls_sink_bin_exists?(_track, ctx, _state), do: Map.has_key?(ctx.children, :hls_sink_bin)

    defp get_depayloader(track) do
      track
      |> Track.get_depayloader()
      |> tap(&unless &1, do: raise("Couldn't find depayloader for track #{inspect(track)}"))
    end

    defp get_common_children(ctx) do
      children = [
        :compositor,
        :encoder,
        :video_parser_out,
        :hls_sink_bin,
        :audio_mixer,
        :aac_encoder,
        :aac_parser,
        :video_realtimer,
        :audio_realtimer,
        :fake_source,
        :silence_generator
      ]

      Enum.filter(children, &Map.has_key?(ctx.children, &1))
    end

    defp get_hls_stream_directory(%{mixer_config: nil} = state, track),
      do: Path.join(state.output_directory, track.stream_id)

    defp get_hls_stream_directory(state, _track), do: state.output_directory

    defp merge_parent_specs(spec1, spec2) do
      %ParentSpec{
        children: Map.merge(spec1.children, spec2.children),
        links: spec1.links ++ spec2.links
      }
    end

    defp filter_placements({Pad.ref(_type, id), _placement}, track),
      do: id == track.id or id == {:blank, track.id}

    defp update_layout_action(_track, _video_layout, %{mixer_config: nil}),
      do: []

    defp update_layout_action(%{type: :audio}, _video_layout, _state), do: []

    defp update_layout_action(_track, placements, _state),
      do: [forward: {:compositor, {:update_placement, placements}}]

    unless Enum.all?(@compositor_deps ++ @audio_mixer_deps, &Code.ensure_loaded?/1),
      do: defp(merge_strings(strings), do: Enum.join(strings, ", "))
  end
end
