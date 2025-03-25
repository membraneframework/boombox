defmodule Boombox.Utils do
  @moduledoc false
  require Logger
  require Membrane.Logger

  # @spec parse_options(input: Boombox.input, output: Boombox.output()) :: Boombox.opts_map()
  @spec parse_options(%{input: Boombox.input(), output: Boombox.output()}) :: Boombox.opts_map()
  def parse_options(options) do
    options
    |> Map.update!(:input, &parse_endpoint_opt!(:input, &1))
    |> Map.update!(:output, &parse_endpoint_opt!(:output, &1))
  end

  @spec parse_endpoint_opt!(:input, Boombox.input()) :: Boombox.input()
  @spec parse_endpoint_opt!(:output, Boombox.output()) :: Boombox.output()
  defp parse_endpoint_opt!(direction, value) when is_binary(value) do
    parse_endpoint_opt!(direction, {value, []})
  end

  defp parse_endpoint_opt!(direction, {value, opts}) when is_binary(value) do
    uri = URI.parse(value)
    scheme = uri.scheme
    extension = if uri.path, do: Path.extname(uri.path)

    case {scheme, extension, direction} do
      {scheme, ".mp4", :input} when scheme in [nil, "http", "https"] -> {:mp4, value, opts}
      {nil, ".mp4", :output} -> {:mp4, value, opts}
      {scheme, _ext, :input} when scheme in ["rtmp", "rtmps"] -> {:rtmp, value}
      {"rtsp", _ext, :input} -> {:rtsp, value}
      {nil, ".m3u8", :output} -> {:hls, value, opts}
      _other -> raise ArgumentError, "Unsupported URI: #{value} for direction: #{direction}"
    end
    |> then(&parse_endpoint_opt!(direction, &1))
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp parse_endpoint_opt!(direction, value) when is_tuple(value) or is_atom(value) do
    case value do
      {:mp4, location} when is_binary(location) and direction == :input ->
        parse_endpoint_opt!(:input, {:mp4, location, []})

      {:mp4, location, opts} when is_binary(location) and direction == :input ->
        opts = opts |> Keyword.put(:transport, resolve_transport(location, opts))
        {:mp4, location, opts}

      {:mp4, location} when is_binary(location) and direction == :output ->
        {:mp4, location, []}

      {:mp4, location, _opts} when is_binary(location) and direction == :output ->
        value

      {:webrtc, %Membrane.WebRTC.Signaling{}} when direction == :input ->
        value

      {:webrtc, %Membrane.WebRTC.Signaling{} = signaling} ->
        {:webrtc, signaling, []}

      {:webrtc, %Membrane.WebRTC.Signaling{}, _opts} when direction == :output ->
        value

      {:webrtc, uri} when is_binary(uri) and direction == :input ->
        value

      {:webrtc, uri} when is_binary(uri) and direction == :output ->
        {:webrtc, uri, []}

      {:webrtc, uri, _opts} when is_binary(uri) and direction == :output ->
        value

      {:whip, uri} when is_binary(uri) ->
        parse_endpoint_opt!(direction, {:whip, uri, []})

      {:whip, uri, opts} when is_binary(uri) and is_list(opts) and direction == :input ->
        if Keyword.keyword?(opts), do: {:webrtc, value}

      {:whip, uri, opts} when is_binary(uri) and is_list(opts) and direction == :output ->
        {webrtc_opts, whip_opts} = split_webrtc_and_whip_opts(opts)
        if Keyword.keyword?(opts), do: {:webrtc, {:whip, uri, whip_opts}, webrtc_opts}

      {:rtmp, arg} when direction == :input and (is_binary(arg) or is_pid(arg)) ->
        value

      {:hls, location} when direction == :output and is_binary(location) ->
        {:hls, location, []}

      {:hls, location, opts}
      when direction == :output and is_binary(location) and is_list(opts) ->
        value

      {:rtsp, location} when direction == :input and is_binary(location) ->
        value

      {:rtp, opts} ->
        if Keyword.keyword?(opts), do: value

      {:stream, opts} ->
        if Keyword.keyword?(opts), do: value

      :membrane_pad ->
        :membrane_pad

      _other ->
        nil
    end
    |> case do
      nil -> raise ArgumentError, "Invalid #{direction} specification: #{inspect(value)}"
      value -> value
    end
  end

  @spec resolve_transport(String.t(), [{:transport, :file | :http}]) :: :file | :http
  defp resolve_transport(location, opts) do
    case Keyword.validate!(opts, transport: nil, force_transcoding: false)[:transport] do
      nil ->
        uri = URI.parse(location)

        case uri.scheme do
          nil -> :file
          "http" -> :http
          "https" -> :http
          _other -> raise ArgumentError, "Unsupported URI: #{location}"
        end

      transport when transport in [:file, :http] ->
        transport

      transport ->
        raise ArgumentError, "Invalid transport: #{inspect(transport)}"
    end
  end

  defp split_webrtc_and_whip_opts(opts) do
    opts
    |> Enum.split_with(fn {key, _value} -> key == :force_transcoding end)
  end

  defguardp is_webrtc_endpoint(endpoint)
            when is_tuple(endpoint) and elem(endpoint, 0) in [:webrtc, :whip]

  @spec maybe_log_transcoding_related_warning(Boombox.opts_map(), Logger | Membrane.Logger) :: :ok
  def maybe_log_transcoding_related_warning(options, logger \\ Logger) do
    if is_webrtc_endpoint(options.output) and not is_webrtc_endpoint(options.input) and
         webrtc_output_force_transcoding(options) not in [true, :video] do
      warning_fn = fn ->
        """
        Boombox output protocol is WebRTC, while Boombox input doesn't support keyframe requests. This \
        might lead to issues with the output video if the output stream isn't sent only by localhost. You \
        can solve this by setting `:force_transcoding` output option to `true` or `:video`, but be aware \
        that it will increase Boombox CPU usage.
        """
      end

      case logger do
        Logger -> Logger.warning(warning_fn)
        Membrane.Logger -> Membrane.Logger.warning(warning_fn)
      end
    end

    :ok
  end

  defp webrtc_output_force_transcoding(%{output: {:webrtc, _singaling, opts}}),
    do: Keyword.get(opts, :force_transcoding)
end
