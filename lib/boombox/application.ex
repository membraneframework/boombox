defmodule Boombox.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Boombox.Gateway], [])
  end
end
