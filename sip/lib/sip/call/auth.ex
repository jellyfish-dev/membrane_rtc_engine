defmodule Membrane.RTC.Engine.Endpoint.SIP.Call.Auth do
  @moduledoc false

  alias Membrane.RTC.Engine.Endpoint.SIP.RegistrarCredentials

  @spec apply_digest(
          Sippet.Message.request(),
          Sippet.Message.response(),
          RegistrarCredentials.t()
        ) :: Sippet.Message.request()
  def apply_digest(request, response, credentials) do
    {:ok, request} =
      Sippet.DigestAuth.make_request(
        request,
        response,
        fn realm -> get_userinfo(realm, credentials) end
      )

    request =
      update_in(request[:headers][:via], fn [elem] ->
        [put_elem(elem, 3, %{"branch" => Sippet.Message.create_branch()})]
      end)

    request =
      update_in(request[:headers][:cseq], fn {cseq, method} ->
        {cseq + 1, method}
      end)

    request
  end

  defp get_userinfo(_realm, credentials) do
    {:ok, credentials.username, credentials.password}
  end
end
