defmodule Boombox.InternalBin.ElixirEndpoints.PushSink do
  @moduledoc false
  use Membrane.Sink

  alias Boombox.InternalBin.ElixirEndpoints.Sink

  def_input_pad :input,
    accepted_format: any_of(Membrane.RawAudio, Membrane.RawVideo),
    availability: :on_request,
    flow_control: :auto

  def_options consumer: [spec: pid()]

  @impl true
  defdelegate handle_init(ctx, opts), to: Sink

  @impl true
  defdelegate handle_pad_added(pad, ctx, state), to: Sink

  @impl true
  defdelegate handle_playing(ctx, state), to: Sink

  @impl true
  defdelegate handle_stream_format(pad, stream_format, ctx, state), to: Sink

  @impl true
  defdelegate handle_end_of_stream(pad, ctx, state), to: Sink
end
