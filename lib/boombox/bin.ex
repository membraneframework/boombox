defmodule Boombox.Bin do
  @moduledoc """
  Boombox is a tool for audio and video streaming.

  See `run/1` for details and [examples.livemd](examples.livemd) for examples.
  """

  use Membrane.Bin

  require Membrane.Pad, as: Pad
  require Membrane.Transcoder.{Audio, Video}

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

  def_input_pad :input,
    accepted_format: format when Transcoder.Audio.is_audio_format(format),
    availability: :on_request,
    max_instances: 1

  def_input_pad :video_input,
    accepted_format: format when Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 1

  def_output_pad :audio_output,
    accepted_format: format when Transcoder.Audio.is_audio_format(format),
    availability: :on_request,
    max_instances: 1

  def_output_pad :video_output,
    accepted_format: format when Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 1

  def_options input: [
                spec: input() | nil,
                default: nil
              ],
              output: [
                spec: output() | nil,
                default: nil
              ]

  @impl true
  def handle_init(_ctx, opts) do
    :ok = validate_opts!(opts)

    spec =
      child(:boombox, %Boombox.InternalBin{
        input: opts.input || :membrane_pad,
        output: opts.output || :membrane_pad
      })

    {[spec: spec], Map.from_struct(opts)}
  end

  @impl true
  def handle_pad_added(Pad.ref(pad_name, _id) = pad_ref, _ctx, state) do
    spec =
      cond do
        pad_name in [:audio_input, :video_input] and state.input == nil ->
          bin_input(pad_ref)
          |> via_in(pad_ref)
          |> get_child(:boombox)

        pad_name in [:audio_output, :video_output] and state.output == nil ->
          get_child(:boombox)
          |> via_out(pad_ref)
          |> bin_output(pad_ref)
      end

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(:processing_finished, :boombox, _ctx, state) do
    {[notify_parent: :processing_finished], state}
  end

  defp validate_opts!(opts) do
    nil_opts_number =
      [opts.input, opts.output]
      |> Enum.count(& &1 == nil)

    if nil_opts_number != 1 do
      raise """
      Always excatly one of options of #{inspect(__MODULE__)} has to be nil, but :input field is \
      set to #{inspect(opts.input)} and :output is set to #{inspect(opts.output)} at the same time.
      """
    end

    [:input, :output]
    |> Enum.each(fn direction ->
      option = opts[direction]

      if is_tuple(option) and elem(option, 0) == :stream do
        raise """
        #{inspect(direction)} option is set to #{inspect(option)}, but #{inspect(__MODULE__)} \
        doesn't support Elixir Stream as an endpoint.
        """
      end
    end)
  end
end
