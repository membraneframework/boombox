defmodule Boombox.InternalBin.ElixirEndpoints.Source do
  @moduledoc false
  alias Membrane.Pad
  require Membrane.Pad

  def handle_init(_ctx, opts) do
    state = %{
      producer: opts.producer,
      audio_format: nil,
      video_dims: nil
    }

    {[], state}
  end

  def handle_playing(_ctx, state) do
    send(state.producer, {:boombox_elixir_source, self()})
    {[], state}
  end

  def handle_demand(Pad.ref(:output, _id), _size, _unit, ctx, state) do
    demands = Enum.map(ctx.pads, fn {_pad, %{demand: demand}} -> demand end)

    if Enum.all?(demands, &(&1 > 0)) do
      send(state.producer, {:boombox_demand, self(), Enum.sum(demands)})
    end

    {[], state}
  end

  def handle_info(
        {:boombox_packet, producer, %Boombox.Packet{kind: :video} = packet},
        _ctx,
        %{producer: producer} = state
      ) do
    image = packet.payload |> Image.flatten!() |> Image.to_colorspace!(:srgb)
    video_dims = %{width: Image.width(image), height: Image.height(image)}
    {:ok, payload} = Vix.Vips.Image.write_to_binary(image)
    buffer = %Membrane.Buffer{payload: payload, pts: packet.pts}

    if video_dims == state.video_dims do
      {[buffer: {Pad.ref(:output, :video), buffer}], state}
    else
      stream_format = %Membrane.RawVideo{
        width: video_dims.width,
        height: video_dims.height,
        pixel_format: :RGB,
        aligned: true,
        framerate: nil
      }

      {[
         stream_format: {Pad.ref(:output, :video), stream_format},
         buffer: {Pad.ref(:output, :video), buffer}
       ], %{state | video_dims: video_dims}}
    end
  end

  def handle_info(
        {:boombox_packet, producer, %Boombox.Packet{kind: :audio} = packet},
        _ctx,
        %{producer: producer} = state
      ) do
    %Boombox.Packet{payload: payload, format: format} = packet
    buffer = %Membrane.Buffer{payload: payload, pts: packet.pts}

    case format do
      empty_format when empty_format == %{} and state.audio_format == nil ->
        raise "No audio stream format provided"

      empty_format when empty_format == %{} ->
        {[buffer: {Pad.ref(:output, :audio), buffer}], state}

      unchanged_format when unchanged_format == state.audio_format ->
        {[buffer: {Pad.ref(:output, :audio), buffer}], state}

      new_format ->
        stream_format = %Membrane.RawAudio{
          sample_format: new_format.audio_format,
          sample_rate: new_format.audio_rate,
          channels: new_format.audio_channels
        }

        {[
           stream_format: {Pad.ref(:output, :audio), stream_format},
           buffer: {Pad.ref(:output, :audio), buffer}
         ], %{state | audio_format: format}}
    end
  end

  def handle_info({:boombox_eos, producer}, ctx, %{producer: producer} = state) do
    actions = Enum.map(ctx.pads, fn {ref, _data} -> {:end_of_stream, ref} end)
    {actions, state}
  end
end
