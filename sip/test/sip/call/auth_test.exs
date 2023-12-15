defmodule Membrane.RTC.AuthTest do
  use ExUnit.Case, async: true

  alias Membrane.RTC.Engine.Endpoint.SIP.Call.Auth
  alias Membrane.RTC.Engine.Endpoint.SIP.RegistrarCredentials
  alias Sippet.{DigestAuth, Message}

  @address "my-sip-server.net"
  @credentials RegistrarCredentials.new(
                 address: @address,
                 username: "my-username",
                 password: "my-password"
               )
  @call_id Message.create_call_id()
  @original_branch Message.create_branch()
  @original_cseq {1, :register}

  test "digest auth works correctly" do
    sender_uri = Sippet.URI.parse!("sip:user0@1.2.3.4")

    headers = %{
      via: [{{2, 0}, :udp, {"1.2.3.4", 0}, %{"branch" => @original_branch}}],
      to: {"", nil, %{}},
      from: {"Engine", sender_uri, %{"tag" => Message.create_tag()}},
      user_agent: "RTC Engine/SIP/0.1",
      content_length: 0,
      call_id: @call_id,
      contact: [{"Engine", sender_uri, %{}}],
      cseq: @original_cseq,
      max_forwards: 70
    }

    request =
      Message.build_request(:register, "sip:#{@address}")
      |> Map.put(:headers, headers)

    {:ok, response} = DigestAuth.make_response(request, 401, "hyperborea")

    start_line = request.start_line

    %Message{
      start_line: ^start_line,
      headers: %{
        via: [{_, _, _, %{"branch" => new_branch}}],
        call_id: @call_id,
        cseq: cseq,
        authorization: [{"Digest", digest_params}]
      }
    } = Auth.apply_digest(request, response, @credentials)

    {sn, method} = @original_cseq
    {new_sn, ^method} = cseq
    assert new_sn == sn + 1

    assert new_branch != @original_branch
    refute Enum.empty?(digest_params)
  end
end
