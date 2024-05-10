defmodule Boombox do
  def run(opts) do
    {:ok, supervisor, _pipeline} = Membrane.Pipeline.start_link(Boombox.Pipeline, opts)
    Process.monitor(supervisor)

    exit_reason =
      receive do
        {:DOWN, _monitor, :process, ^supervisor, reason} -> reason
      end

    if exit_reason == :normal do
      :ok
    else
      raise "Boombox pipeline crashed with reason: #{inspect(exit_reason)}"
    end
  end
end
