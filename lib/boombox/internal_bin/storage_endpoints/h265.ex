defmodule Boombox.InternalBin.StorageEndpoints.H265 do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.InternalBin.Ready
  alias Boombox.InternalBin.StorageEndpoints
  alias Membrane.H265

  @spec create_input(String.t(), transport: :file | :http, framerate: H265.framerate_t()) ::
          Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      |> child(:h265_parser, %H265.Parser{
        output_alignment: :au,
        generate_best_effort_timestamps: %{framerate: opts[:framerate]},
        output_stream_structure: :annexb
      })

    %Ready{track_builders: %{video: spec}}
  end

  @spec link_output(
          String.t(),
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, _spec_builder) do
    spec =
      track_builders[:video]
      |> child(:h265_video_transcoder, %Membrane.Transcoder{
        output_stream_format: %H265{stream_structure: :annexb}
      })
      |> child(:file_sink, %Membrane.File.Sink{location: location})

    %Ready{actions: [spec: spec]}
  end
end
