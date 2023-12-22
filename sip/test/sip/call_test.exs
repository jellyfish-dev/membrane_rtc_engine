defmodule Membrane.RTC.CallTest do
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

  describe "OutgoingCall INVITE" do
    test "happy path", %{state: state} do
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
    end

    test "declined/busy", %{state: state} do
      state = OutgoingCall.after_init(state)

      {:noreply, state} = handle_response(403, state)
      assert_receive {:call_info, {:end, :declined}}

      state = OutgoingCall.after_init(state)
      {:noreply, state} = handle_response(603, state)
      assert_receive {:call_info, {:end, :declined}}

      state = OutgoingCall.after_init(state)
      {:noreply, state} = handle_response(486, state)
      assert_receive {:call_info, {:end, :busy}}

      state = OutgoingCall.after_init(state)
      {:noreply, _state} = handle_response(600, state)
      assert_receive {:call_info, {:end, :busy}}
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
  end

  describe "responses" do
    test "are processed only when the CSeq matches a pending request", %{state: state} do
      {state, cseq} = issue_request(:bye, state)
      assert Map.has_key?(state.pending_requests, cseq)

      {:noreply, state} =
        Sippet.Message.build_response(200)
        |> Map.put(:headers, %{cseq: {cseq + 9001, :bye}})
        |> then(&OutgoingCall.handle_cast({:response, &1}, state))

      assert Map.has_key?(state.pending_requests, cseq)

      {:noreply, state} = handle_response(200, state)
      refute Map.has_key?(state.pending_requests, cseq)
    end
  end

  describe "timeouts" do
    test "work correctly for requests which have been responded to", %{state: state} do
      {state, cseq} = issue_request(:bye, state)
      assert Map.has_key?(state.pending_requests, cseq)

      {:noreply, state} = handle_response(200, state)
      refute Map.has_key?(state.pending_requests, cseq)

      {:noreply, _state} = OutgoingCall.handle_info({:timeout, cseq}, state)
    end

    test "raise for requests which received no response", %{state: state} do
      {state, cseq} = issue_request(:bye, state)
      assert Map.has_key?(state.pending_requests, cseq)

      # Let's modify the state so that it seems like the request was made 10 seconds ago
      #   With the current settings, this shouldn't trigger a timeout (yet)
      state = update_in(state, [:pending_requests, cseq], &(&1 - 10_000))
      {:noreply, state} = OutgoingCall.handle_info({:timeout, cseq}, state)

      # A timeout should be triggered if a request has been made more than 32 seconds ago
      state = update_in(state, [:pending_requests, cseq], &(&1 - 50_000))

      assert_raise RuntimeError, ~r/timeout/i, fn ->
        OutgoingCall.handle_info({:timeout, cseq}, state)
      end
    end

    test "work correctly for multi-response INVITE requests", %{state: state} do
      {state, cseq} = issue_request(:invite, state)
      assert Map.has_key?(state.pending_requests, cseq)

      Process.sleep(10)

      time_before_receiving_response = System.monotonic_time(:millisecond)
      assert Map.fetch!(state.pending_requests, cseq) < time_before_receiving_response

      Process.sleep(10)

      {:noreply, state} = handle_response(100, state)
      assert Map.has_key?(state.pending_requests, cseq)
      assert Map.fetch!(state.pending_requests, cseq) > time_before_receiving_response

      {:noreply, state} = handle_response(180, state)
      assert Map.has_key?(state.pending_requests, cseq)

      {:noreply, state} = handle_response(486, state)
      refute Map.has_key?(state.pending_requests, cseq)

      {:noreply, _state} = OutgoingCall.handle_info({:timeout, cseq}, state)
    end
  end

  defp issue_request(method, state) do
    headers = Call.build_headers(method, state)
    {cseq, ^method} = headers.cseq

    state =
      Sippet.Message.build_request(method, to_string(state.callee))
      |> Map.put(:headers, headers)
      |> Call.make_request(state)

    {state, cseq}
  end

  defp handle_response(response_code, state) do
    state.last_message
    |> Sippet.Message.to_response(response_code)
    |> then(&OutgoingCall.handle_cast({:response, &1}, state))
  end
end
