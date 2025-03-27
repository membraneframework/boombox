defmodule Boombox.StorageEndpoints.IVF do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.Pipeline.Ready
  alias Boombox.StorageEndpoints

  @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      |> child(:ivf_deserializer, Membrane.IVF.Deserializer)

    %Ready{track_builders: [{:video, spec}]}
  end

  @spec link_output(
          String.t(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, _spec_builder) do
    spec =
      StorageEndpoints.get_track(track_builders, :video)
      |> child(:ivf_video_transcoder, %Membrane.Transcoder{
        output_stream_format: fn
          %Membrane.VP8{} -> Membrane.VP8
          %Membrane.VP9{} -> Membrane.VP9
          _other -> Membrane.VP9
        end
      })
      |> child(:ivf_serializer, Membrane.IVF.Serializer)
      |> child(:file_sink, %Membrane.File.Sink{location: location})

    %Ready{actions: [spec: spec]}
  end
end
