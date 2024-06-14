defmodule Boombox.WebRTC do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad

  def create_input(signaling) do
    signaling = resolve_signaling(signaling)

    spec = [
      child(:webrtc_input, %Membrane.WebRTC.Source{
        signaling: signaling,
        video_codec: :h264
      }),
      get_child(:webrtc_input)
      |> via_out(:output, options: [kind: :audio])
      |> child(:opus_decoder, Membrane.Opus.Decoder)
    ]

    builders = %{
      audio: get_child(:opus_decoder),
      video:
        get_child(:webrtc_input)
        |> via_out(:output, options: [kind: :video])
    }

    {:ready, spec, builders}
  end

  def create_output(signaling, builders) do
    signaling = resolve_signaling(signaling)

    spec = [
      child(:webrtc_output, %Membrane.WebRTC.Sink{
        signaling: signaling,
        video_codec: :h264
      }),
      builders.video
      |> child(Membrane.Realtimer)
      |> child(%Membrane.H264.Parser{output_stream_structure: :annexb, output_alignment: :nalu})
      |> via_in(Pad.ref(:input, :video_track), options: [kind: :video])
      |> get_child(:webrtc_output),
      builders.audio
      |> child(%Membrane.FFmpeg.SWResample.Converter{
        output_stream_format: %Membrane.RawAudio{
          sample_format: :s16le,
          sample_rate: 48_000,
          channels: 2
        }
      })
      |> child(Membrane.Opus.Encoder)
      |> child(Membrane.Realtimer)
      |> via_in(Pad.ref(:input, :audio_track), options: [kind: :audio])
      |> get_child(:webrtc_output)
    ]

    {:ready, spec}
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
