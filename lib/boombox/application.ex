defmodule Boombox.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children =
      case System.get_env("RELEASE_NAME") do
        "server" ->
          node_to_ping = System.get_env("NODE_TO_PING")

          if node_to_ping != nil do
            Node.ping(String.to_atom(node_to_ping))
          end

          [Boombox.Server]

        _not_server ->
          []
      end

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
