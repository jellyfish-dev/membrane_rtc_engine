defmodule Membrane.RTC.Engine.Endpoint.SIP.Call do
  @moduledoc false

  require Membrane.Logger

  alias Membrane.Logger
  alias Membrane.RTC.Engine.Endpoint.SIP
  alias Membrane.RTC.Engine.Endpoint.SIP.Call.{Auth, Headers, Settings}
  alias Membrane.RTC.Engine.Endpoint.SIP.{CallRegistry, SippetCore}

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

      @impl GenServer
      def init({call_id, settings}) do
        state = SIP.Call.init_state(call_id, settings)
        {:ok, __MODULE__.after_init(state)}
      end

      @impl GenServer
      def handle_cast(
            {:response, %{headers: %{cseq: {cseq, method}}} = response},
            %{cseq: cseq} = state
          ) do
        Logger.debug("Received response in call: #{inspect(response)}")

        state =
          __MODULE__.handle_response(method, response.start_line.status_code, response, state)

        {:noreply, state}
      end

      @impl GenServer
      def handle_cast({:response, %Sippet.Message{headers: %{cseq: {cseq, _method}}}}, state) do
        Logger.warning(
          "SIP Client: Received response with CSeq #{cseq}, which doesn't match last request CSeq (#{state.cseq}). Ignoring."
        )

        {:noreply, state}
      end

      @impl GenServer
      def handle_cast({:request, %{headers: %{cseq: {_cseq, method}}} = request}, state) do
        Logger.debug("Received request in call: #{inspect(request)}")
        {:noreply, __MODULE__.handle_request(method, request, state)}
      end
    end
  end

  ## MANAGEMENT API

  @spec exists?(id()) :: boolean()
  def exists?(call_id) do
    Registry.lookup(CallRegistry, call_id) != []
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
    {:via, Registry, {CallRegistry, call_id}}
  end

  @spec init_state(id(), Settings.t()) :: state()
  def init_state(call_id, settings) do
    from_address = %Sippet.URI{
      scheme: "sip",
      userinfo: settings.registrar_credentials.username,
      host: settings.external_ip,
      port: settings.sip_port
    }

    callee =
      if is_nil(settings.phone_number),
        do: nil,
        else: %{settings.registrar_credentials.uri | userinfo: settings.phone_number}

    settings
    |> Map.from_struct()
    |> Map.merge(%{
      call_id: call_id,
      callee: callee,
      headers_base: Headers.create_headers_base(from_address),
      cseq: 0,
      last_message: nil
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

  @spec make_request(Sippet.Message.request(), state()) :: state() | no_return()
  def make_request(message, state) do
    with :ok <- SippetCore.send_message(message) do
      {cseq, _method} = message.headers.cseq

      %{state | cseq: cseq, last_message: message}
    else
      error ->
        Logger.debug("Send failed with message: #{inspect(message)}")
        raise "SIP Client: Unable to send message: #{inspect(error)}"
    end
  end

  @spec handle_generic_response(pos_integer(), Sippet.Message.response(), state()) ::
          state() | no_return()
  def handle_generic_response(status_code, response, state) do
    case status_code do
      success when success in [200, 204] ->
        state

      401 ->
        handle_unauthorized(response, state)

      407 ->
        raise "SIP Client: Received 407 response. Proxy authorization is unsupported"

      redirect when redirect in 300..399 ->
        raise "SIP Client: Received redirection response with code #{status_code}. Redirections are unsupported"

      _other_failure ->
        raise """
        SIP Client: Received unhandled failure response
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
