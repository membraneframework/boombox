defmodule Boombox.Pipeline do
  @moduledoc false
  use Membrane.Pipeline
  @elixir_endpoints [:stream, :message, :writer, :reader]

  @type opts_map :: %{
          input: Boombox.input() | Boombox.elixir_input(),
          output: Boombox.output() | Boombox.elixir_output()
        }
  @type procs :: %{pipeline: pid(), supervisor: pid()}

  @spec start_pipeline(opts_map()) :: procs()
  def start_pipeline(opts) do
    opts =
      opts
      |> Map.update!(:input, &resolve_stream_endpoint(&1, self()))
      |> Map.update!(:output, &resolve_stream_endpoint(&1, self()))
      |> Map.put(:parent, self())

    {:ok, supervisor, pipeline} =
      Membrane.Pipeline.start_link(Boombox.Pipeline, opts)

    Process.monitor(supervisor)
    %{supervisor: supervisor, pipeline: pipeline}
  end

  @spec terminate_pipeline(procs()) :: :ok
  def terminate_pipeline(procs) do
    Membrane.Pipeline.terminate(procs.pipeline)
    await_pipeline(procs)
  end

  @spec await_pipeline(procs()) :: :ok
  def await_pipeline(%{supervisor: supervisor}) do
    receive do
      {:DOWN, _monitor, :process, ^supervisor, _reason} -> :ok
    end
  end

  @spec await_source_ready() :: pid()
  def await_source_ready() do
    receive do
      {:boombox_elixir_source, source} -> source
    end
  end

  @spec await_sink_ready() :: pid()
  def await_sink_ready() do
    receive do
      {:boombox_elixir_sink, sink} -> sink
    end
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
  def handle_playing(_ctx, state) do
    send(state.parent, {:pipeline_playing, self()})
    {[], state}
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

  defp resolve_stream_endpoint({endpoint_type, opts}, parent)
       when endpoint_type in @elixir_endpoints,
       do: {endpoint_type, parent, opts}

  defp resolve_stream_endpoint(endpoint, _parent), do: endpoint
end
