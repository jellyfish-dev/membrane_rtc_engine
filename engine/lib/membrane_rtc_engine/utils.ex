defmodule Membrane.RTC.Utils do
  @moduledoc false

  # This is workaround to make dialyzer happy.
  # In other case we would have to specify all possible CallbackContext types here.
  # Maybe membrane_core should have something like
  # @type Membrane.Pipeline.CallbackContxt.t() ::  CallbackContext.Notification.t()
  #  | CallbackContext.Other.t()
  #  | CallbackContext.PlaybackChange.t()
  #  | etc.
  # to make it easier to reference CallbackContext types.
  @type ctx :: any()

  defmacro find_child(ctx, pattern: pattern) do
    quote do
      unquote(ctx).children |> Map.keys() |> Enum.find(&match?(unquote(pattern), &1))
    end
  end

  defmacro filter_children(ctx, pattern: pattern) do
    quote do
      unquote(ctx).children |> Map.keys() |> Enum.filter(&match?(unquote(pattern), &1))
    end
  end

  @spec reduce_children(ctx :: ctx(), acc :: any(), fun :: fun()) ::
          any()
  def reduce_children(ctx, acc, fun) do
    ctx.children |> Map.keys() |> Enum.reduce(acc, fun)
  end

  @spec flat_map_children(ctx :: ctx(), fun :: fun()) :: [any()]
  def flat_map_children(ctx, fun) do
    ctx.children |> Map.keys() |> Enum.flat_map(fun)
  end

  @spec forward(
          child_name :: any(),
          msg :: any(),
          ctx :: ctx()
        ) :: [Membrane.Pipeline.Action.notify_child()]
  def forward(child_name, msg, ctx) do
    child = find_child(ctx, pattern: ^child_name)

    if child do
      [notify_child: {child_name, msg}]
    else
      []
    end
  end

  @spec send_if_not_nil(pid :: pid() | nil, msg :: any()) :: any()
  def send_if_not_nil(pid, msg) do
    if pid != nil do
      send(pid, msg)
    end
  end

  @spec generate_turn_credentials(binary(), binary()) :: {binary(), binary()}
  def generate_turn_credentials(name, secret) do
    duration =
      DateTime.utc_now()
      |> DateTime.to_unix()
      |> tap(fn unix_timestamp -> unix_timestamp + 24 * 3600 end)

    username = "#{duration}:#{name}"

    password =
      :crypto.mac(:hmac, :sha, secret, username)
      |> Base.encode64()

    {username, password}
  end
end
