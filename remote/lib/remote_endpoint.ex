defmodule Membrane.RTC.Engine.Endpoint.Remote do
  @moduledoc """
  A Remote Endpoint
  """

  use Membrane.Bin

  require Membrane.Logger

  alias Membrane.RTC.Engine.Endpoint.Remote

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
              link_proposal: [
                spec: Remote.LinkProposal.t() | nil,
                default: nil
              ]

  @impl true
  def handle_init(_ctx, opts) do
    state =
      opts
      |> Map.from_struct()
      |> Map.merge(%{
        partner_endpoint: nil,
        status: :initialized
      })

    {[], state}
  end

  @impl true
  def handle_setup(ctx, state) do
    {:endpoint, endpoint_id} = ctx.name
    myself = :"#{endpoint_id}"
    Process.register(self(), myself)

    {actions, state_update} =
      case state.link_proposal do
        %Remote.LinkProposal{token: token, link_to: partner_endpoint} ->
          token = token || generate_token()

          unless is_nil(partner_endpoint) do
            send(
              partner_endpoint,
              {:handshake, %Remote.LinkProposal{token: token, link_to: {myself, Node.self()}},
               token}
            )
          end

          {
            [setup: :incomplete],
            %{token: token, partner_endpoint: partner_endpoint, status: :linking}
          }

        nil ->
          token = generate_token()

          setup = %Remote.LinkProposal{
            token: token,
            link_to: {myself, Node.self()}
          }

          {
            [setup: :incomplete, notify_parent: {:forward_to_parent, {:link_proposal, setup}}],
            %{token: token, partner_endpoint: nil, status: :waiting_for_partner}
          }
      end

    {actions, Map.merge(state, state_update)}
  end

  @impl true
  def handle_info(
        {:handshake, %Remote.LinkProposal{token: new_token, link_to: new_partner_endpoint},
         incoming_token},
        _ctx,
        %{status: status, token: token} = state
      )
      when token == incoming_token do
    state =
      Enum.reduce(%{partner_endpoint: new_partner_endpoint, token: new_token}, state, fn {key,
                                                                                          value},
                                                                                         acc ->
        if value, do: Map.put(acc, key, value), else: acc
      end)

    case status do
      :handshaked ->
        {[], state}

      _other ->
        send(state.partner_endpoint, {:handshake, %Remote.LinkProposal{}, state.token})

        {
          [notify_parent: :ready, setup: :complete],
          %{state | status: :handshaked}
        }
    end
  end

  @impl true
  def handle_info({:handshake, _link_proposal, _incoming_token}, _ctx, state) do
    {[], state}
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
  def handle_parent_notification({:new_tracks, _tracks}, _ctx, state) do
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

  defp generate_token(), do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
