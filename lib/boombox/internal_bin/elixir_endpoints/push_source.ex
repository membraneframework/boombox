defmodule Boombox.InternalBin.ElixirEndpoints.PushSource do
  @moduledoc false
  use Membrane.Source

  alias Boombox.InternalBin.ElixirEndpoints.Source

  def_output_pad :output,
    accepted_format: any_of(Membrane.RawVideo, Membrane.RawAudio),
    availability: :on_request,
    flow_control: :push

  def_options producer: [
                spec: pid()
              ]

  @impl true
  defdelegate handle_init(ctx, opts), to: Source

  @impl true
  defdelegate handle_playing(ctx, state), to: Source

  @impl true
  defdelegate handle_info(info, ctx, state), to: Source
end
