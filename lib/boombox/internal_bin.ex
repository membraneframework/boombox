defmodule Boombox.InternalBin do
  @moduledoc false
  use Membrane.Bin

  require Membrane.Logger
  require Boombox.InternalBin.StorageEndpoints, as: StorageEndpoints
  require Membrane.Transcoder.Audio
  require Membrane.Transcoder.Video

  alias Membrane.Transcoder

  @type input() ::
          Boombox.Bin.input()
          | {:stream, pid(), Boombox.in_stream_opts()}
          | :membrane_pad

  @type output ::
          Boombox.Bin.output()
          | {:stream, pid(), Boombox.out_stream_opts()}
          | :membrane_pad

  @type track_builders :: %{
          optional(:audio) => Membrane.ChildrenSpec.t(),
          optional(:video) => Membrane.ChildrenSpec.t()
        }
  @type storage_type :: :file | :http

  defmodule Ready do
    @moduledoc false

    @type t :: %__MODULE__{
            actions: [Membrane.Bin.Action.t()],
            track_builders: Boombox.InternalBin.track_builders() | nil,
            spec_builder: Membrane.ChildrenSpec.t() | nil,
            eos_info: term
          }

    defstruct actions: [], track_builders: nil, spec_builder: [], eos_info: nil
  end

  defmodule Wait do
    @moduledoc false

    @type t :: %__MODULE__{actions: [Membrane.Bin.Action.t()]}
    defstruct actions: []
  end

  defmodule State do
    @moduledoc false
    use Bunch.Access

    @enforce_keys [:status, :input, :output]

    defstruct @enforce_keys ++
                [
                  actions_acc: [],
                  spec_builder: [],
                  track_builders: nil,
                  last_result: nil,
                  eos_info: nil,
                  rtsp_state: nil,
                  pending_new_tracks: %{input: [], output: []},
                  output_webrtc_state: nil,
                  new_tracks_notification_status: :not_resolved
                ]

    @typedoc """
    Statuses of the Boombox.InternalBin in the order of occurence.

    Statuses starting with `awaiting_` occur only if
    the `proceed` function returns `t:Wait.t/0` when in the
    preceeding status.
    """
    @type status ::
            :init
            | :awaiting_output
            | :output_ready
            | :awaiting_input
            | :input_ready
            | :awaiting_output_link
            | :output_linked
            | :running

    @type t :: %__MODULE__{
            status: status(),
            input: Boombox.InternalBin.input(),
            output: Boombox.InternalBin.output(),
            actions_acc: [Membrane.Bin.Action.t()],
            spec_builder: Membrane.ChildrenSpec.t(),
            track_builders: Boombox.InternalBin.track_builders() | nil,
            last_result: Ready.t() | Wait.t() | nil,
            eos_info: term(),
            rtsp_state: Boombox.InternalBin.RTSP.state() | nil,
            output_webrtc_state: Boombox.InternalBin.WebRTC.output_webrtc_state() | nil,
            new_tracks_notification_status:
              Boombox.InternalBin.Pad.new_tracks_notification_status()
          }
  end

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
          | nil
      ],
      transcoding_policy: [
        spec: :always | :if_needed | :never
      ]
    ]

  def_options input: [spec: input()],
              output: [spec: output()]

  @impl true
  def handle_init(ctx, opts) do
    if opts.input == :membrane_pad and opts.output == :membrane_pad do
      raise """
      Internal boombox error: both input and output of #{inspect(__MODULE__)} are set to :membrane_pad.
      """
    end

    state =
      %State{
        input: parse_endpoint_opt!(:input, opts.input),
        output: parse_endpoint_opt!(:output, opts.output),
        status: :init
      }

    :ok = maybe_log_transcoding_related_warning(state.input, state.output)
    proceed(ctx, state)
  end

  @impl true
  def handle_playing(ctx, state) do
    state =
      Boombox.InternalBin.Pad.resolve_new_tracks_notification_status(state, ctx)

    case state.status do
      :awaiting_input when state.input == :membrane_pad ->
        Boombox.InternalBin.Pad.create_input(ctx)
        |> proceed_result(ctx, state)

      :awaiting_output_link when state.output == :membrane_pad ->
        {result, state} =
          Boombox.InternalBin.Pad.link_output(
            ctx,
            state.track_builders,
            state.spec_builder,
            state
          )

        proceed_result(result, ctx, state)

      _status ->
        {[], state}
    end
  end

  @impl true
  def handle_pad_added(Pad.ref(direction, _id) = pad_ref, ctx, state) do
    if state[direction] != :membrane_pad do
      raise """
      internal boombox error (state.#{direction} is #{inspect(state[direction])}) but it \
      should be :membrane_pad
      """
    end

    actions = Boombox.InternalBin.Pad.handle_pad_added(pad_ref, ctx.pad_options.kind, ctx, state)
    {actions, state}
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :mp4_demuxer, ctx, state) do
    Boombox.InternalBin.StorageEndpoints.MP4.handle_input_tracks(tracks)
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_child_notification({:set_up_tracks, tracks}, :rtsp_source, ctx, state) do
    {result, state} = Boombox.InternalBin.RTSP.handle_set_up_tracks(tracks, state)
    proceed_result(result, ctx, state)
  end

  @impl true
  def handle_child_notification({:new_track, ssrc, track}, :rtsp_source, ctx, state) do
    {result, state} = Boombox.InternalBin.RTSP.handle_input_track(ssrc, track, state)
    proceed_result(result, ctx, state)
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :webrtc_input, ctx, state) do
    Boombox.InternalBin.WebRTC.handle_input_tracks(tracks)
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_child_notification({:negotiated_video_codecs, codecs}, :webrtc_output, ctx, state) do
    {result, state} =
      Boombox.InternalBin.WebRTC.handle_output_video_codecs_negotiated(codecs, state)

    proceed_result(result, ctx, state)
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :webrtc_output, ctx, state) do
    unless state.status == :awaiting_output_link do
      raise """
      Invalid status: #{inspect(state.status)}, expected :awaiting_output_link. \
      This is probably a bug in Boombox.
      """
    end

    {:webrtc, _signaling, webrtc_opts} = state.output

    Boombox.InternalBin.WebRTC.handle_output_tracks_negotiated(
      webrtc_opts,
      state.track_builders,
      state.spec_builder,
      tracks,
      state
    )
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_child_notification({:end_of_stream, id}, :webrtc_output, _ctx, state) do
    %{eos_info: track_ids} = state
    track_ids = List.delete(track_ids, id)
    state = %{state | eos_info: track_ids}

    if track_ids == [] do
      wait_before_closing()
      {[notify_parent: :processing_finished], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_child_notification(:end_of_stream, :hls_sink_bin, _ctx, state) do
    {[notify_parent: :processing_finished], state}
  end

  @impl true
  def handle_child_notification(notification, child, _ctx, state) do
    Membrane.Logger.debug_verbose(
      "Ignoring notification #{inspect(notification)} from child #{inspect(child)}"
    )

    {[], state}
  end

  @impl true
  def handle_info({:rtmp_client_ref, client_ref}, ctx, state) do
    Boombox.InternalBin.RTMP.handle_connection(client_ref)
    |> proceed_result(ctx, state)
  end

  @impl true
  def handle_element_end_of_stream(element, :input, _ctx, state)
      when element in [:hls_sink_bin, :file_sink, :udp_rtp_sink] do
    {[notify_parent: :processing_finished], state}
  end

  @impl true
  def handle_element_end_of_stream(:elixir_stream_sink, Pad.ref(:input, id), _ctx, state) do
    eos_info = List.delete(state.eos_info, id)
    state = %{state | eos_info: eos_info}

    case eos_info do
      [] -> {[notify_parent: :processing_finished], state}
      _eos_info -> {[], state}
    end
  end

  @impl true
  def handle_element_end_of_stream(_element, _pad, _ctx, state) do
    {[], state}
  end

  @spec proceed_result(Ready.t() | Wait.t(), Membrane.Bin.CallbackContext.t(), State.t()) ::
          Membrane.Bin.callback_return()
  defp proceed_result(result, ctx, %{status: :awaiting_output} = state) do
    do_proceed(result, :output_ready, :awaiting_output, ctx, state)
  end

  defp proceed_result(result, ctx, %{status: :awaiting_input} = state) do
    do_proceed(result, :input_ready, :awaiting_input, ctx, state)
  end

  defp proceed_result(result, ctx, %{status: :awaiting_output_link} = state) do
    do_proceed(result, :output_linked, :awaiting_output_link, ctx, state)
  end

  defp proceed_result(result, ctx, %{status: :running} = state) do
    do_proceed(result, :running, :running, ctx, state)
  end

  defp proceed_result(_result, _ctx, state) do
    raise """
    Boombox got into invalid internal state. Status: #{inspect(state.status)}.
    """
  end

  @spec proceed(Membrane.Bin.CallbackContext.t(), State.t()) ::
          Membrane.Bin.callback_return()
  defp proceed(ctx, %{status: :init} = state) do
    {ready_or_wait, state} = create_output(state.output, ctx, state)
    do_proceed(ready_or_wait, :output_ready, :awaiting_output, ctx, state)
  end

  defp proceed(ctx, %{status: :output_ready} = state) do
    create_input(state.input, ctx, state)
    |> do_proceed(:input_ready, :awaiting_input, ctx, state)
  end

  defp proceed(
         ctx,
         %{
           status: :input_ready,
           last_result: %Ready{track_builders: track_builders, spec_builder: spec_builder}
         } = state
       )
       when track_builders != nil do
    state = %{state | track_builders: track_builders, spec_builder: spec_builder}

    {result, state} = link_output(state.output, track_builders, spec_builder, ctx, state)
    do_proceed(result, :output_linked, :awaiting_output_link, ctx, state)
  end

  defp proceed(ctx, %{status: :output_linked} = state) do
    do_proceed(%Wait{}, nil, :running, ctx, %{state | eos_info: state.last_result.eos_info})
  end

  defp proceed(_ctx, state) do
    raise """
    Boombox got into invalid internal state. Status: #{inspect(state.status)}.
    """
  end

  @spec do_proceed(
          Ready.t() | Wait.t(),
          State.status() | nil,
          State.status() | nil,
          Membrane.Bin.CallbackContext.t(),
          State.t()
        ) :: Membrane.Bin.callback_return()
  defp do_proceed(result, ready_status, wait_status, ctx, state) do
    %{actions_acc: actions_acc} = state

    case result do
      %Ready{actions: actions} = result when ready_status != nil ->
        proceed(ctx, %{
          state
          | status: ready_status,
            last_result: result,
            actions_acc: actions_acc ++ actions
        })

      %Wait{actions: actions} when wait_status != nil ->
        {actions_acc ++ actions, %{state | actions_acc: [], status: wait_status}}
    end
  end

  @spec create_input(input(), Membrane.Bin.CallbackContext.t(), State.t()) ::
          Ready.t() | Wait.t()
  defp create_input({:webrtc, signaling}, ctx, state) do
    Boombox.InternalBin.WebRTC.create_input(signaling, state.output, ctx, state)
  end

  defp create_input({:mp4, location, opts}, _ctx, _state) do
    Boombox.InternalBin.StorageEndpoints.MP4.create_input(location, opts)
  end

  defp create_input({:rtsp, uri}, _ctx, _state) do
    Boombox.InternalBin.RTSP.create_input(uri)
  end

  defp create_input({:stream, stream_process, params}, _ctx, _state) do
    Boombox.InternalBin.ElixirStream.create_input(stream_process, params)
  end

  defp create_input({:h264, location, opts}, _ctx, _state) do
    Boombox.InternalBin.StorageEndpoints.H264.create_input(location, opts)
  end

  defp create_input({:h265, location, opts}, _ctx, _state) do
    Boombox.InternalBin.StorageEndpoints.H265.create_input(location, opts)
  end

  defp create_input({:aac, location, opts}, _ctx, _state) do
    Boombox.InternalBin.StorageEndpoints.AAC.create_input(location, opts)
  end

  defp create_input({:wav, location, opts}, _ctx, _state) do
    Boombox.InternalBin.StorageEndpoints.WAV.create_input(location, opts)
  end

  defp create_input({:mp3, location, opts}, _ctx, _state) do
    Boombox.InternalBin.StorageEndpoints.MP3.create_input(location, opts)
  end

  defp create_input({:ivf, location, opts}, _ctx, _state) do
    Boombox.InternalBin.StorageEndpoints.IVF.create_input(location, opts)
  end

  defp create_input({:ogg, location, opts}, _ctx, _state) do
    Boombox.InternalBin.StorageEndpoints.Ogg.create_input(location, opts)
  end

  defp create_input({:rtmp, src}, ctx, _state) do
    Boombox.InternalBin.RTMP.create_input(src, ctx.utility_supervisor)
  end

  defp create_input({:rtp, opts}, _ctx, _state) do
    Boombox.InternalBin.RTP.create_input(opts)
  end

  defp create_input(:membrane_pad, ctx, _state) do
    Boombox.InternalBin.Pad.create_input(ctx)
  end

  @spec create_output(output(), Membrane.Bin.CallbackContext.t(), State.t()) ::
          {Ready.t() | Wait.t(), State.t()}
  defp create_output({:webrtc, signaling, _opts}, ctx, state) do
    Boombox.InternalBin.WebRTC.create_output(signaling, ctx, state)
  end

  defp create_output(_output, _ctx, state) do
    {%Ready{}, state}
  end

  @spec link_output(
          output(),
          track_builders(),
          Membrane.ChildrenSpec.t(),
          Membrane.Bin.CallbackContext.t(),
          State.t()
        ) ::
          {Ready.t() | Wait.t(), State.t()}
  defp link_output({:webrtc, _signaling, opts}, track_builders, spec_builder, _ctx, state) do
    tracks = [
      %{kind: :audio, id: :audio_track},
      %{kind: :video, id: :video_tracks}
    ]

    result =
      Boombox.InternalBin.WebRTC.link_output(opts, track_builders, spec_builder, tracks, state)

    {result, state}
  end

  defp link_output({:mp4, location, opts}, track_builders, spec_builder, _ctx, state) do
    result =
      Boombox.InternalBin.StorageEndpoints.MP4.link_output(
        location,
        opts,
        track_builders,
        spec_builder
      )

    {result, state}
  end

  defp link_output({:h264, location, _opts}, track_builders, spec_builder, _ctx, state) do
    maybe_warn_about_dropped_tracks(track_builders, :audio, :h264)

    result =
      Boombox.InternalBin.StorageEndpoints.H264.link_output(
        location,
        track_builders,
        spec_builder
      )

    {result, state}
  end

  defp link_output({:h265, location, _opts}, track_builders, spec_builder, _ctx, state) do
    maybe_warn_about_dropped_tracks(track_builders, :audio, :h265)

    result =
      Boombox.InternalBin.StorageEndpoints.H265.link_output(
        location,
        track_builders,
        spec_builder
      )

    {result, state}
  end

  defp link_output({:aac, location, _opts}, track_builders, spec_builder, _ctx, state) do
    maybe_warn_about_dropped_tracks(track_builders, :video, :aac)

    result =
      Boombox.InternalBin.StorageEndpoints.AAC.link_output(location, track_builders, spec_builder)

    {result, state}
  end

  defp link_output({:wav, location, _opts}, track_builders, spec_builder, _ctx, state) do
    maybe_warn_about_dropped_tracks(track_builders, :video, :wav)

    result =
      Boombox.InternalBin.StorageEndpoints.WAV.link_output(location, track_builders, spec_builder)

    {result, state}
  end

  defp link_output({:mp3, location, _opts}, track_builders, spec_builder, _ctx, state) do
    maybe_warn_about_dropped_tracks(track_builders, :video, :mp3)

    result =
      Boombox.InternalBin.StorageEndpoints.MP3.link_output(location, track_builders, spec_builder)

    {result, state}
  end

  defp link_output({:ivf, location, _opts}, track_builders, spec_builder, _ctx, state) do
    maybe_warn_about_dropped_tracks(track_builders, :audio, :ivf)

    result =
      Boombox.InternalBin.StorageEndpoints.IVF.link_output(location, track_builders, spec_builder)

    {result, state}
  end

  defp link_output({:ogg, location, _opts}, track_builders, spec_builder, _ctx, state) do
    maybe_warn_about_dropped_tracks(track_builders, :video, :ogg)

    result =
      Boombox.InternalBin.StorageEndpoints.Ogg.link_output(location, track_builders, spec_builder)

    {result, state}
  end

  defp link_output({:hls, location, opts}, track_builders, spec_builder, _ctx, state) do
    result =
      Boombox.InternalBin.HLS.link_output(location, opts, track_builders, spec_builder)

    {result, state}
  end

  defp link_output({:rtp, opts}, track_builders, spec_builder, _ctx, state) do
    result =
      Boombox.InternalBin.RTP.link_output(opts, track_builders, spec_builder)

    {result, state}
  end

  defp link_output({:stream, stream_process, params}, track_builders, spec_builder, _ctx, state) do
    result =
      Boombox.InternalBin.ElixirStream.link_output(
        stream_process,
        params,
        track_builders,
        spec_builder
      )

    {result, state}
  end

  defp link_output(:membrane_pad, track_builder, spec_builder, ctx, state) do
    Boombox.InternalBin.Pad.link_output(ctx, track_builder, spec_builder, state)
  end

  # Wait between sending the last packet
  # and terminating boombox, to avoid closing
  # any connection before the other peer
  # receives the last packet.
  defp wait_before_closing() do
    Process.sleep(500)
  end

  @spec parse_endpoint_opt!(:input, input()) :: input()
  @spec parse_endpoint_opt!(:output, output()) :: output()
  defp parse_endpoint_opt!(direction, value) when is_binary(value) do
    parse_endpoint_opt!(direction, {value, []})
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp parse_endpoint_opt!(direction, {value, opts}) when is_binary(value) do
    uri = URI.parse(value)
    scheme = uri.scheme
    extension = if uri.path, do: Path.extname(uri.path)

    case {scheme, extension, direction} do
      {scheme, extension, :input}
      when scheme in [nil, "http", "https"] and
             StorageEndpoints.is_storage_endpoint_extension(extension) ->
        {StorageEndpoints.get_storage_endpoint_type!(extension), value, opts}

      {nil, extension, :output} when StorageEndpoints.is_storage_endpoint_extension(extension) ->
        {StorageEndpoints.get_storage_endpoint_type!(extension), value, opts}

      {scheme, _ext, :input} when scheme in ["rtmp", "rtmps"] ->
        {:rtmp, value}

      {"rtsp", _ext, :input} ->
        {:rtsp, value}

      {nil, ".m3u8", :output} ->
        {:hls, value, opts}

      _other ->
        raise ArgumentError, "Unsupported URI: #{value} for direction: #{direction}"
    end
    |> then(&parse_endpoint_opt!(direction, &1))
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp parse_endpoint_opt!(direction, value) when is_tuple(value) or is_atom(:value) do
    case value do
      {endpoint_type, location}
      when is_binary(location) and direction == :input and
             StorageEndpoints.is_storage_endpoint_type(endpoint_type) ->
        parse_endpoint_opt!(:input, {endpoint_type, location, []})

      {endpoint_type, location, opts}
      when endpoint_type in [:h264, :h265] and is_binary(location) and direction == :input ->
        {endpoint_type, location,
         transport: resolve_transport(location, opts), framerate: opts[:framerate] || {30, 1}}

      {endpoint_type, location, opts}
      when is_binary(location) and direction == :input and
             StorageEndpoints.is_storage_endpoint_type(endpoint_type) ->
        {endpoint_type, location, transport: resolve_transport(location, opts)}

      {endpoint_type, location}
      when is_binary(location) and direction == :output and
             StorageEndpoints.is_storage_endpoint_type(endpoint_type) ->
        {endpoint_type, location, []}

      {endpoint_type, location, _opts}
      when is_binary(location) and direction == :output and
             StorageEndpoints.is_storage_endpoint_type(endpoint_type) ->
        value

      {:webrtc, %Membrane.WebRTC.Signaling{}} when direction == :input ->
        value

      {:webrtc, %Membrane.WebRTC.Signaling{} = signaling} ->
        {:webrtc, signaling, []}

      {:webrtc, %Membrane.WebRTC.Signaling{}, _opts} when direction == :output ->
        value

      {:webrtc, uri} when is_binary(uri) and direction == :input ->
        value

      {:webrtc, uri} when is_binary(uri) and direction == :output ->
        {:webrtc, uri, []}

      {:webrtc, uri, _opts} when is_binary(uri) and direction == :output ->
        value

      {:whip, uri} when is_binary(uri) ->
        parse_endpoint_opt!(direction, {:whip, uri, []})

      {:whip, uri, opts} when is_binary(uri) and is_list(opts) and direction == :input ->
        if Keyword.keyword?(opts), do: {:webrtc, value}

      {:whip, uri, opts} when is_binary(uri) and is_list(opts) and direction == :output ->
        {webrtc_opts, whip_opts} = split_webrtc_and_whip_opts(opts)
        if Keyword.keyword?(opts), do: {:webrtc, {:whip, uri, whip_opts}, webrtc_opts}

      {:rtmp, arg} when direction == :input and (is_binary(arg) or is_pid(arg)) ->
        value

      {:hls, location} when direction == :output and is_binary(location) ->
        {:hls, location, []}

      {:hls, location, opts}
      when direction == :output and is_binary(location) and is_list(opts) ->
        value

      {:rtsp, location} when direction == :input and is_binary(location) ->
        value

      {:rtp, opts} ->
        if Keyword.keyword?(opts), do: value

      {:stream, stream_process, opts} when is_pid(stream_process) ->
        if Keyword.keyword?(opts), do: value

      :membrane_pad ->
        :membrane_pad

      _other ->
        nil
    end
    |> case do
      nil -> raise ArgumentError, "Invalid #{direction} specification: #{inspect(value)}"
      value -> value
    end
  end

  @spec resolve_transport(String.t(), [{:transport, :file | :http}]) :: :file | :http
  defp resolve_transport(location, opts) do
    opts = opts |> Keyword.validate!(transport: nil, transcoding_policy: :if_needed)

    case opts[:transport] do
      nil ->
        uri = URI.parse(location)

        case uri.scheme do
          nil -> :file
          "http" -> :http
          "https" -> :http
          _other -> raise ArgumentError, "Unsupported URI: #{location}"
        end

      transport when transport in [:file, :http] ->
        transport

      transport ->
        raise ArgumentError, "Invalid transport: #{inspect(transport)}"
    end
  end

  defp split_webrtc_and_whip_opts(opts) do
    opts
    |> Enum.split_with(fn {key, _value} -> key == :transcoding_policy end)
  end

  @spec maybe_log_transcoding_related_warning(input(), output()) :: :ok
  defp maybe_log_transcoding_related_warning(input, output) do
    if webrtc?(output) and not handles_keyframe_requests?(input) and
         webrtc_output_transcoding_policy(output) != :always do
      Membrane.Logger.warning("""
      Boombox output protocol is WebRTC, while Boombox input doesn't support keyframe requests. This \
      might lead to issues with the output video if the output stream isn't sent only by localhost. You \
      can solve this by setting `:transcoding_policy` output option to `:always`, but be aware that it \
      will increase Boombox CPU usage.
      """)
    end

    :ok
  end

  defp webrtc?({:webrtc, _signaling}), do: true
  defp webrtc?({:webrtc, _signaling, _opts}), do: true
  defp webrtc?(_endpoint), do: false

  defp handles_keyframe_requests?({:stream, _pid, _opts}), do: true
  defp handles_keyframe_requests?(endpoint), do: webrtc?(endpoint)

  defp webrtc_output_transcoding_policy({:webrtc, _singaling, opts}),
    do: Keyword.get(opts, :transcoding_policy, :if_needed)

  defp maybe_warn_about_dropped_tracks(track_builders, dropped_track, output_type) do
    if track_builders[dropped_track] do
      Membrane.Logger.info(
        "Dropping #{dropped_track} track from input, as output #{output_type} does not support #{dropped_track}"
      )
    end
  end
end
