defmodule Boombox.Bin do
  @moduledoc """
  Boombox.Bin is a Membrane Bin for audio and video streaming.
  It can be used as a Sink or Source in your Membrane Pipeline.

  If you use it as a Membrane Source, you have to specify `:input` option.
  If you use it as a Membrane Sink, you have to specify `:output` option.
  Boombox.Bin cannot be used as both Source and Sink at the same time.
  """

  use Membrane.Bin

  require Membrane.Pad, as: Pad
  require Membrane.Transcoder.{Audio, Video}

  alias Membrane.{AAC, H264, Opus, RawAudio, RawVideo, Transcoder, VP8, VP9}

  @video_codecs [H264, VP8, VP9, RawVideo]
  @audio_codecs [AAC, Opus, RawAudio]

  @codecs %{
    audio: @audio_codecs,
    video: @video_codecs
  }

  @typedoc """
  Value passed via `:input` option.

  Specifies the input endpoint of `#{inspect(__MODULE__)}`.

  Similar to `t:Boombox.input/0`, but without `:stream` option.
  """
  @type input() ::
          (path_or_uri :: String.t())
          | {:mp4, location :: String.t(), transport: :file | :http}
          | {:webrtc, Boombox.webrtc_signaling()}
          | {:whip, uri :: String.t(), token: String.t()}
          | {:rtmp, (uri :: String.t()) | (client_handler :: pid)}
          | {:rtsp, url :: String.t()}
          | {:rtp, Boombox.in_rtp_opts()}

  @typedoc """
  Value passed via `:output` option.

  Specifies the output endpoint of `#{inspect(__MODULE__)}`.

  Similar to `t:Boombox.output/0`, but without `:stream` option.
  """
  @type output ::
          (path_or_uri :: String.t())
          | {path_or_uri :: String.t(), [Boombox.transcoding_policy()]}
          | {:mp4, location :: String.t()}
          | {:mp4, location :: String.t(), [Boombox.transcoding_policy()]}
          | {:webrtc, Boombox.webrtc_signaling()}
          | {:webrtc, Boombox.webrtc_signaling(), [Boombox.transcoding_policy()]}
          | {:whip, uri :: String.t(), [{:token, String.t()} | {bandit_option :: atom(), term()}]}
          | {:hls, location :: String.t()}
          | {:hls, location :: String.t(), [Boombox.transcoding_policy()]}
          | {:rtp, Boombox.out_rtp_opts()}

  def_input_pad :input,
    accepted_format:
      format
      when Transcoder.Audio.is_audio_format(format) or Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 2,
    options: [
      kind: [
        spec: :video | :audio,
        description: """
        Specifies, if the input pad is for audio or video.

        There might be up to one pad of each kind at the time.
        """
      ]
    ]

  def_output_pad :output,
    accepted_format:
      format
      when Transcoder.Audio.is_audio_format(format) or Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 2,
    options: [
      kind: [
        spec: :video | :audio,
        description: """
        Specifies, if the output pad is for audio or video.

        There might be up to one pad of each kind at the time.
        """
      ],
      codec: [
        spec:
          H264
          | VP8
          | VP9
          | AAC
          | Opus
          | RawVideo
          | RawAudio
          | [H264 | VP8 | VP9 | AAC | Opus | RawVideo | RawAudio]
          | nil,
        default: nil,
        description: """
        Specifies the codec of the stream flowing through the pad.

        Can be either a single codec or a list of codecs.

        If a list is provided
          * and the stream matches one of the codecs, the matching codec will be used,
          * and the stream doesn't match any of the codecs, it will be transcoded to
            the first codec in the list.

        If the codec is not specified, it will be resolved to:
          * `Membrane.H264` for video,
          * `Membrane.AAC` for audio, if the input is not WebRTC,
          * `Membrane.Opus` for audio, if the input is WebRTC.
        """
      ],
      transcoding_policy: [
        spec: :always | :if_needed | :never,
        default: :if_needed,
        description: """
        Specifies the transcoding policy for the stream flowing through the pad.

        Can be either `:always`, `:if_needed`, or `:never`.

        If set to `:always`, the media stream will be decoded and/or encoded, even if the
        format of the stream arriving at the #{inspect(__MODULE__)} endpoint matches the \
        output pad codec.

        If set to `:if_needed`, the media stream will be transcoded only if the format of
        the stream arriving at the #{inspect(__MODULE__)} endpoint doesn't match the output
        pad codec.
        This is the default behavior.

        If set to `:never`, the input media stream won't be decoded or encoded.
        Changing alignment, encapsulation, or stream structure is still possible. This option
        is helpful when you want to ensure that #{inspect(__MODULE__)} will not use too many
        resources, e.g., CPU or memory.

        If the stream arriving at the #{inspect(__MODULE__)} endpoint doesn't match the output
        pad codec, an error will be raised.
        """
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
  def handle_pad_added(Pad.ref(name, _id) = pad_ref, ctx, state) do
    :ok = validate_pads!(ctx.pads)

    spec =
      case name do
        :input ->
          bin_input(pad_ref)
          |> via_in(:input, options: [kind: ctx.pad_options.kind])
          |> get_child(:boombox)

        :output ->
          get_child(:boombox)
          |> via_out(:output, options: Map.to_list(ctx.pad_options))
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
    |> Enum.find(fn {Pad.ref(name, _id), %{options: options}} ->
      name == :output and
        (Bunch.listify(options.codec) -- @codecs[options.kind]) -- [nil] != []
    end)
    |> case do
      nil ->
        :ok

      {pad_ref, %{options: options}} ->
        raise """
        Pad #{inspect(pad_ref)} is of kind #{inspect(options.kind)} and it has :codec option set \
        to  #{inspect(options.codec)}. \
        Supported codecs for #{inspect(options.kind)} kind are: #{inspect(@codecs[options.kind])}.
        """
    end

    pads
    |> Enum.group_by(fn {Pad.ref(name, _id), %{options: %{kind: kind}}} ->
      {name, kind}
    end)
    |> Enum.find(fn {_key, pads} -> length(pads) > 1 end)
    |> case do
      nil ->
        :ok

      {_key, pads} ->
        raise """
        #{inspect(__MODULE__)} supports only one input and one output pad of each kind. \
        Found multiple pads of the same direction and kind: #{Map.keys(pads) |> inspect()}
        """
    end
  end
end
