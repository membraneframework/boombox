defmodule Boombox.InternalBin.StorageEndpoints.Ogg do
  @moduledoc false
  import Membrane.ChildrenSpec

  alias Boombox.InternalBin.Ready
  alias Boombox.InternalBin.StorageEndpoints
  alias Membrane.Transcoder

  @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  def create_input(location, opts) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      |> child(:ogg_demuxer, Membrane.Ogg.Demuxer)

    %Ready{track_builders: %{audio: spec}}
  end

  @spec link_output(
          String.t(),
          [Boombox.Endpoints.transcoding_policy_opt()],
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, opts, track_builders, _spec_builder) do
    transcoding_policy = opts |> Keyword.get(:transcoding_policy, :if_needed)

    pipeline_tail = fn builder ->
      builder
      |> child(:ogg_audio_transcoder, %Transcoder{
        transcoding_policy: transcoding_policy
      })
      |> via_out(:output,
        options: [output_stream_format: Transcoder.OutputFormat.Opus]
      )
      |> child(:parser, %Membrane.Opus.Parser{
        generate_best_effort_timestamps?: true,
        delimitation: :undelimit,
        input_delimitted?: false
      })
      |> child(:ogg_muxer, Membrane.Ogg.Muxer)
      |> child(:file_sink, %Membrane.File.Sink{location: location})
    end

    spec =
      StorageEndpoints.get_spec_for_single_track_output(:audio, track_builders, pipeline_tail)

    %Ready{actions: [spec: spec]}
  end
end
