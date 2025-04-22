defmodule Boombox.Application do
  use Application

  @impl true
  def start(_type, _args) do
    pyrlang_node = System.fetch_env!("PYRLANG_NODE")

    Node.ping(String.to_atom(pyrlang_node))
    Supervisor.start_link([Boombox.Gateway], strategy: :one_for_one)
  end
end
