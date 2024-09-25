defmodule Boombox.WebRTC do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.{Ready, Wait}
  alias Boombox.Transcoders
  alias Membrane.H264

  @spec create_input(Boombox.webrtc_signaling(), Boombox.output()) :: Wait.t()
  def create_input(signaling, output) do
    signaling = resolve_signaling(signaling)

    keyframe_interval =
      case output do
        {:webrtc, _signaling} -> nil
        _other -> Membrane.Time.seconds(2)
      end

    spec =
      child(:webrtc_input, %Membrane.WebRTC.Source{
        signaling: signaling,
        video_codec: :h264,
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

  @spec create_output(Boombox.webrtc_signaling()) :: Ready.t()
  def create_output(signaling) do
    signaling = resolve_signaling(signaling)

    spec =
      child(:webrtc_output, %Membrane.WebRTC.Sink{
        signaling: signaling,
        tracks: [],
        video_codec: :h264
      })

    %Ready{actions: [spec: spec]}
  end

  @spec link_output(Boombox.Pipeline.track_builders()) :: Wait.t()
  def link_output(track_builders) do
    tracks = Bunch.KVEnum.keys(track_builders)
    %Wait{actions: [notify_child: {:webrtc_output, {:add_tracks, tracks}}]}
  end

  @spec handle_output_tracks_negotiated(
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t(),
          Membrane.WebRTC.Sink.new_tracks()
        ) :: Ready.t()
  def handle_output_tracks_negotiated(track_builders, spec_builder, tracks) do
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
          builder
          |> child(:webrtc_out_video_realtimer, Membrane.Realtimer)
          |> child(:webrtc_video_transcoder, %Transcoders.Video{
            output_stream_format: %H264{alignment: :nalu, stream_structure: :annexb}
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
end
