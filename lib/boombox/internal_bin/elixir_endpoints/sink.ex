defmodule Boombox.InternalBin.ElixirEndpoints.Sink do
  @moduledoc false
  alias Membrane.Pad
  require Membrane.Pad

  def handle_init(_ctx, opts) do
    {[], Map.merge(Map.from_struct(opts), %{last_pts: %{}, audio_format: nil})}
  end

  def handle_pad_added(Pad.ref(:input, kind), _ctx, state) do
    {[], %{state | last_pts: Map.put(state.last_pts, kind, 0)}}
  end

  def handle_playing(_ctx, state) do
    send(state.consumer, {:boombox_elixir_sink, self()})
    {[], state}
  end

  def handle_info({:boombox_demand, consumer}, _ctx, %{consumer: consumer} = state) do
    if state.last_pts == %{} do
      {[], state}
    else
      {kind, _pts} =
        Enum.min_by(state.last_pts, fn {_kind, pts} -> pts end)

      {[demand: Pad.ref(:input, kind)], state}
    end
  end

  def handle_info(info, _ctx, state) do
    dbg(info)
    dbg(state)
    raise "aaaaa"
  end

  def handle_stream_format(Pad.ref(:input, :audio), stream_format, _ctx, state) do
    audio_format = %{
      audio_format: stream_format.sample_format,
      audio_rate: stream_format.sample_rate,
      audio_channels: stream_format.channels
    }

    {[], %{state | audio_format: audio_format}}
  end

  def handle_stream_format(_pad, _stream_format, _ctx, state) do
    {[], state}
  end

  def handle_buffer(Pad.ref(:input, :video), buffer, ctx, state) do
    state = %{state | last_pts: %{state.last_pts | video: buffer.pts}}
    %{width: width, height: height} = ctx.pads[Pad.ref(:input, :video)].stream_format

    {:ok, image} =
      Vix.Vips.Image.new_from_binary(buffer.payload, width, height, 3, :VIPS_FORMAT_UCHAR)

    send(state.consumer, %Boombox.Packet{
      payload: image,
      pts: buffer.pts,
      kind: :video
    })

    {[], state}
  end

  def handle_buffer(Pad.ref(:input, :audio), buffer, _ctx, state) do
    state = %{state | last_pts: %{state.last_pts | audio: buffer.pts}}

    packet = %Boombox.Packet{
      payload: buffer.payload,
      pts: buffer.pts,
      kind: :audio,
      format: state.audio_format
    }

    send(state.consumer, {:boombox_packet, self(), packet})

    {[], state}
  end

  def handle_end_of_stream(Pad.ref(:input, kind), _ctx, state) do
    {[], %{state | last_pts: Map.delete(state.last_pts, kind)}}
  end
end
