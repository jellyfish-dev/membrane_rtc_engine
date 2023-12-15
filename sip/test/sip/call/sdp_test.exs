defmodule Membrane.RTC.CallSDPTest do
  use ExUnit.Case, async: true

  alias Membrane.RTC.Engine.Endpoint.SIP.Call

  @connection_data %ExSDP.ConnectionData{address: {1, 2, 3, 4}, network_type: "IN"}
  @rtp_port 2140
  @pt 8
  @encoding_name :PCMA
  @clock_rate 8000

  @medialess_sdp_answer ExSDP.new(session_name: "MySuperDuperSession")
                        |> Map.put(:connection_data, @connection_data)

  @acceptable_sdp_answer ExSDP.add_media(
                           @medialess_sdp_answer,
                           ExSDP.Media.new(:audio, @rtp_port, "RTP/AVP", @pt)
                         )

  test "parsing sdp answer works correctly" do
    {:ok,
     %{
       rtp_payload_fmt: {@pt, %{encoding_name: @encoding_name, clock_rate: @clock_rate}},
       connection_data: @connection_data,
       port: @rtp_port
     }} = Call.SDP.parse(@acceptable_sdp_answer |> to_string())

    {:error, :no_audio_media} = Call.SDP.parse(@medialess_sdp_answer |> to_string())

    {:error, :no_audio_media} =
      Call.SDP.parse(
        @medialess_sdp_answer
        |> ExSDP.add_media(ExSDP.Media.new(:video, 1234, "RTP/AVP", 96))
        |> to_string()
      )

    {:error, :unknown_fmt} =
      Call.SDP.parse(
        @medialess_sdp_answer
        |> ExSDP.add_media(ExSDP.Media.new(:audio, 1234, "other", "???"))
        |> to_string()
      )

    {:error, :no_common_fmt} =
      Call.SDP.parse(
        @medialess_sdp_answer
        |> ExSDP.add_media(ExSDP.Media.new(:audio, 1234, "RTP/AVP", 0))
        |> to_string()
      )

    {:error, :no_common_fmt} =
      Call.SDP.parse(
        @medialess_sdp_answer
        |> ExSDP.add_media(ExSDP.Media.new(:audio, 1234, "RTP/AVP", [0, 1, 2, 3, 4, 5, 6, 7]))
        |> to_string()
      )
  end
end
