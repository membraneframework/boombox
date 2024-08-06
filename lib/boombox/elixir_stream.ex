defmodule Boombox.ElixirStream do
  @moduledoc false

  import Membrane.ChildrenSpec
  alias Boombox.Pipeline.Ready

  @spec create_input(producer :: pid) :: Ready.t()
  def create_input(producer) do
    builders =
      %{
        video:
          child(%Source{producer: producer})
          |> child(%Membrane.FFmpeg.SWScale.Converter{format: :I420})
          |> child(Membrane.H264.FFmpeg.Encoder)
      }

    %Ready{track_builders: builders}
  end

  @spec link_output(
          consumer :: pid,
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(consumer, track_builders, spec_builder) do
    spec =
      [
        spec_builder,
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(Membrane.Debug.Sink)

          {:video, builder} ->
            builder
            |> child(%Membrane.H264.Parser{output_stream_structure: :annexb})
            |> child(Membrane.H264.FFmpeg.Decoder)
            |> child(%Membrane.FFmpeg.SWScale.Converter{format: :RGB})
            |> child(:elixir_stream_sink, %Sink{consumer: consumer})
        end)
      ]

    %Ready{actions: [spec: spec]}
  end
end
