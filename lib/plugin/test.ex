defmodule Plugin.Test do
  require Logger
  use TypeCheck
  alias Stampede, as: S
  require S.Response
  use Plugin

  @spec! process_msg(any(), S.Msg.t()) :: nil | S.Response.t()
  @impl Plugin
  def process_msg(_, msg) do
    case msg.body do
      "!ping" -> S.Response.new(confidence: 10, text: "pong!", why: ["They pinged so I ponged!"])
      "!raise" -> raise SillyError
      _ -> nil
    end
  end
end
defmodule SillyError do
  defexception [message: "Intentional exception raised"]
end

