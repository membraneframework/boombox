defmodule Boombox.WebRTC do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.{Ready, State, Wait}
  alias Membrane.{H264, RemoteStream, VP8, WebRTC}
  alias Membrane.Pipeline.CallbackContext

  @type output_webrtc_state :: %{negotiated_video_codecs: [:vp8 | :h264] | nil}
  @type webrtc_sink_new_tracks :: [%{id: term, kind: :audio | :video}]

  @spec create_input(Boombox.webrtc_signaling(), Boombox.output(), CallbackContext.t(), State.t()) ::
          Wait.t()
  def create_input(signaling, output, ctx, state) do
    signaling = resolve_signaling(signaling, :input, ctx.utility_supervisor)

    keyframe_interval =
      case output do
        {:webrtc, _signaling} -> nil
        _other -> Membrane.Time.seconds(2)
      end

    {preferred_video_codec, allowed_video_codecs} =
      case state.output_webrtc_state do
        nil ->
          {:h264, [:h264, :vp8]}

        %{negotiated_video_codecs: []} ->
          # preferred_video_codec will be ignored
          {:vp8, []}

        %{negotiated_video_codecs: [codec]} ->
          {codec, [:h264, :vp8]}

        %{negotiated_video_codecs: [_codec_1, _codec_2] = codecs} ->
          {:vp8, codecs}
      end

    spec =
      child(:webrtc_input, %WebRTC.Source{
        signaling: signaling,
        preferred_video_codec: preferred_video_codec,
        allowed_video_codecs: allowed_video_codecs,
        keyframe_interval: keyframe_interval
      })

    %Wait{actions: [spec: spec]}
  end

  @spec handle_input_tracks(WebRTC.Source.new_tracks()) :: Ready.t()
  def handle_input_tracks(tracks) do
    track_builders =
      Map.new(tracks, fn
        %{kind: :audio, id: id} ->
          spec =
            get_child(:webrtc_input)
            |> via_out(Pad.ref(:output, id))

          {:audio, spec}

        %{kind: :video, id: id} ->
          spec =
            get_child(:webrtc_input)
            |> via_out(Pad.ref(:output, id))

          {:video, spec}
      end)

    %Ready{track_builders: track_builders}
  end

  @spec create_output(Boombox.webrtc_signaling(), CallbackContext.t(), State.t()) ::
          {Ready.t() | Wait.t(), State.t()}
  def create_output(signaling, ctx, state) do
    signaling = resolve_signaling(signaling, :output, ctx.utility_supervisor)
    startup_tracks = if webrtc_input?(state), do: [:audio, :video], else: []

    spec =
      child(:webrtc_output, %WebRTC.Sink{
        signaling: signaling,
        tracks: startup_tracks,
        video_codec: [:vp8, :h264]
      })

    state = %{state | output_webrtc_state: %{negotiated_video_codecs: nil}}

    {status, state} =
      if webrtc_input?(state) do
        # let's spawn websocket server for webrtc source before the source starts
        {:webrtc, input_signaling} = state.input
        signaling = resolve_signaling(input_signaling, :input, ctx.utility_supervisor)
        state = %{state | input: {:webrtc, signaling}}

        {%Wait{actions: [spec: spec]}, state}
      else
        {%Ready{actions: [spec: spec]}, state}
      end

    {status, state}
  end

  @spec handle_output_video_codecs_negotiated([:h264 | :vp8], State.t()) ::
          {Ready.t() | Wait.t(), State.t()}
  def handle_output_video_codecs_negotiated(codecs, state) do
    state = put_in(state.output_webrtc_state.negotiated_video_codecs, codecs)
    status = if webrtc_input?(state), do: %Ready{}, else: %Wait{}
    {status, state}
  end

  @spec link_output(
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t(),
          webrtc_sink_new_tracks(),
          State.t()
        ) :: Ready.t() | Wait.t()
  def link_output(track_builders, spec_builder, tracks, state) do
    if webrtc_input?(state) do
      do_link_output(track_builders, spec_builder, tracks, state)
    else
      tracks = Bunch.KVEnum.keys(track_builders)
      %Wait{actions: [notify_child: {:webrtc_output, {:add_tracks, tracks}}]}
    end
  end

  @spec handle_output_tracks_negotiated(
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t(),
          webrtc_sink_new_tracks(),
          State.t()
        ) :: Ready.t() | no_return()
  def handle_output_tracks_negotiated(track_builders, spec_builder, tracks, state) do
    if webrtc_input?(state) do
      raise """
      Currently ICE restart is not supported in Boombox instances having WebRTC input and output.
      """
    end

    do_link_output(track_builders, spec_builder, tracks, state)
  end

  defp do_link_output(track_builders, spec_builder, tracks, state) do
    tracks = Map.new(tracks, &{&1.kind, &1.id})

    spec = [
      spec_builder,
      Enum.map(track_builders, fn
        {:audio, builder} ->
          builder
          |> child(:mp4_audio_transcoder, %Membrane.Transcoder{
            output_stream_format: Membrane.Opus,
            enforce_transcoding?: state.enforce_audio_transcoding?
          })
          |> child(:webrtc_out_audio_realtimer, Membrane.Realtimer)
          |> via_in(Pad.ref(:input, tracks.audio), options: [kind: :audio])
          |> get_child(:webrtc_output)

        {:video, builder} ->
          negotiated_codecs = state.output_webrtc_state.negotiated_video_codecs
          vp8_negotiated? = :vp8 in negotiated_codecs
          h264_negotiated? = :h264 in negotiated_codecs

          builder
          |> child(:webrtc_out_video_realtimer, Membrane.Realtimer)
          |> child(:webrtc_video_transcoder, %Membrane.Transcoder{
            output_stream_format:
              &resolve_output_video_stream_format(
                &1,
                vp8_negotiated?,
                h264_negotiated?,
                state.enforce_video_transcoding?
              ),
            enforce_transcoding?: state.enforce_video_transcoding?
          })
          |> via_in(Pad.ref(:input, tracks.video), options: [kind: :video])
          |> get_child(:webrtc_output)
      end)
    ]

    %Ready{actions: [spec: spec], eos_info: Map.values(tracks)}
  end

  defp resolve_output_video_stream_format(
         input_stream_format,
         vp8_negotiated?,
         h264_negotiated?,
         false = _enforce_transcoding?
       ) do
    case input_stream_format do
      %H264{} = h264 when h264_negotiated? ->
        %H264{h264 | alignment: :nalu, stream_structure: :annexb}

      %VP8{} = vp8 when vp8_negotiated? ->
        vp8

      %RemoteStream{content_format: VP8, type: :packetized} when vp8_negotiated? ->
        VP8

      _format when h264_negotiated? ->
        %H264{alignment: :nalu, stream_structure: :annexb}

      _format when vp8_negotiated? ->
        VP8
    end
  end

  defp resolve_output_video_stream_format(
         _input_stream_format,
         vp8_negotiated?,
         h264_negotiated?,
         true = _enforce_transcoding?
       ) do
    # if we have to perform transcoding one way or another, we always choose H264 if it is possilbe,
    # because H264 Encoder comsumes less CPU than VP8 Encoder
    cond do
      h264_negotiated? -> %H264{alignment: :nalu, stream_structure: :annexb}
      vp8_negotiated? -> VP8
    end
  end

  defp resolve_signaling(
         %WebRTC.Signaling{} = signaling,
         _direction,
         _utility_supervisor
       ) do
    signaling
  end

  defp resolve_signaling({:whip, uri, opts}, :input, utility_supervisor) do
    uri = URI.new!(uri)
    {:ok, ip} = :inet.getaddr(~c"#{uri.host}", :inet)
    setup_whip_server([ip: ip, port: uri.port] ++ opts, utility_supervisor)
  end

  defp resolve_signaling({:whip, uri, opts}, :output, utility_supervisor) do
    signaling = WebRTC.Signaling.new()

    Membrane.UtilitySupervisor.start_link_child(
      utility_supervisor,
      {WebRTC.WhipClient, [signaling: signaling, uri: uri] ++ opts}
    )

    signaling
  end

  defp resolve_signaling(uri, _direction, utility_supervisor) when is_binary(uri) do
    uri = URI.new!(uri)
    {:ok, ip} = :inet.getaddr(~c"#{uri.host}", :inet)
    opts = [ip: ip, port: uri.port]

    WebRTC.SimpleWebSocketServer.start_link_supervised(utility_supervisor, opts)
  end

  defp setup_whip_server(opts, utility_supervisor) do
    signaling = WebRTC.Signaling.new()
    clients_cnt = :atomics.new(1, [])
    {valid_token, opts} = Keyword.pop(opts, :token)

    handle_new_client = fn token ->
      cond do
        valid_token not in [nil, token] -> {:error, :invalid_token}
        :atomics.add_get(clients_cnt, 1, 1) > 1 -> {:error, :already_connected}
        true -> {:ok, signaling}
      end
    end

    Membrane.UtilitySupervisor.start_child(utility_supervisor, {
      WebRTC.WhipServer,
      [handle_new_client: handle_new_client] ++ opts
    })

    signaling
  end

  defp webrtc_input?(%{input: {:webrtc, _signalling}}), do: true
  defp webrtc_input?(_state), do: false
end
