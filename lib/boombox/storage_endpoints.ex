defmodule Boombox.StorageEndpoints do
  @moduledoc false
  import Membrane.ChildrenSpec
  alias Membrane.ChildrenSpec.Builder

  @spec get_source(String.t(), :file | :http, boolean()) :: Builder.t()
  def get_source(location, transport, seekable \\ false)

  def get_source(location, :file, seekable) do
    child(:file_source, %Membrane.File.Source{location: location, seekable?: seekable})
  end

  def get_source(location, :http, _seekable) do
    child(:http_source, %Membrane.Hackney.Source{
      location: location,
      hackney_opts: [follow_redirect: true]
    })
  end

  @spec get_track([{:audio | :video, Builder.t()}], :audio | :video) :: Builder.t()
  def get_track(track_builders, track_type) do
    maybe_track =
      track_builders
      |> Enum.find(fn
        {^track_type, _track_builder} -> true
        _other -> false
      end)

    case maybe_track do
      {^track_type, track_builder} -> track_builder
      nil -> nil
    end
  end
end
