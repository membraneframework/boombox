defmodule Boombox.StorageEndpoints.H264 do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.Pipeline.Ready
  alias Boombox.StorageEndpoints
  alias Membrane.H264

  @spec create_input(String.t(), transport: :file | :http, framerate: Membrane.H264.framerate()) ::
          Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      |> child(:h264_parser, %Membrane.H264.Parser{
        output_alignment: :au,
        generate_best_effort_timestamps: %{framerate: opts[:framerate]},
        output_stream_structure: :annexb
      })

    %Ready{track_builders: %{video: spec}}
  end

  @spec link_output(
          String.t(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, _spec_builder) do
    spec =
      track_builders[:video]
      |> child(:h264_video_transcoder, %Membrane.Transcoder{
        output_stream_format: %H264{stream_structure: :annexb}
      })
      |> child(:file_sink, %Membrane.File.Sink{location: location})

    %Ready{actions: [spec: spec]}
  end
end
