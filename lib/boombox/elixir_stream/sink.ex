defmodule Sink do
  @moduledoc false
  use Membrane.Sink

  def_input_pad :input,
    accepted_format: any_of(Membrane.RawAudio, Membrane.RawVideo),
    availability: :on_request,
    flow_control: :manual,
    demand_unit: :buffers

  def_options consumer: [spec: pid()]

  @impl true
  def handle_init(_ctx, opts) do
    {[], Map.merge(Map.from_struct(opts), %{last_pts: %{}, audio_format: nil})}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, kind), _ctx, state) do
    {[], %{state | last_pts: Map.put(state.last_pts, kind, 0)}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    send(state.consumer, {:boombox_ex_stream_sink, self()})
    {[], state}
  end

  @impl true
  def handle_info(:boombox_demand, _ctx, state) do
    {kind, _pts} = Enum.min_by(state.last_pts, fn {_kind, pts} -> pts end)
    {[demand: Pad.ref(:input, kind)], state}
  end

  @impl true
  def handle_stream_format(Pad.ref(:input, :audio), stream_format, _ctx, state) do
    audio_format = %{
      audio_format: stream_format.sample_format,
      audio_rate: stream_format.sample_rate,
      audio_channels: stream_format.channels
    }

    {[], %{state | audio_format: audio_format}}
  end

  @impl true
  def handle_stream_format(_pad, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
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

  @impl true
  def handle_buffer(Pad.ref(:input, :audio), buffer, _ctx, state) do
    state = %{state | last_pts: %{state.last_pts | audio: buffer.pts}}

    send(state.consumer, %Boombox.Packet{
      payload: buffer.payload,
      pts: buffer.pts,
      kind: :audio,
      format: state.audio_format
    })

    {[], state}
  end
end
