defmodule Boombox.MSR do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Logger
  alias Boombox.Pipeline.Ready

  @type input_location :: [
          {:video, {String.t(), transport: :file | :http}},
          {:audio, {String.t(), transport: :file | :http}}
        ]

  @type output_location :: [
          {:video, video_location :: String.t()},
          {:audio, audio_location :: String.t()}
        ]

  @spec create_input(input_location()) :: Ready.t()
  def create_input(location) do
    video_branch =
      case location[:video] do
        {video_location, transport: :file} ->
          child(:msr_video_in_file_source, %Membrane.File.Source{location: video_location})
          |> child(:msr_video_deserializer, Membrane.Stream.Deserializer)

        {video_location, transport: :http} ->
          child(:msr_video_in_http_source, %Membrane.Hackney.Source{
            location: video_location,
            hackney_opts: [follow_redirect: true]
          })
          |> child(:msr_video_deserializer, Membrane.Stream.Deserializer)

        nil ->
          nil
      end

    audio_branch =
      case location[:audio] do
        {audio_location, transport: :file} ->
          child(:msr_video_in_file_source, %Membrane.File.Source{location: audio_location})
          |> child(:msr_video_deserializer, Membrane.Stream.Deserializer)

        {audio_location, transport: :http} ->
          child(:msr_video_in_http_source, %Membrane.Hackney.Source{
            location: audio_location,
            hackney_opts: [follow_redirect: true]
          })
          |> child(:msr_video_deserializer, Membrane.Stream.Deserializer)

        nil ->
          nil
      end

    track_builders =
      if(video_branch, do: [video: video_branch], else: []) ++
        if audio_branch, do: [audio: audio_branch], else: []

    %Ready{track_builders: track_builders}
  end

  @spec link_output(
          output_location(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: {Ready.t(), [:video | :audio]}
  def link_output(location, track_builders, _spec_builder) do
    {:video, video_track_builder} =
      track_builders
      |> Enum.find({:video, nil}, fn
        {:video, _track_builder} -> true
        _other -> false
      end)

    {:audio, audio_track_builder} =
      track_builders
      |> Enum.find({:audio, nil}, fn
        {:audio, _track_builder} -> true
        _other -> false
      end)

    video_branch =
      cond do
        Keyword.has_key?(location, :video) and video_track_builder != nil ->
          video_track_builder
          |> child(:msr_video_serializer, Membrane.Stream.Serializer)
          |> child(:msr_video_file_sink, %Membrane.File.Sink{location: location[:video]})

        Keyword.has_key?(location, :video) ->
          Membrane.Logger.warning("You specified :video MSR output but there is no video track.")
          nil

        true ->
          nil
      end

    audio_branch =
      cond do
        Keyword.has_key?(location, :audio) and audio_track_builder != nil ->
          audio_track_builder
          |> child(:msr_audio_serializer, Membrane.Stream.Serializer)
          |> child(:msr_audio_file_sink, %Membrane.File.Sink{location: location[:audio]})

        Keyword.has_key?(location, :audio) ->
          Membrane.Logger.warning("You specified :audio MSR output but there is no audio track.")
          nil

        true ->
          nil
      end

    spec = [video_branch, audio_branch] |> Enum.reject(&(&1 == nil))
    tracks = (if video_branch, do: [:video], else: []) ++ (if audio_branch, do: [:audio], else: [])
    {%Ready{actions: [spec: spec]}, tracks}
  end
end
