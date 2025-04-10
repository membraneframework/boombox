defmodule Boombox.StorageEndpoints.AAC do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.Pipeline.Ready
  alias Boombox.StorageEndpoints
  alias Membrane.AAC

  @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      |> child(:aac_input_parser, Membrane.AAC.Parser)

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
      |> child(:aac_audio_transcoder, %Membrane.Transcoder{
        output_stream_format: AAC
      })
      |> child(:file_sink, %Membrane.File.Sink{location: location})

    %Ready{actions: [spec: spec]}
  end
end
