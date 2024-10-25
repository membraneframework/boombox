defmodule Boombox.WebRTC do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.{Ready, State, Wait}
  alias Boombox.Transcoders
  alias Membrane.H264
  alias Membrane.VP8

  @type output_webrtc_state :: %{negotiated_video_codecs: [:vp8 | :h264] | nil}
  @type webrtc_sink_new_tracks :: [%{id: term, kind: :audio | :video}]

  @spec create_input(Boombox.webrtc_signaling(), Boombox.output(), State.t()) :: Wait.t()
  def create_input(signaling, output, state) do
    signaling = resolve_signaling(signaling)

    keyframe_interval =
      case output do
        {:webrtc, _signaling} -> nil
        _other -> Membrane.Time.seconds(2)
      end

    {suggested_video_codec, allowed_video_codecs} =
      case state.output_webrtc_state do
        nil ->
          {:h264, [:h264, :vp8]}

        %{negotiated_video_codecs: []} ->
          # suggested_video_codec will be ignored
          {:vp8, []}

        %{negotiated_video_codecs: [codec]} ->
          {codec, [:h264, :vp8]}

        %{negotiated_video_codecs: both} when is_list(both) ->
          {:vp8, both}
      end

    spec =
      child(:webrtc_input, %Membrane.WebRTC.Source{
        signaling: signaling,
        suggested_video_codec: suggested_video_codec,
        allowed_video_codecs: allowed_video_codecs,
        keyframe_interval: keyframe_interval
      })

    %Wait{actions: [spec: spec]}
  end

  @spec handle_input_tracks(Membrane.WebRTC.Source.new_tracks()) :: Ready.t()
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

  @spec create_output(Boombox.webrtc_signaling(), State.t()) :: {Ready.t() | Wait.t(), State.t()}
  def create_output(signaling, state) do
    signaling = resolve_signaling(signaling)
    startup_tracks = if webrtc_input?(state), do: [:audio, :video], else: []

    spec =
      child(:webrtc_output, %Membrane.WebRTC.Sink{
        signaling: signaling,
        tracks: startup_tracks,
        video_codec: [:vp8, :h264]
      })

    state = %{state | output_webrtc_state: %{negotiated_video_codecs: nil}}

    status =
      if webrtc_input?(state),
        do: %Wait{actions: [spec: spec]},
        else: %Ready{actions: [spec: spec]}

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
          |> child(:mp4_audio_transcoder, %Transcoders.Audio{
            output_stream_format_module: Membrane.Opus
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
          |> child(:webrtc_video_transcoder, %Transcoders.Video{
            output_stream_format: fn
              %H264{} = h264 when h264_negotiated? ->
                %H264{h264 | alignment: :nalu, stream_structure: :annexb}

              %VP8{} = vp8 when vp8_negotiated? ->
                vp8

              _format when h264_negotiated? ->
                %H264{alignment: :nalu, stream_structure: :annexb}

              %{width: width, height: height} when vp8_negotiated? ->
                %VP8{width: width, height: height}

              _format when vp8_negotiated? ->
                VP8
            end
          })
          |> via_in(Pad.ref(:input, tracks.video), options: [kind: :video])
          |> get_child(:webrtc_output)
      end)
    ]

    %Ready{actions: [spec: spec], eos_info: Map.values(tracks)}
  end

  defp resolve_signaling(%Membrane.WebRTC.SignalingChannel{} = signaling) do
    signaling
  end

  defp resolve_signaling(uri) when is_binary(uri) do
    uri = URI.new!(uri)
    {:ok, ip} = :inet.getaddr(~c"#{uri.host}", :inet)
    {:websocket, ip: ip, port: uri.port}
  end

  defp webrtc_input?(%{input: {:webrtc, _signalling}}), do: true
  defp webrtc_input?(_state), do: false
end
