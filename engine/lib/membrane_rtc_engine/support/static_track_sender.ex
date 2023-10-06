defmodule Membrane.RTC.Engine.Support.StaticTrackSender do
  @moduledoc """
  This is a very simple version of
  `Membrane.RTC.Engine.Endpoint.WebRTC.TrackSender` element.

  Engine forwards track starting from a keyframe.
  Therefore, whenever some endpoint requests some
  track, engine sends keyframe request to the track
  source.

  In case of publishing from a file we are not able to
  generate keyframe on request. This element ignores
  incoming demands and starts sending data after receiving
  first keyframe request. Subsequent keyframe requests
  are ignored.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.Buffer
  alias Membrane.RTC.Engine.Event.TrackVariantResumed
  alias Membrane.RTC.Engine.Track

  def_options track: [
                type: :struct,
                spec: Membrane.RTC.Engine.Track.t(),
                description: "Track this sender will maintain"
              ],
              is_keyframe: [
                spec: (Membrane.Buffer.t(), Track.t() -> boolean()),
                description: "Function informing if buffer is a keyframe for this track"
              ]

  def_input_pad :input,
    mode: :pull,
    demand_unit: :buffers,
    demand_mode: :manual,
    accepted_format: Membrane.RTP

  def_output_pad :output,
    mode: :pull,
    demand_mode: :manual,
    accepted_format: Membrane.RTP

  @impl true
  def handle_init(_ctx, %__MODULE__{track: track, is_keyframe: is_keyframe}) do
    {[], %{track: track, started?: false, is_keyframe: is_keyframe}}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _ctx, %{started?: false} = state) do
    {[], state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, %{started?: true} = state) do
    {[demand: {:input, size}], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[event: {:output, %TrackVariantResumed{variant: :high}}], state}
  end

  @impl true
  def handle_event(:output, %Membrane.KeyframeRequestEvent{}, _ctx, state) do
    {[redemand: :output], %{state | started?: true}}
  end

  @impl true
  def handle_process(:input, buffer, _ctx, state) do
    buffer = add_is_keyframe_flag(buffer, state)
    {[buffer: {:output, buffer}, redemand: :output], state}
  end

  defp add_is_keyframe_flag(buffer, state) do
    is_keyframe = state.is_keyframe.(buffer, state.track)

    new_metadata = Map.put(buffer.metadata, :is_keyframe, is_keyframe)
    %Buffer{buffer | metadata: new_metadata}
  end
end
