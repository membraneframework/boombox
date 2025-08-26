defmodule Boombox.InternalBin.HLS do
  @moduledoc false

  import Membrane.ChildrenSpec

  require Membrane.Pad, as: Pad
  alias Boombox.InternalBin.{Ready, Wait}
  alias Membrane.{AAC, H264, HTTPAdaptiveStream, RemoteStream, Time, Transcoder}

  @spec create_input(String.t(), [Boombox.hls_variant_selection_policy_opt()]) :: Wait.t()
  def create_input(url, opts) do
    variant_selection_policy = Keyword.get(opts, :variant_selection_policy, :highest_resolution)

    spec =
      child(:hls_source, %HTTPAdaptiveStream.Source{
        url: url,
        variant_selection_policy: variant_selection_policy
      })

    %Wait{actions: [spec: spec]}
  end

  @spec handle_input_tracks([{:audio_output | :video_output, struct()}]) :: Ready.t()
  def handle_input_tracks(tracks) do
    track_builders =
      tracks
      |> Map.new(fn
        {:audio_output, %RemoteStream{content_format: AAC}} ->
          spec =
            get_child(:hls_source)
            |> via_out(:audio_output)
            |> child(:hls_source_aac_parser, %AAC.Parser{out_encapsulation: :ADTS})

          {:audio, spec}

        {:audio_output, %AAC{}} ->
          spec = get_child(:hls_source) |> via_out(:audio_output)
          {:audio, spec}

        {:video_output, _video_format} ->
          spec = get_child(:hls_source) |> via_out(:video_output)
          {:video, spec}
      end)

    %Ready{track_builders: track_builders}
  end

  @spec link_output(
          Path.t(),
          [Boombox.transcoding_policy_opt() | Boombox.pacing_opt()],
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, opts, track_builders, spec_builder) do
    transcoding_policy = opts |> Keyword.get(:transcoding_policy, :if_needed)
    pacing = opts |> Keyword.get(:pacing, :timestamp_based)

    {directory, manifest_name} =
      if Path.extname(location) == ".m3u8" do
        {Path.dirname(location), Path.basename(location, ".m3u8")}
      else
        {location, "index"}
      end

    hls_mode =
      if Map.keys(track_builders) == [:video], do: :separate_av, else: :muxed_av

    spec =
      [
        spec_builder,
        child(
          :hls_sink_bin,
          %HTTPAdaptiveStream.SinkBin{
            manifest_name: manifest_name,
            manifest_module: HTTPAdaptiveStream.HLS,
            storage: %HTTPAdaptiveStream.Storages.FileStorage{
              directory: directory
            },
            hls_mode: hls_mode,
            mp4_parameters_in_band?: true,
            target_window_duration: Time.seconds(20)
          }
        ),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:hls_audio_transcoder, %Transcoder{
              output_stream_format: AAC,
              transcoding_policy: transcoding_policy
            })
            |> then(
              &case pacing do
                :as_fast_as_possible -> &1
                :timestamp_based -> child(&1, :hls_audio_realtimer, Membrane.Realtimer)
              end
            )
            |> via_in(Pad.ref(:input, :audio),
              options: [encoding: :AAC, segment_duration: Time.milliseconds(2000)]
            )
            |> get_child(:hls_sink_bin)

          {:video, builder} ->
            builder
            |> child(:hls_video_transcoder, %Transcoder{
              output_stream_format: %H264{alignment: :au, stream_structure: :avc3},
              transcoding_policy: transcoding_policy
            })
            |> then(
              &case pacing do
                :as_fast_as_possible -> &1
                :timestamp_based -> child(&1, :hls_video_realtimer, Membrane.Realtimer)
              end
            )
            |> via_in(Pad.ref(:input, :video),
              options: [encoding: :H264, segment_duration: Time.milliseconds(2000)]
            )
            |> get_child(:hls_sink_bin)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end
end
