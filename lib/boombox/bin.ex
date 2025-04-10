defmodule Boombox.Bin do
  @moduledoc """
  todo:)
  """

  use Membrane.Bin

  require Membrane.Pad, as: Pad
  require Membrane.Transcoder.{Audio, Video}

  alias Membrane.Transcoder

  @type webrtc_video_track_option() ::
          {:video_codec, :h264 | :vp8 | [:h264 | :vp8]}
          | {:video_transcoding_policy, :always | :if_needed | :never}

  @type input() ::
          (path_or_uri :: String.t())
          | {:mp4, location :: String.t(), transport: :file | :http}
          | {:webrtc, Boombox.webrtc_signaling()}
          | {:webrtc, Boombox.webrtc_signaling(), webrtc_video_track_options()}
          | {:whip, uri :: String.t(), [webrtc_video_track_option(), token: String.t()]}
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
    accepted_format:
      format
      when Transcoder.Audio.is_audio_format(format) or Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 2,
    options: [kind: [spec: :video | :audio]]

  def_output_pad :output,
    accepted_format:
      format
      when Transcoder.Audio.is_audio_format(format) or Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 2,
    options: [
      kind: [spec: :video | :audio],
      webrtc_video_codec: [
        spec: :vp8 | :h264 | [:vp8 | :h264],
        default: :vp8
      ],
      transcoding_policy: [
        spec: :always | :never | :if_needed | (stream_format() -> :always | :if_needed | :never),
        default: :if_needed
      ]
    ]

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
  def handle_pad_added(Pad.ref(direction, _id) = pad_ref, ctx, state) do
    :ok = validate_pads!(ctx.pads)

    spec =
      case direction do
        :input ->
          bin_input(pad_ref)
          |> via_in(:input, options: [kind: ctx.pad_options.kind])
          |> get_child(:boombox)

        :output ->
          get_child(:boombox)
          |> via_out(:output, options: [kind: ctx.pad_options.kind])
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
      |> Enum.count(&(&1 == nil))

    if nil_opts_number != 1 do
      raise """
      Always excatly one of options of #{inspect(__MODULE__)} has to be nil, but :input field is \
      set to #{inspect(opts.input)} and :output is set to #{inspect(opts.output)} at the same time.
      """
    end

    [:input, :output]
    |> Enum.each(fn direction ->
      option = opts |> Map.get(direction)

      if is_tuple(option) and elem(option, 0) == :stream do
        raise """
        #{inspect(direction)} option is set to #{inspect(option)}, but #{inspect(__MODULE__)} \
        doesn't support Elixir Stream as an endpoint.
        """
      end
    end)
  end

  defp validate_pads!(pads) do
    pads
    |> Enum.group_by(fn {Pad.ref(name, _id), %{options: %{kind: kind}}} -> {name, kind} end)
    |> Enum.find(fn {_key, pads} -> length(pads) > 1 end)
    |> case do
      nil ->
        :ok

      {_key, pads} ->
        raise """
        #{inspect(__MODULE__)} supports only one input and one output pad of each kind. \
        Found multiple pads of the same kind: #{Map.keys(pads) |> inspect()}
        """
    end
  end
end
