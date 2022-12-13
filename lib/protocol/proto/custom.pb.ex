defmodule MembraneRtcEngine.Protocol.WebRtcCustomMediaEvent do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  oneof :event, 0

  field :test, 1, type: MembraneRtcEngine.Protocol.Test, oneof: 0
end

defmodule MembraneRtcEngine.Protocol.Test do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.11.0", syntax: :proto3

  field :payload, 1, type: :string
end