defmodule Membrane.RTC.Engine.PushOutputTee do
  @moduledoc """
  Element forwarding packets to multiple push outputs.
  """
  use Membrane.Filter

  def_options codec: [
                type: :atom,
                spec: [:H264 | :VP8 | :OPUS],
                description: "Codec of track #{inspect(__MODULE__)} will forward."
              ],
              telemetry_metadata: [
                spec: Keyword.t(),
                default: []
              ]

  def_input_pad :input,
    availability: :always,
    mode: :pull,
    demand_mode: :auto,
    caps: :any

  def_output_pad :output,
    availability: :on_request,
    mode: :push,
    caps: :any

  @impl true
  def handle_init(opts) do
    Membrane.RTC.Utils.register_event_with_telemetry_metadata(
      opts.telemetry_metadata,
      opts.codec
    )

    {:ok,
     %{
       codec: opts.codec,
       caps: nil,
       telemetry_metadata: opts.telemetry_metadata
     }}
  end

  @impl true
  def handle_caps(_pad, caps, _ctx, state) do
    {{:ok, forward: caps}, %{state | caps: caps}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, _ref), _ctx, %{caps: nil} = state) do
    {:ok, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, _ref) = pad, _ctx, %{caps: caps} = state) do
    {{:ok, caps: {pad, caps}}, state}
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, _ctx, state) do
    Membrane.RTC.Utils.emit_telemetry_event_with_packet_mesaurments(
      buffer.payload,
      state.telemetry_metadata,
      state.codec
    )

    {{:ok, forward: buffer}, state}
  end
end
