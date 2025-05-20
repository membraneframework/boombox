defmodule Boombox.Pipeline do
  @moduledoc false
  use Membrane.Pipeline

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

  def handle_child_notification(:processing_finished, :boombox, _ctx, state) do
    {[terminate: :normal], state}
  end

  def handle_child_notification(_notification, _element, _context, state) do
    {[], state}
  end
end
