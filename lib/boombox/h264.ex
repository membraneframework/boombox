defmodule Boombox.H264 do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.Pipeline.Ready
  alias Membrane.H264

  @spec create_input(String.t(), transport: :file | :http, framerate: Membrane.H264.framerate()) ::
          Ready.t()
  def create_input(location, opts) do
    spec =
      case opts[:transport] do
        :file ->
          child(:h264_in_file_source, %Membrane.File.Source{location: location})
          |> child(:h264_parser, %Membrane.H264.Parser{
            output_alignment: :au,
            generate_best_effort_timestamps: %{framerate: opts[:framerate]},
            output_stream_structure: :annexb
          })

        :http ->
          child(:h264_in_http_source, %Membrane.Hackney.Source{
            location: location,
            hackney_opts: [follow_redirect: true]
          })
          |> child(:h264_parser, %Membrane.H264.Parser{
            output_alignment: :au,
            generate_best_effort_timestamps: %{framerate: opts[:framerate]},
            output_stream_structure: :annexb
          })
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
        {:video, _track_builfer} -> true
        _other -> false
      end)

    spec =
      video_track_builder
      |> child(:h264_video_transcoder, %Membrane.Transcoder{
        output_stream_format: %H264{stream_structure: :annexb}
      })
      |> child(:h264_file_sink, %Membrane.File.Sink{location: location})

    %Ready{actions: [spec: spec]}
  end
end

# Boombox.run(input: {:h264, "input.h264"}, output: "out.mp4")
