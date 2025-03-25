defmodule Boombox.IVF do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.Pipeline.Ready

  @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  def create_input(location, opts) do
    spec =
      case opts[:transport] do
        :file ->
          child(:ivf_in_file_source, %Membrane.File.Source{location: location})
          |> child(:ivf_deserializer, Membrane.IVF.Deserializer)

        :http ->
          child(:ivf_in_http_source, %Membrane.Hackney.Source{
            location: location,
            hackney_opts: [follow_redirect: true]
          })
          |> child(:ivf_deserializer, Membrane.IVF.Deserializer)
      end

    %Ready{track_builders: [{:video, spec}]}
  end

  @spec link_output(
          String.t(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, _spec_builder) do
    [{:video, video_track_builder}] =
      track_builders
      |> Enum.filter(fn
        {:video, _track_builder} -> true
        _other -> false
      end)

    spec =
      video_track_builder
      |> child(:ivf_video_transcoder, %Membrane.Transcoder{
        output_stream_format: fn
          %Membrane.VP8{} -> Membrane.VP8
          %Membrane.VP9{} -> Membrane.VP9
          _other -> Membrane.VP9
        end
      })
      |> child(:ivf_serializer, Membrane.IVF.Serializer)
      |> child(:ivf_file_sink, %Membrane.File.Sink{location: location})

    %Ready{actions: [spec: spec]}
  end
end
