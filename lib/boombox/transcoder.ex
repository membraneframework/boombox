defmodule Boombox.Transcoder do
  @moduledoc false
  use Membrane.Bin

  require __MODULE__.Audio
  require __MODULE__.Video

  alias __MODULE__.{Audio, ForwardingFilter, Video}
  alias Membrane.{AAC, Funnel, H264, H265, Opus, RawAudio, RawVideo, RemoteStream, VP8}

  @type stream_format ::
          H264.t()
          | H265.t()
          | VP8.t()
          | RawVideo.t()
          | AAC.t()
          | Opus.t()
          | RemoteStream.t()
          | RawAudio.t()

  @type stream_format_module :: H264 | H265 | VP8 | RawVideo | AAC | Opus | RawAudio

  @type stream_format_resolver :: (stream_format() -> stream_format() | stream_format_module())

  def_input_pad :input,
    accepted_format: format when Audio.is_audio_format(format) or Video.is_video_format(format)

  def_output_pad :output,
    accepted_format: format when Audio.is_audio_format(format) or Video.is_video_format(format)

  def_options output_stream_format: [
                spec: stream_format() | stream_format_module() | stream_format_resolver()
              ]

  @impl true
  def handle_init(_ctx, opts) do
    spec = [
      bin_input()
      |> child(:forwarding_filter, ForwardingFilter),
      child(:output_funnel, Funnel)
      |> bin_output()
    ]

    state =
      opts
      |> Map.from_struct()
      |> Map.put(:input_stream_format, nil)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification({:stream_format, format}, :forwarding_filter, _ctx, state) do
    state =
      %{state | input_stream_format: format}
      |> resolve_output_stream_format()

    spec =
      get_child(:forwarding_filter)
      |> plug_transcoding(format, state.output_stream_format)
      |> get_child(:output_funnel)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(_notification, _element, _ctx, state) do
    {[], state}
  end

  defp resolve_output_stream_format(state) do
    case state.output_stream_format do
      format when is_struct(format) ->
        state

      module when is_atom(module) ->
        %{state | output_stream_format: struct(module)}

      resolver when is_function(resolver) ->
        %{state | output_stream_format: resolver.(state.input_stream_format)}
        |> resolve_output_stream_format()
    end
  end

  defp plug_transcoding(builder, input_format, output_format)
       when Audio.is_audio_format(input_format) do
    builder |> Audio.plug_audio_transcoding(input_format, output_format)
  end

  defp plug_transcoding(builder, input_format, output_format)
       when Video.is_video_format(input_format) do
    builder |> Video.plug_video_transcoding(input_format, output_format)
  end
end
