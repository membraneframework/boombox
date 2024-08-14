defmodule Source do
  @moduledoc false
  use Membrane.Source

  def_output_pad :output,
    accepted_format: any_of(Membrane.RawVideo, Membrane.RawAudio),
    availability: :on_request,
    flow_control: :manual,
    demand_unit: :buffers

  def_options producer: []

  @impl true
  def handle_init(_ctx, opts) do
    state = %{producer: opts.producer, dims: nil}
    {[], state}
  end

  @impl true
  def handle_playing(ctx, state) do
    send(state.producer, {:boombox_ex_stream_source, self()})

    if Map.has_key?(ctx.pads, Pad.ref(:output, :audio)) do
      format = %Membrane.RawAudio{sample_format: :s16le, sample_rate: 44100, channels: 2}
      {[stream_format: {Pad.ref(:output, :audio), format}], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_demand(Pad.ref(:output, _id), _size, _unit, ctx, state) do
    audio_demand = ctx.pads[Pad.ref(:output, :audio)].demand
    video_demand = ctx.pads[Pad.ref(:output, :video)].demand

    if audio_demand > 0 and video_demand > 0 do
      send(state.producer, {:boombox_demand, audio_demand + video_demand})
    end

    {[], state}
  end

  @impl true
  def handle_info(%Boombox.Packet{kind: :video} = packet, _ctx, state) do
    image = packet.payload |> Image.flatten!() |> Image.to_colorspace!(:srgb)
    dims = %{width: Image.width(image), height: Image.height(image)}
    {:ok, payload} = Vix.Vips.Image.write_to_binary(image)
    buffer = %Membrane.Buffer{payload: payload, pts: packet.pts}

    if dims == state.dims do
      {[buffer: {Pad.ref(:output, :video), buffer}], state}
    else
      stream_format = %Membrane.RawVideo{
        width: dims.width,
        height: dims.height,
        pixel_format: :RGB,
        aligned: true,
        framerate: nil
      }

      {[
         stream_format: {Pad.ref(:output, :video), stream_format},
         buffer: {Pad.ref(:output, :video), buffer}
       ], %{state | dims: dims}}
    end
  end

  @impl true
  def handle_info(%Boombox.Packet{kind: :audio} = packet, _ctx, state) do
    buffer = %Membrane.Buffer{payload: packet.payload, pts: packet.pts}
    {[buffer: {Pad.ref(:output, :audio), buffer}], state}
  end

  @impl true
  def handle_info(:boombox_eos, _ctx, state) do
    {[end_of_stream: Pad.ref(:output, :audio), end_of_stream: Pad.ref(:output, :video)], state}
  end
end
