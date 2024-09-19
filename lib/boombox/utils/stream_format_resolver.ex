defmodule Boombox.Utils.StreamFormatResolver do
  use Membrane.Filter

  def_input_pad :input, accepted_format: _any
  def_output_pad :output, accepted_format: _any

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    actions = [
      notify_parent: {:stream_format, stream_format},
      stream_format: {:output, stream_format}
    ]

    {actions, state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    {[buffer: {:output, buffer}], state}
  end
end
