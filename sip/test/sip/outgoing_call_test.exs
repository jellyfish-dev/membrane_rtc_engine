defmodule Membrane.RTC.OutgoingCallTest do
  use ExUnit.Case, async: false

  alias Membrane.RTC.Engine.Endpoint.SIP.{Call, OutgoingCall, RegistrarCredentials}

  setup do
    state =
      Call.init_state("my-call-id", %Call.Settings{
        endpoint: self(),
        rtp_port: 8888,
        sip_port: 8889,
        registrar_credentials:
          RegistrarCredentials.new(
            address: "localhost:9999",
            username: "user0",
            password: "some-password"
          ),
        external_ip: "1.2.3.4",
        register_interval: 30_000,
        phone_number: "12345678"
      })

    [state: state]
  end

  test "happy path with hangups", %{state: state} do
    # This sends an INVITE
    state = OutgoingCall.after_init(state)

    {:noreply, state} = handle_response(100, state)
    assert_receive {:call_info, :trying}

    {:noreply, state} = handle_response(180, state)
    assert_receive {:call_info, :ringing}

    # Session Progress
    {:noreply, state} = handle_response(183, state)

    sdp_answer =
      ExSDP.new(session_name: "MySuperDuperSession")
      |> Map.put(:connection_data, %ExSDP.ConnectionData{
        address: {1, 2, 3, 4},
        network_type: "IN"
      })
      |> ExSDP.add_media(ExSDP.Media.new(:audio, 7878, "RTP/AVP", 8))
      |> to_string()

    {:noreply, _state} =
      Sippet.Message.to_response(state.last_message, 200)
      |> Map.put(:body, sdp_answer)
      |> then(&OutgoingCall.handle_cast({:response, &1}, state))

    {:ok, connection_info} = Call.SDP.parse(sdp_answer)
    assert_receive {:call_info, {:call_ready, ^connection_info}}

    # User ends the call using OutgoingCall.bye/1
    {:noreply, _state} = OutgoingCall.handle_cast(:bye, state)
    assert_receive {:call_info, {:end, :user_hangup}}

    # The other side ends the call (we receive a BYE request)
    {:noreply, _state} =
      Sippet.Message.build_request(:bye, "sip:1.2.3.4:8889" |> Sippet.URI.parse!() |> to_string())
      # These headers are incorrect -- they are built as if we're the one sending the request,
      #   but it shouldn't matter for this test
      |> Map.put(:headers, Call.build_headers(:bye, state))
      |> put_in([:headers, "X-Asterisk-HangupCause"], ["Normal Clearing"])
      |> then(&OutgoingCall.handle_cast({:request, &1}, state))

    assert_receive {:call_info, {:end, :normal_clearing}}
  end

  test "declined/busy", %{state: state} do
    state = OutgoingCall.after_init(state)
    {:noreply, _state} = handle_response(403, state)
    assert_receive {:call_info, {:end, :declined}}

    state = OutgoingCall.after_init(state)
    {:noreply, _state} = handle_response(603, state)
    assert_receive {:call_info, {:end, :declined}}

    state = OutgoingCall.after_init(state)
    {:noreply, _state} = handle_response(486, state)
    assert_receive {:call_info, {:end, :busy}}

    state = OutgoingCall.after_init(state)
    {:noreply, _state} = handle_response(600, state)
    assert_receive {:call_info, {:end, :busy}}
  end

  test "cancel", %{state: state} do
    state = OutgoingCall.after_init(state)
    invite_request = state.last_message

    {:noreply, state} = handle_response(100, state)
    assert_receive {:call_info, :trying}

    {:noreply, state} = OutgoingCall.handle_cast(:cancel, state)
    assert_receive {:call_info, {:end, :cancelled}}

    # We can expect a 200 response to CANCEL, and a 487 Request Terminated to INVITE
    {:noreply, state} =
      invite_request
      |> Sippet.Message.to_response(487)
      |> then(&OutgoingCall.handle_cast({:response, &1}, state))

    {:noreply, _state} = handle_response(200, state)
    # Make sure this info is sent only once
    refute_receive {:call_info, {:end, :cancelled}}
  end

  test "transfer", %{state: state} do
    state = OutgoingCall.after_init(state)

    first_request = state.last_message
    new_callee = Sippet.URI.parse!("sip:23456789@localhost:9999")
    assert new_callee != state.callee

    {:noreply, state} =
      Sippet.Message.to_response(state.last_message, 301)
      |> put_in([:headers, :contact], [{"Transfer", new_callee, %{}}])
      |> then(&OutgoingCall.handle_cast({:response, &1}, state))

    assert new_callee == state.callee

    # Check that a new INVITE request was made to the new callee
    assert first_request != state.last_message
    refute Enum.empty?(state.pending_requests)
  end

  defp handle_response(response_code, state) do
    state.last_message
    |> Sippet.Message.to_response(response_code)
    |> then(&OutgoingCall.handle_cast({:response, &1}, state))
  end
end
