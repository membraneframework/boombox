defmodule Boombox.InternalBin.ElixirEndpoints.FrameDropper do
  @moduledoc false
  # Passes on at most `framerate` raw video frames per second of stream
  # time and drops the rest, so frames the consumer will not use skip the
  # conversion to the output format.

  use Membrane.Filter

  alias Membrane.Buffer

  def_input_pad :input, accepted_format: Membrane.RawVideo
  def_output_pad :output, accepted_format: Membrane.RawVideo

  def_options framerate: [
                spec: number(),
                description: "The most frames per second to pass on."
              ]

  @impl true
  def handle_init(_ctx, %__MODULE__{framerate: framerate}) do
    {[], %{interval: round(Membrane.Time.seconds(1) / framerate), next: nil}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case Buffer.get_dts_or_pts(buffer) do
      nil ->
        {[buffer: {:output, buffer}], state}

      ts when state.next == nil or ts >= state.next ->
        {[buffer: {:output, buffer}], %{state | next: next_due(state, ts)}}

      _early ->
        {[], state}
    end
  end

  # Due times advance by one interval from the last one, so a source whose
  # frames do not divide the interval evenly still averages `framerate`; a
  # gap in the stream restarts the schedule from the frame after it.
  defp next_due(%{next: nil, interval: interval}, ts), do: ts + interval

  defp next_due(%{next: next, interval: interval}, ts) when ts - next < interval,
    do: next + interval

  defp next_due(%{interval: interval}, ts), do: ts + interval
end
