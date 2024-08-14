defmodule Sink do
  @moduledoc false
  use Membrane.Sink

  def_input_pad :input,
    accepted_format: Membrane.RawVideo,
    flow_control: :manual,
    demand_unit: :buffers

  def_options consumer: [spec: pid()]

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{consumer: opts.consumer}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    send(state.consumer, {:boombox_ex_stream_sink, self()})
    {[], state}
  end

  @impl true
  def handle_info(:boombox_demand, _ctx, state) do
    {[demand: :input], state}
  end

  @impl true
  def handle_buffer(:input, buffer, ctx, state) do
    %{width: width, height: height} = ctx.pads.input.stream_format

    {:ok, image} =
      Vix.Vips.Image.new_from_binary(buffer.payload, width, height, 3, :VIPS_FORMAT_UCHAR)

    send(state.consumer, %Boombox.Packet{
      payload: image,
      pts: buffer.pts,
      kind: :video
    })

    {[], state}
  end
end
