defmodule Boombox.Bin do
  @moduledoc """
  TODO: write docs
  """
  use Membrane.Bin

  require Membrane.Logger
  require Membrane.Pad, as: Pad
  require Membrane.Transcoder.Audio
  require Membrane.Transcoder.Video
  alias Membrane.Transcoder

  @type input() ::
          (path_or_uri :: String.t())
          | {:mp4, location :: String.t(), transport: :file | :http}
          | {:webrtc, Boombox.webrtc_signaling()}
          | {:whip, uri :: String.t(), token: String.t()}
          | {:rtmp, (uri :: String.t()) | (client_handler :: pid)}
          | {:rtsp, url :: String.t()}
          | {:rtp, Boombox.in_rtp_opts()}

  @type output ::
          (path_or_uri :: String.t())
          | {path_or_uri :: String.t(), [Boombox.force_transcoding()]}
          | {:mp4, location :: String.t()}
          | {:mp4, location :: String.t(), [Boombox.force_transcoding()]}
          | {:webrtc, Boombox.webrtc_signaling()}
          | {:webrtc, Boombox.webrtc_signaling(), [Boombox.force_transcoding()]}
          | {:whip, uri :: String.t(), [{:token, String.t()} | {bandit_option :: atom(), term()}]}
          | {:hls, location :: String.t()}
          | {:hls, location :: String.t(), [Boombox.force_transcoding()]}
          | {:rtp, Boombox.out_rtp_opts()}

  def_input_pad :audio_input,
    accepted_format: format when Transcoder.Audio.is_audio_format(format),
    availability: :on_request,
    max_instances: 1

  def_input_pad :video_input,
    accepted_format: format when Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 1

  def_options input: [
                spec: input() | :membrane_pad,
                default: :membrane_pad
              ],
              output: [
                spec: output()
              ]

  @impl true
  def handle_init(_ctx, opts) do
    :ok = validate_option!(:input, opts.input)
    :ok = validate_option!(:output, opts.output)

    spec =
      child(:boombox, %Boombox.InternalBin{
        input: opts.input,
        output: opts.output
      })

    {[spec: spec], %{}}
  end

  @impl true
  def handle_pad_added(pad_ref, _ctx, state) do
    spec =
      bin_input(pad_ref)
      |> via_in(pad_ref)
      |> get_child(:boombox)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(:processing_finished, :boombox, _ctx, state) do
    {[notify_parent: :processing_finished], state}
  end

  defp validate_option!(direction, option) do
    if is_tuple(option) and elem(option, 0) == :stream do
      raise """
      #{inspect(direction)} option is set to #{inspect(option)}, but #{inspect(__MODULE__)} \
      doesn't support Elixir Stream as endpoint.
      """
    end

    :ok
  end
end
