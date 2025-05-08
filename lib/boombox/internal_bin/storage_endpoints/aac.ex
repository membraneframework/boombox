defmodule Boombox.InternalBin.StorageEndpoints.AAC do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.InternalBin.Ready
  alias Boombox.InternalBin.StorageEndpoints
  alias Membrane.AAC

  @behaviour Boombox.Endpoint

  # @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  @impl true
  def create_input({:aac, location, opts}, _ctx, state) do
    spec =
      StorageEndpoints.get_source(location, opts[:transport])
      |> child(:aac_input_parser, Membrane.AAC.Parser)

    {%Ready{track_builders: %{audio: spec}}, state}
  end

  # @spec link_output(
  #         String.t(),
  #         Boombox.InternalBin.track_builders(),
  #         Membrane.ChildrenSpec.t()
  #       ) :: Ready.t()
  @impl true
  def link_output({:aac, location, _opts}, track_builders, spec_builder, _ctx, state) do
    spec =
      track_builders[:audio]
      |> child(:aac_audio_transcoder, %Membrane.Transcoder{
        output_stream_format: AAC
      })
      |> child(:file_sink, %Membrane.File.Sink{location: location})

    {%Ready{actions: [spec: spec]}, state}
  end
end
