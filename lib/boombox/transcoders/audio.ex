defmodule Boombox.Transcoders.Audio do
  @moduledoc false

  use Membrane.Bin

  alias Membrane.Funnel
  alias Membrane.Transcoders.DataReceiver

  def_input_pad :input,
    accepted_format: any_of(Membrane.AAC, Membrane.Opus)

  def_output_pad :output,
    accepted_format: any_of(Membrane.AAC, Membrane.Opus)

  @type stream_format :: Membrane.AAC.t() | Membrane.Opus.t()

  def_options output_stream_format: [
                spec: stream_format() | (stream_format() -> stream_format()),
                description: """
                Specyfies format of the output stream.

                Can be a struct, that will be returned as output stream format or a function that receives \
                input stream format and returns output stream format.

                Input stream will be transformed, so it will match the output stream format.

                If transformation won't be possible or supported, an error will be raised.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    spec = [
      bin_input() |> child(:data_receiver, DataReceiver),
      child(:output_forward_filter, Funnel) |> bin_output()
    ]

    {[spec: spec], Map.from_struct(opts)}
  end

  @impl true
  def handle_child_notification(
        {:input_stream_format, stream_format},
        :data_receiver,
        _ctx,
        state
      ) do
    state = resolve_output_stream_format(stream_format, state)
    spec = generate_transcoding_spec(stream_format, state.output_stream_format)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(_notification, _element, _ctx, state) do
    {[], state}
  end

  defp resolve_output_stream_format(input_stream_format, state) do
    case state.output_stream_format do
      function when is_function(function) ->
        %{state | output_stream_format: function.(input_stream_format)}

      struct when is_struct(struct) ->
        state
    end
  end

  defp generate_transcoding_spec(%module{} = input_format, %module{} = output_format) do
    if input_format != output_format do
      raise "Cannot transcode #{inspect(input_format)} to #{input_format(output_format)} yet"
    end

    get_child(:data_receiver) |> get_child(:output_forward_filter)
  end

  defp generate_


end
