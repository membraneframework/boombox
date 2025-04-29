defmodule Boombox.InternalBin.StorageEndpoints do
  @moduledoc false
  import Membrane.ChildrenSpec

  defguard is_storage_endpoint_type(endpoint_type)
           when endpoint_type in [:mp4, :h264, :h265, :aac, :wav, :mp3, :ivf, :ogg]

  defguard is_storage_endpoint_extension(extension)
           when extension in [".mp4", ".h264", ".h265", ".aac", ".wav", ".mp3", ".ivf", ".ogg"]

  @spec get_storage_endpoint_type!(String.t()) :: atom() | no_return()
  def get_storage_endpoint_type!("." <> type) do
    String.to_existing_atom(type)
  end

  @spec get_source(String.t(), :file | :http, boolean()) :: Membrane.ChildrenSpec.builder()
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
end
