defmodule Source do
  @moduledoc false
  use Membrane.Source

  def_output_pad :output,
    accepted_format: Membrane.RawVideo,
    flow_control: :manual,
    demand_unit: :buffers

  def_options producer: []

  @impl true
  def handle_init(_ctx, opts) do
    state = %{producer: opts.producer, demand_atomic: :atomics.new(1, []), dims: nil}
    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    send(state.producer, {:boombox_ex_stream_source, self(), state.demand_atomic})
    {[], state}
  end

  @impl true
  def handle_demand(:output, _size, _unit, _ctx, %{producer: nil} = state) do
    {[], state}
  end

  @impl true
  def handle_demand(:output, _size, _unit, ctx, state) do
    new_demand = ctx.incoming_demand
    demand = :atomics.add_get(state.demand_atomic, 1, new_demand)

    if demand < new_demand do
      send(state.producer, :boombox_demand)
    end

    {[], state}
  end

  @impl true
  def handle_info(%Boombox.Packet{} = packet, _ctx, state) do
    image = packet.payload |> Image.flatten!() |> Image.to_colorspace!(:srgb)
    dims = %{width: Image.width(image), height: Image.height(image)}
    {:ok, payload} = Vix.Vips.Image.write_to_binary(image)
    buffer = %Membrane.Buffer{payload: payload, pts: packet.pts}

    if dims == state.dims do
      {[buffer: {:output, buffer}], state}
    else
      stream_format = %Membrane.RawVideo{
        width: dims.width,
        height: dims.height,
        pixel_format: :RGB,
        aligned: true,
        framerate: nil
      }

      {[stream_format: {:output, stream_format}, buffer: {:output, buffer}],
       %{state | dims: dims}}
    end
  end

  @impl true
  def handle_info(:boombox_eos, _ctx, state) do
    {[end_of_stream: :output], state}
  end
end
