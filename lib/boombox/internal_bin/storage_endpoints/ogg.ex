defmodule Boombox.InternalBin.StorageEndpoints.Ogg do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.InternalBin.Ready
  alias Boombox.InternalBin.StorageEndpoints

  @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      |> child(:ogg_demuxer, Membrane.Ogg.Demuxer)

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
      |> child(:ogg_audio_transcoder, %Membrane.Transcoder{
        output_stream_format: Membrane.Opus
      })
      |> child(:parser, %Membrane.Opus.Parser{
        generate_best_effort_timestamps?: true,
        delimitation: :undelimit,
        input_delimitted?: false
      })
      |> child(:ogg_muxer, Membrane.Ogg.Muxer)
      |> child(:file_sink, %Membrane.File.Sink{location: location})

    %Ready{actions: [spec: spec]}
  end
end
