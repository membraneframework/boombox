defmodule Boombox.InternalBin.StorageEndpoints.Ogg do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Logger

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
          [Boombox.transcoding_policy_opt()],
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, opts, track_builders, _spec_builder) do
    transcoding_policy = opts |> Keyword.get(:transcoding_policy, :if_needed)

    pipeline_tail = fn builder ->
      builder
      |> child(:ogg_audio_transcoder, %Membrane.Transcoder{
        output_stream_format: Membrane.Opus,
        transcoding_policy: transcoding_policy
      })
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

  # defp foo() do
  # audio_spec =
  # case track_builders do
  # %{audio: audio_track_builder} ->
  # [
  # audio_track_builder
  # |> child(:ogg_audio_transcoder, %Membrane.Transcoder{
  # output_stream_format: Membrane.Opus,
  # transcoding_policy: transcoding_policy
  # })
  # |> child(:parser, %Membrane.Opus.Parser{
  # generate_best_effort_timestamps?: true,
  # delimitation: :undelimit,
  # input_delimitted?: false
  # })
  # |> child(:ogg_muxer, Membrane.Ogg.Muxer)
  # |> child(:file_sink, %Membrane.File.Sink{location: location})
  # ]

  # _no_audio_track ->
  # raise "Output endpoint supports only audio, but no audio track is present"
  # end

  # video_spec =
  # case track_builders do
  # %{video: video_track_builder} ->
  # Logger.warning("Output endpoint supports only audio, discarding video track")

  # [
  # video_track_builder
  # |> child(:video_fake_sink, Membrane.Fake.Sink)
  # ]

  # _no_video_track ->
  # []
  # end
  # end
end
