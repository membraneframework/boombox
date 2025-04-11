defmodule Boombox.StorageEndpoints.MP3 do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.InternalBin.Ready
  alias Boombox.StorageEndpoints

  @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      # transcoder is used just to ensure that a proper MPEGAudio stream format is resolved
      # as there is no MP3 parser that could do it
      |> child(:mp3_stream_format_overrider, %Membrane.Transcoder{
        output_stream_format: Membrane.MPEGAudio,
        assumed_input_stream_format: %Membrane.RemoteStream{
          content_format: Membrane.MPEGAudio
        }
      })

    %Ready{track_builders: %{audio: spec}}
  end

  @spec link_output(
          String.t(),
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, _spec_builder) do
    spec =
      track_builders[:audio]
      |> child(:mp3_audio_transcoder, %Membrane.Transcoder{
        output_stream_format: Membrane.MPEGAudio
      })
      |> child(:file_sink, %Membrane.File.Sink{location: location})

    %Ready{actions: [spec: spec]}
  end
end
