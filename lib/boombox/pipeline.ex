defmodule Boombox.Pipeline do
  @moduledoc false
  use Membrane.Pipeline
  @elixir_endpoints [:stream, :message, :writer, :reader]

  @type opts_map :: %{
          input: Boombox.input() | Boombox.elixir_input(),
          output: Boombox.output() | Boombox.elixir_output()
        }
  @type procs :: %{pipeline: pid(), supervisor: pid()}

  @spec start(opts_map()) :: procs()
  def start(opts) do
    opts =
      opts
      |> Map.update!(:input, &resolve_elixir_endpoint(&1, self()))
      |> Map.update!(:output, &resolve_elixir_endpoint(&1, self()))
      |> Map.put(:parent, self())

    {:ok, supervisor, pipeline} =
      Membrane.Pipeline.start_link(Boombox.Pipeline, opts)

    Process.monitor(supervisor)
    %{supervisor: supervisor, pipeline: pipeline}
  end

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      child(:boombox, %Boombox.InternalBin{
        input: opts.input,
        output: opts.output
      })

    {[spec: spec], %{parent: opts.parent}}
  end

  @impl true
  def handle_child_notification(:external_resource_ready, _element, _context, state) do
    send(state.parent, :external_resource_ready)
    {[], state}
  end

  @impl true
  def handle_child_notification(:processing_finished, :boombox, _ctx, state) do
    {[terminate: :normal], state}
  end

  defp resolve_elixir_endpoint({endpoint_type, opts}, parent)
       when endpoint_type in @elixir_endpoints,
       do: {endpoint_type, parent, opts}

  defp resolve_elixir_endpoint(endpoint, _parent), do: endpoint
end
