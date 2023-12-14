defmodule Membrane.RTC.Engine.Endpoint.SIP.SippetCore do
  @moduledoc false

  use Sippet.Core

  require Membrane.Logger

  alias Membrane.Logger
  alias Membrane.RTC.Engine.Endpoint.SIP.Call

  @sippet_id __MODULE__

  @spec setup() :: :ok
  def setup() do
    {:ok, _pid} = Sippet.start_link(name: @sippet_id)
    {:ok, _pid} = Sippet.Transports.UDP.start_link(name: @sippet_id)
    Sippet.register_core(@sippet_id, __MODULE__)
  end

  @spec send_message(Sippet.Message.t()) :: :ok | {:error, term()}
  def send_message(message) do
    Sippet.send(@sippet_id, message)
  end

  @impl true
  def receive_request(
        %Sippet.Message{start_line: %{method: method}} = incoming_request,
        server_key
      ) do
    Logger.debug(
      "Sippet receive_request (server_key=#{inspect(server_key)}): #{inspect(incoming_request)}"
    )

    call_id = Sippet.Message.get_header(incoming_request, :call_id)

    cond do
      # We don't support incoming calls until new sip client implementation
      Call.exists?(call_id) ->
        Call.handle_request(call_id, incoming_request)

      method == :notify ->
        incoming_request
        |> Sippet.Message.to_response(200)
        |> send_message()

      true ->
        Logger.warning("""
          SIP client: Call #{inspect(call_id)} doesn't exist. Incoming calls are unsupported
        """)
    end
  end

  @impl true
  def receive_response(incoming_response, client_key) do
    Logger.debug(
      "Sippet receive_response (client_key=#{inspect(client_key)}): #{inspect(incoming_response)}"
    )

    Call.handle_response(incoming_response.headers.call_id, incoming_response)
  end

  @impl true
  def receive_error(reason, client_or_server_key) do
    Logger.warning("""
      SIP client: Received an error (key=#{inspect(client_or_server_key)}): #{inspect(reason)}
    """)

    # route the error to your UA or proxy process
    # TODO Honestly I don't know how to handle those errors, probably is nicely to pass them up.
  end
end
