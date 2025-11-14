defmodule Boombox.InternalBin.ElixirEndpoints.PullSource do
  @moduledoc false
  use Membrane.Source

  alias Boombox.InternalBin.ElixirEndpoints.Source

  def_output_pad :output,
    accepted_format: any_of(Membrane.RawVideo, Membrane.RawAudio),
    availability: :on_request,
    flow_control: :manual

  def_options producer: [
                spec: pid()
              ]

  @impl true
  defdelegate handle_init(ctx, opts), to: Source

  @impl true
  defdelegate handle_playing(ctx, state), to: Source

  @impl true
  defdelegate handle_demand(pad, size, unit, ctx, state), to: Source

  @impl true
  defdelegate handle_info(info, ctx, state), to: Source
end
