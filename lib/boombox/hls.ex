defmodule Boombox.HLS do
  @moduledoc false

  import Membrane.ChildrenSpec

  require Membrane.Pad, as: Pad
  alias Boombox.InternalBin.Ready
  alias Membrane.H264
  alias Membrane.Time

  @spec link_output(
          Path.t(),
          [Boombox.force_transcoding()],
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, opts, track_builders, spec_builder) do
    force_transcoding = opts |> Keyword.get(:force_transcoding, false)

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
          %Membrane.HTTPAdaptiveStream.SinkBin{
            manifest_name: manifest_name,
            manifest_module: Membrane.HTTPAdaptiveStream.HLS,
            storage: %Membrane.HTTPAdaptiveStream.Storages.FileStorage{
              directory: directory
            },
            hls_mode: hls_mode,
            mp4_parameters_in_band?: true,
            target_window_duration: Membrane.Time.seconds(20)
          }
        ),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:hls_audio_transcoder, %Membrane.Transcoder{
              output_stream_format: Membrane.AAC,
              force_transcoding?: force_transcoding in [true, :audio]
            })
            |> via_in(Pad.ref(:input, :audio),
              options: [encoding: :AAC, segment_duration: Time.milliseconds(2000)]
            )
            |> get_child(:hls_sink_bin)

          {:video, builder} ->
            builder
            |> child(:hls_video_transcoder, %Membrane.Transcoder{
              output_stream_format: %H264{alignment: :au, stream_structure: :avc3},
              force_transcoding?: force_transcoding in [true, :video]
            })
            |> via_in(Pad.ref(:input, :video),
              options: [encoding: :H264, segment_duration: Time.milliseconds(2000)]
            )
            |> get_child(:hls_sink_bin)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end
end
