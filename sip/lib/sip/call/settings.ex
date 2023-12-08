defmodule Membrane.RTC.Engine.Endpoint.SIP.Call.Settings do
  @moduledoc false

  alias Membrane.RTC.Engine.Endpoint.SIP.RegistrarCredentials

  @type t :: %__MODULE__{
          endpoint: pid(),
          rtp_port: 1..65_535,
          sip_port: 1..65_535,
          registrar_credentials: RegistrarCredentials.t(),
          external_ip: String.t(),
          register_interval: non_neg_integer()
        }

  @enforce_keys [
    :endpoint,
    :rtp_port,
    :sip_port,
    :registrar_credentials,
    :external_ip,
    :register_interval
  ]

  defstruct @enforce_keys
end
