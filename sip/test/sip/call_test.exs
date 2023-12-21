defmodule Membrane.RTC.CallTest do
  use ExUnit.Case, async: false

  alias Membrane.RTC.Engine.Endpoint.SIP
  alias Membrane.RTC.Engine.Endpoint.SIP.Call

  setup do
    state =
      Call.init_state("my-call-id", %Call.Settings{
        endpoint: self(),
        rtp_port: 8888,
        sip_port: 8889,
        registrar_credentials:
          SIP.RegistrarCredentials.new(
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

  describe "timeouts" do
    test "work correctly for requests which have been responded to", %{state: state} do
      {state, cseq} = issue_request(:bye, state)
      assert Map.has_key?(state.pending_requests, cseq)

      {:noreply, state} =
        Sippet.Message.build_response(200)
        |> Map.put(:headers, %{cseq: {cseq, :bye}})
        |> then(&SIP.OutgoingCall.handle_cast({:response, &1}, state))

      refute Map.has_key?(state.pending_requests, cseq)

      {:noreply, _state} = SIP.OutgoingCall.handle_info({:timeout, cseq}, state)
    end

    test "raise for requests which received no response", %{state: state} do
      {state, cseq} = issue_request(:bye, state)
      assert Map.has_key?(state.pending_requests, cseq)

      # Let's modify the state so that it seems like the request was made 10 seconds ago
      #   With the current settings, this shouldn't trigger a timeout (yet)
      state = update_in(state, [:pending_requests, cseq], &(&1 - 10_000))
      {:noreply, state} = SIP.OutgoingCall.handle_info({:timeout, cseq}, state)

      # A timeout should be triggered if a request has been made more than 32 seconds ago
      state = update_in(state, [:pending_requests, cseq], &(&1 - 50_000))

      assert_raise RuntimeError, ~r/timeout/i, fn ->
        SIP.OutgoingCall.handle_info({:timeout, cseq}, state)
      end
    end

    test "work correctly for multi-response INVITE requests", %{state: state} do
      {state, cseq} = issue_request(:invite, state)
      assert Map.has_key?(state.pending_requests, cseq)

      Process.sleep(10)
      time_before_receiving_response = System.monotonic_time(:millisecond)

      assert Map.fetch!(state.pending_requests, cseq) < time_before_receiving_response

      Process.sleep(10)

      {:noreply, state} =
        Sippet.Message.build_response(100)
        |> Map.put(:headers, %{cseq: {cseq, :invite}})
        |> then(&SIP.OutgoingCall.handle_cast({:response, &1}, state))

      assert Map.has_key?(state.pending_requests, cseq)
      assert Map.fetch!(state.pending_requests, cseq) > time_before_receiving_response

      {:noreply, state} =
        Sippet.Message.build_response(180)
        |> Map.put(:headers, %{cseq: {cseq, :invite}})
        |> then(&SIP.OutgoingCall.handle_cast({:response, &1}, state))

      assert Map.has_key?(state.pending_requests, cseq)

      # We can't really send 200 as we have no SDP and it would crash
      #   Let's send 486 Busy Here instead
      {:noreply, state} =
        Sippet.Message.build_response(486)
        |> Map.put(:headers, %{cseq: {cseq, :invite}})
        |> then(&SIP.OutgoingCall.handle_cast({:response, &1}, state))

      refute Map.has_key?(state.pending_requests, cseq)
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
end
