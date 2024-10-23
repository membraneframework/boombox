defmodule Utils.SilenceFiller do
  @moduledoc false

  use Membrane.Filter

  def_input_pad(:input, accepted_format: Membrane.RawAudio)
  def_output_pad(:output, accepted_format: Membrane.RawAudio)

  @time Membrane.Time.milliseconds(20)

  @impl true
  def handle_stream_format(:input, _format, ctx, state) when ctx.old_stream_format != nil do
    {[], state}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, _opts) do
    {[stream_format: {:output, format}, start_timer: {:timer, @time}], %{overtime: 0, pts: 0}}
  end

  @impl true
  def handle_tick(:timer, ctx, state) do
    %{overtime: overtime, pts: pts} = state
    time = @time - overtime

    if time > 0 do
      silence = Membrane.RawAudio.silence(ctx.pads.input.stream_format, time)
      buffer = %Membrane.Buffer{payload: silence, pts: state.pts}

      real_time =
        Membrane.RawAudio.bytes_to_time(byte_size(buffer.payload), ctx.pads.input.stream_format)

      {[buffer: {:output, buffer}], %{state | pts: pts + real_time, overtime: 0}}
    else
      {[], %{state | overtime: overtime - @time}}
    end
  end

  @impl true
  def handle_buffer(:input, buffer, ctx, state) do
    duration =
      Membrane.RawAudio.bytes_to_time(byte_size(buffer.payload), ctx.pads.input.stream_format)

    actions = [buffer: {:output, %{buffer | pts: state.pts}}]
    state = %{state | overtime: state.overtime + duration, pts: state.pts + duration}
    {actions, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {[end_of_stream: :output, stop_timer: :timer], state}
  end
end
