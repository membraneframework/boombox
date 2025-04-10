defmodule Boombox.StorageEndpoints.WAV do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.Pipeline.Ready
  alias Boombox.StorageEndpoints

  @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      |> child(:wav_input_parser, Membrane.WAV.Parser)

    %Ready{track_builders: %{audio: spec}}
  end

  @spec link_output(
          String.t(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, _spec_builder) do
    spec =
      track_builders[:audio]
      |> child(:wav_transcoder, %Membrane.Transcoder{
        output_stream_format: Membrane.RawAudio
      })
      |> child(:wav_output_parser, Membrane.WAV.Serializer)
      |> child(:file_sink, %Membrane.File.Sink{location: location})

    %Ready{actions: [spec: spec]}
  end
end
