defmodule Boombox.Pipeline do
  @moduledoc false
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      child(:boombox, %Boombox.Bin{
        input: opts.input,
        output: opts.output
      })

    {[spec: spec], %{}}
  end

  @impl true
  def handle_child_notification(:processing_finished, :bin, _ctx, state) do
    {[terminate: :normal], state}
  end
end
