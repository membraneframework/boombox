defmodule Boombox.HLS do
  @moduledoc false

  import Membrane.ChildrenSpec

  require Membrane.Pad, as: Pad

  alias Boombox.Pipeline.Ready
  alias Membrane.{HTTPAdaptiveStream, Time}

  defmodule HTTPUploader do
    @moduledoc false
    use GenServer

    require Logger

    alias Membrane.HTTPAdaptiveStream.Storages.GenServerStorage

    @impl true
    def init(config) do
      {:ok, config}
    end

    @impl true
    def handle_call(
          {GenServerStorage, :store, %{context: %{type: :partial_segment}}},
          _from,
          state
        ) do
      Logger.warning("LL-HLS is not supported. The partial segment is omitted.")
      {:reply, :ok, state}
    end

    @impl true
    def handle_call({GenServerStorage, :store, params}, _from, state) do
      location = Path.join(state.directory, params.name)

      reply =
        case :hackney.request(:post, location, [], params.contents, follow_redirect: true) do
          {:ok, status, _headers, _ref} when status in 200..299 ->
            :ok

          {:ok, status, _headers, ref} ->
            {:ok, body} = :hackney.body(ref)
            {:error, "POST failed with status code #{status}: #{body}"}

          error ->
            error
        end

      {:reply, reply, state}
    end

    @impl true
    def handle_call({GenServerStorage, :remove, params}, _from, state) do
      location = Path.join(state.directory, params.name)

      reply =
        case :hackney.request(:delete, location, [], <<>>, follow_redirect: true) do
          {:ok, status, _headers, _ref} when status in 200..299 ->
            :ok

          {:ok, status, _headers, ref} ->
            {:ok, body} = :hackney.body(ref)
            {:error, "DELETE failed with status code #{status}: #{body}"}

          error ->
            error
        end

      {:reply, reply, state}
    end
  end

  @spec link_output(
          Path.t(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t(),
          transport: :file | :http
        ) :: Ready.t()
  def link_output(location, track_builders, spec_builder, opts) do
    {directory, manifest_name} =
      if Path.extname(location) == ".m3u8" do
        {Path.dirname(location), Path.basename(location, ".m3u8")}
      else
        {location, "index"}
      end

    storage =
      case opts[:transport] do
        :file ->
          %HTTPAdaptiveStream.Storages.FileStorage{directory: directory}

        :http ->
          {:ok, uploader} = GenServer.start_link(HTTPUploader, %{directory: directory})
          %HTTPAdaptiveStream.Storages.GenServerStorage{destination: uploader}
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
            storage: storage,
            hls_mode: hls_mode
          }
        ),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:hls_out_aac_encoder, Membrane.AAC.FDK.Encoder)
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
