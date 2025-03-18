defmodule Boombox.WAV do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Boombox.Pipeline.Ready

  @spec create_input(String.t(), transport: :file | :http) :: Ready.t()
  def create_input(location, opts) do
    spec =
      case opts[:transport] do
        :file ->
          child(:wav_in_file_source, %Membrane.File.Source{location: location})
          |> child(:aac_parser, Membrane.WAV.Parser)

        :http ->
          child(:wav_in_http_source, %Membrane.Hackney.Source{
            location: location,
            hackney_opts: [follow_redirect: true]
          })
          |> child(:aac_parser, Membrane.WAV.Parser)
      end

    %Ready{track_builders: [{:audio, spec}]}
  end

  @spec link_output(
          String.t(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, _spec_builder) do
    [{:audio, audio_track_builder}] =
      track_builders
      |> Enum.filter(fn
        {:audio, _track_builder} -> true
        _other -> false
      end)

    spec =
      audio_track_builder
      |> child(:aac_audio_transcoder, %Membrane.Transcoder{
        output_stream_format: Membrane.RawAudio
      })
      |> child(:aac_parser, Membrane.WAV.Serializer)
      |> child(:aac_file_sink, %Membrane.File.Sink{location: location})

    %Ready{actions: [spec: spec]}
  end
end
