defmodule Boombox.HLS do
  @moduledoc false

  import Membrane.ChildrenSpec

  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.Ready
  alias Membrane.Time

  @spec link_output(
          String.t(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, spec_builder) do
    spec =
      [
        spec_builder,
        child(
          :hls_sink_bin,
          %Membrane.HTTPAdaptiveStream.SinkBin{
            manifest_module: Membrane.HTTPAdaptiveStream.HLS,
            storage: %Membrane.HTTPAdaptiveStream.Storages.FileStorage{
              directory: location
            }
          }
        ),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(Membrane.AAC.FDK.Encoder)
            |> via_in(Pad.ref(:input, :audio),
              options: [encoding: :AAC, segment_duration: Time.milliseconds(2000)]
            )
            |> get_child(:hls_sink_bin)

          {:video, builder} ->
            builder
            |> via_in(Pad.ref(:input, :video),
              options: [encoding: :H264, segment_duration: Time.milliseconds(2000)]
            )
            |> get_child(:hls_sink_bin)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end
end
