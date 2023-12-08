defmodule Membrane.RTC.Engine.Endpoint.SIP.Call do
  @moduledoc false

  require Membrane.Logger

  alias Membrane.Logger
  alias Membrane.RTC.Engine.Endpoint.SIP
  alias Membrane.RTC.Engine.Endpoint.SIP.Call.{Auth, Headers, Settings}
  alias Membrane.RTC.Engine.Endpoint.SIP.SippetCore

  @type id :: String.t()
  @type state :: map()

  @callback start_link(Settings.t()) :: {id(), pid()}
  @callback after_init(state :: state()) :: state()
  @callback handle_request(
              method :: atom(),
              request :: Sippet.Message.request(),
              state :: state()
            ) :: state()
  @callback handle_response(
              method :: atom(),
              status_code :: pos_integer(),
              response :: Sippet.Message.response(),
              state :: state()
            ) :: state()

  defmacro __using__(_opts) do
    quote location: :keep do
      use GenServer

      require Membrane.Logger

      alias Membrane.Logger
      alias Membrane.RTC.Engine.Endpoint.SIP

      @behaviour SIP.Call

      @impl SIP.Call
      def start_link(settings) do
        call_id = Sippet.Message.create_call_id()
        Logger.debug("SIP Client: Starting call process with id #{inspect(call_id)}")

        {:ok, pid} =
          GenServer.start_link(__MODULE__, {call_id, settings},
            name: SIP.Call.registry_id(call_id)
          )

        {call_id, pid}
      end

      @impl SIP.Call
      def after_init(state) do
        state
      end

      @impl SIP.Call
      def handle_request(_method, _request, state) do
        state
      end

      @impl SIP.Call
      def handle_response(_method, status_code, response, state) do
        SIP.Call.handle_generic_response(status_code, response, state)
      end

      defoverridable after_init: 1, handle_request: 3, handle_response: 4

      defguardp is_request_pending(state, cseq) when is_map_key(state.pending_requests, cseq)

      @impl GenServer
      def init({call_id, settings}) do
        state = SIP.Call.init_state(call_id, settings)
        {:ok, __MODULE__.after_init(state)}
      end

      # This case is disabled for INVITEs because:
      # * `pending_requests` is primarily used for retransmissions
      # * when we send an INVITE, the server will respond with 100 Trying, 180 Ringing and then 200 OK
      # * since we don't want to send retransmissions if we receive a response from the server,
      #   we're deleting the entire INVITE request from `pending_requests` after receiving 100
      # * ...which means the case below would kick in when we receive 180 and 200, and nothing would work
      @impl GenServer
      def handle_cast({:response, %Sippet.Message{headers: %{cseq: {cseq, method}}}}, state)
          when method != :invite and not is_request_pending(state, cseq) do
        Logger.warning(
          "SIP Client: Received response with CSeq #{cseq}, for which there is no pending request. Ignoring."
        )

        {:noreply, state}
      end

      @impl GenServer
      def handle_cast({:response, %{headers: %{cseq: {cseq, method}}} = response}, state) do
        Logger.debug("Received response in call: #{inspect(response)}")

        state =
          __MODULE__.handle_response(method, response.start_line.status_code, response, state)

        {:noreply, %{state | pending_requests: Map.delete(state.pending_requests, cseq)}}
      end

      @impl GenServer
      def handle_cast({:request, %{headers: %{cseq: {_cseq, method}}} = request}, state) do
        Logger.debug("Received request in call: #{inspect(request)}")
        {:noreply, __MODULE__.handle_request(method, request, state)}
      end

      @impl GenServer
      def handle_info({:retransmission, cseq, 0}, state) when is_request_pending(state, cseq) do
        raise "SIP Client: Reached retransmission limit"
      end

      @impl GenServer
      def handle_info({:retransmission, cseq, attempts}, state)
          when is_request_pending(state, cseq) do
        Logger.warning("SIP Client: No response received. Attempts left: #{attempts - 1}")
        state = SIP.Call.make_request(state.last_message, state, attempts - 1)
        {:noreply, state}
      end

      @impl GenServer
      def handle_info({:retransmission, _cseq, _attempts}, state) do
        {:noreply, state}
      end
    end
  end

  @max_retransmission_attempts 3
  @retransmission_delay 5_000

  ## MANAGEMENT API

  @spec exists?(id()) :: boolean()
  def exists?(call_id) do
    Registry.lookup(SipEndpoint.CallRegistry, call_id) != []
  end

  ## INCOMING API

  @spec handle_request(id(), term()) :: :ok
  def handle_request(call_id, request) do
    GenServer.cast(registry_id(call_id), {:request, request})
  end

  @spec handle_response(id(), term()) :: :ok
  def handle_response(call_id, response) do
    GenServer.cast(registry_id(call_id), {:response, response})
  end

  ## PRIVATE API (for modules implementing the behaviour)

  @spec registry_id(id()) :: {:via, module(), term()}
  def registry_id(call_id) do
    {:via, Registry, {SipEndpoint.CallRegistry, call_id}}
  end

  @spec init_state(id(), Settings.t()) :: state()
  def init_state(call_id, settings) do
    from_address = %Sippet.URI{
      scheme: "sip",
      userinfo: settings.registrar_credentials.username,
      host: settings.external_ip,
      port: settings.sip_port
    }

    settings
    |> Map.from_struct()
    |> Map.merge(%{
      call_id: call_id,
      callee: nil,
      headers_base: Headers.create_headers_base(from_address),
      cseq: 0,
      last_message: nil,
      pending_requests: %{}
    })
  end

  @spec build_headers(atom(), state(), String.t()) :: map()
  def build_headers(method, state, branch \\ Sippet.Message.create_branch()) do
    state.headers_base
    |> Map.merge(%{
      to: {"", state.callee, %{}},
      call_id: state.call_id,
      cseq: {state.cseq + 1, method},
      content_length: 0
    })
    |> update_in([:via], fn via -> [Tuple.append(via, %{"branch" => branch})] end)
  end

  @spec make_request(Sippet.Message.request(), state(), non_neg_integer()) ::
          state() | no_return()
  def make_request(message, state, attempts_left \\ @max_retransmission_attempts) do
    with :ok <- SippetCore.send_message(message) do
      {cseq, _method} = message.headers.cseq

      pending_requests = Map.put(state.pending_requests, cseq, true)

      Process.send_after(
        self(),
        {:retransmission, cseq, attempts_left},
        @retransmission_delay
      )

      %{state | cseq: cseq, last_message: message, pending_requests: pending_requests}
    else
      error ->
        Logger.debug("Register failed with message: #{inspect(message)}")
        raise "SIP Client: Unable to send message: #{inspect(error)}."
    end
  end

  @spec handle_generic_response(pos_integer(), Sippet.Message.response(), state()) ::
          state() | no_return()
  def handle_generic_response(status_code, response, state) do
    case status_code do
      200 ->
        state

      401 ->
        handle_unauthorized(response, state)

      407 ->
        raise "SIP Client: Received 407 response. Proxy authorization is unsupported"

      _other ->
        raise """
        SIP Client: Received unhandled response
          with code #{status_code} (#{inspect(response.start_line.reason_phrase)}):
          #{inspect(response)}
        """
    end
  end

  defp handle_unauthorized(response, state) do
    authorization_headers = Map.get(state.last_message.headers, :authorization, [])

    cond do
      not Enum.empty?(authorization_headers) ->
        raise "SIP Client: Unable to authorize using digest auth (incorrect credentials?)"

      not Sippet.Message.has_header?(response, :www_authenticate) ->
        raise "SIP Client: Unable to authorize using digest auth (no `www-authenticate` header present)"

      true ->
        request = Auth.apply_digest(state.last_message, response, state.registrar_credentials)
        make_request(request, state)
    end
  end
end
