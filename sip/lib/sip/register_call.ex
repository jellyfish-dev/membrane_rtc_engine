defmodule Membrane.RTC.Engine.Endpoint.SIP.RegisterCall do
  @moduledoc false

  use Membrane.RTC.Engine.Endpoint.SIP.Call

  alias Membrane.RTC.Engine.Endpoint.SIP.Call

  @impl Call
  def after_init(state) do
    send(self(), :register)
    state
  end

  @impl Call
  def handle_response(:register, 200, _response, state) do
    send(state.endpoint, :registered)
    state
  end

  @impl Call
  def handle_response(:register, status_code, response, state) do
    Call.handle_generic_response(status_code, response, state, &handle_transfer/3)
  end

  @impl GenServer
  def handle_info(:register, state) do
    headers =
      Call.build_headers(:register, state)
      |> Map.replace(:to, put_elem(state.headers_base.from, 2, %{}))

    # TODO: determine whether we really need userinfo here: Verify with Asterisk if needed
    registrar = %{
      state.registrar_credentials.uri
      | userinfo: state.registrar_credentials.username
    }

    message =
      Sippet.Message.build_request(:register, to_string(registrar))
      |> Map.put(:headers, headers)

    state = Call.make_request(message, state)

    Process.send_after(self(), :register, state.register_interval)
    {:noreply, state}
  end
end
