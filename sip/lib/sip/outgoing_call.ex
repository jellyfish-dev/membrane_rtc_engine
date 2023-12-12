defmodule Membrane.RTC.Engine.Endpoint.SIP.OutgoingCall do
  @moduledoc false

  use Membrane.RTC.Engine.Endpoint.SIP.Call

  alias Membrane.RTC.Engine.Endpoint.SIP.{Call, SippetCore}
  alias Membrane.RTC.Engine.Endpoint.SIP.Call.SDP

  ## OUTGOING API

  @spec dial(Call.id(), String.t()) :: :ok
  def dial(call_id, phone_number) do
    GenServer.cast(Call.registry_id(call_id), {:invite, phone_number})
  end

  @spec cancel(Call.id()) :: :ok
  def cancel(call_id) do
    GenServer.cast(Call.registry_id(call_id), :cancel)
  end

  @spec bye(Call.id()) :: :ok
  def bye(call_id) do
    GenServer.cast(Call.registry_id(call_id), :bye)
  end

  ## SIP.Call CALLBACKS

  @impl Call
  def handle_response(:invite, status_code, response, state) do
    case status_code do
      status_code when status_code in 100..199 ->
        handle_provisional_invite_response(status_code, state)
        state

      200 ->
        send_ack(response, state)

        case SDP.parse(response.body) do
          {:ok, connection_info} ->
            notify_endpoint(state.endpoint, {:call_ready, connection_info})
            state

          {:error, reason} ->
            bye(state.call_id)
            # Give Sippet time to send the request (this is async)
            Process.sleep(50)

            raise "SIP Client: Call connection error, received SDP answer is not matching our requirements: #{inspect(reason)}"
        end

      403 ->
        raise "SIP Client: Got response 403 Forbidden (call declined?)"

      _other ->
        Call.handle_generic_response(status_code, response, state)
    end
  end

  @impl Call
  def handle_response(_method, status_code, response, state) do
    Call.handle_generic_response(status_code, response, state)
  end

  @impl Call
  def handle_request(:notify, request, state) do
    respond(request, 200)
    state
  end

  @impl Call
  def handle_request(:bye, request, state) do
    respond(request, 200)

    # Give Sippet time to respond to the BYE (this is async)
    Process.sleep(50)

    notify_endpoint(state.endpoint, {:end, hangup_cause(request)})
    state
  end

  ## GenServer CALLBACKS

  @impl GenServer
  def handle_cast({:invite, phone_number}, state) do
    callee = %{state.registrar_credentials.uri | userinfo: phone_number}
    state = %{state | callee: callee}

    {body, content_length} = SDP.proposal(state.external_ip, state.rtp_port)

    headers =
      Call.build_headers(:invite, state)
      |> Map.replace(:content_length, content_length)

    message =
      Sippet.Message.build_request(:invite, to_string(callee))
      |> Map.put(:headers, headers)
      |> Sippet.Message.put_header(:content_type, "application/sdp")
      |> Map.replace(:body, body)

    state = Call.make_request(message, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(:cancel, state) do
    headers = Call.build_headers(:cancel, state)

    message =
      Sippet.Message.build_request(:cancel, to_string(state.callee))
      |> Map.put(:headers, headers)

    state = Call.make_request(message, state)

    # Give Sippet time to send the request (this is async)
    Process.sleep(50)

    notify_endpoint(state.endpoint, {:end, :cancelled})

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(:bye, state) do
    headers = Call.build_headers(:bye, state)

    message =
      Sippet.Message.build_request(:bye, to_string(state.callee))
      |> Map.put(:headers, headers)

    state = Call.make_request(message, state)

    notify_endpoint(state.endpoint, {:end, :user_hangup})

    {:noreply, state}
  end

  ## PRIVATE FUNCTIONS

  defp respond(request, code) do
    request
    |> Sippet.Message.to_response(code)
    |> SippetCore.send_message()
  end

  defp notify_endpoint(endpoint, message) do
    send(endpoint, {:call_info, message})
  end

  defp handle_provisional_invite_response(100, state),
    do: notify_endpoint(state.endpoint, :trying)

  defp handle_provisional_invite_response(180, state),
    do: notify_endpoint(state.endpoint, :ringing)

  # Session Progress
  defp handle_provisional_invite_response(183, _state), do: nil

  defp handle_provisional_invite_response(code, _state),
    do: Logger.warning("SIP Client: Received unknown provisional response #{code}. Ignoring.")

  defp send_ack(response, state) do
    %Sippet.Message{
      headers: %{
        to: to,
        via: [{_, _, _, %{"branch" => branch}}],
        cseq: {cseq, _method}
      }
    } = response

    headers =
      Call.build_headers(:ack, state, branch)
      |> Map.replace(:to, to)
      |> Map.replace(:cseq, {cseq, :ack})

    message =
      Sippet.Message.build_request(:ack, to_string(state.callee))
      |> Map.put(:headers, headers)

    SippetCore.send_message(message)
  end

  defp hangup_cause(request) do
    case Sippet.Message.get_header(request, "X-Asterisk-HangupCause", []) do
      ["Normal Clearing"] -> :normal_clearing
      [] -> :unknown
      [other | _rest] -> other
    end
  end
end
