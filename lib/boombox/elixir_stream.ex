defmodule Boombox.ElixirStream do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.Ready

  @spec create_input(producer :: pid) :: Ready.t()
  def create_input(producer) do
    builders =
      %{
        video:
          get_child(:elixir_stream_source)
          |> via_out(Pad.ref(:output, :video))
          |> child(%Membrane.FFmpeg.SWScale.Converter{format: :I420})
          |> child(Membrane.H264.FFmpeg.Encoder),
        audio:
          get_child(:elixir_stream_source)
          |> via_out(Pad.ref(:output, :audio))
      }

    spec_builder = child(:elixir_stream_source, %Source{producer: producer})

    %Ready{track_builders: builders, spec_builder: spec_builder}
  end

  @spec link_output(
          consumer :: pid,
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(consumer, track_builders, spec_builder) do
    dbg(track_builders)

    spec =
      [
        spec_builder,
        child(:elixir_stream_sink, %Sink{consumer: consumer}),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> via_in(Pad.ref(:input, :audio))
            |> get_child(:elixir_stream_sink)

          {:video, builder} ->
            builder
            |> child(%Membrane.H264.Parser{output_stream_structure: :annexb})
            |> child(Membrane.H264.FFmpeg.Decoder)
            |> child(%Membrane.FFmpeg.SWScale.Converter{format: :RGB})
            |> via_in(Pad.ref(:input, :video))
            |> get_child(:elixir_stream_sink)
        end)
      ]

    %Ready{actions: [spec: spec], eos_info: Map.keys(track_builders)}
  end
end
