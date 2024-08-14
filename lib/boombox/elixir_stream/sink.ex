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
    {[], %{consumer: opts.consumer, last_audio_pts: 0, last_video_pts: 0}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    send(state.consumer, {:boombox_ex_stream_sink, self()})
    {[], state}
  end

  @impl true
  def handle_info(:boombox_demand, _ctx, state) do
    if state.last_audio_pts < state.last_video_pts do
      {[demand: Pad.ref(:input, :audio)], state}
    else
      {[demand: Pad.ref(:input, :video)], state}
    end
  end

  @impl true
  def handle_buffer(Pad.ref(:input, :video), buffer, ctx, state) do
    state = %{state | last_video_pts: buffer.pts}
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
    state = %{state | last_audio_pts: buffer.pts}

    send(state.consumer, %Boombox.Packet{
      payload: buffer.payload,
      pts: buffer.pts,
      kind: :audio
    })

    {[], state}
  end
end
