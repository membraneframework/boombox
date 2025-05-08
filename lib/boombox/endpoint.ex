defmodule Boombox.Endpoint do
  @moduledoc false

  alias Boombox.Endpoints.{
    AAC,
    ElixirStream,
    H264,
    H265,
    HLS,
    IVF,
    MP3,
    MP4,
    Ogg,
    Pad,
    RTMP,
    RTP,
    RTSP,
    WAV,
    WebRTC
  }

  alias Boombox.InternalBin

  defmodule Ready do
    @moduledoc false

    @type t :: %__MODULE__{
            actions: [Membrane.Bin.Action.t()],
            track_builders: InternalBin.track_builders() | nil,
            spec_builder: Membrane.ChildrenSpec.t() | nil,
            eos_info: term
          }

    defstruct actions: [], track_builders: nil, spec_builder: [], eos_info: nil
  end

  defmodule Wait do
    @moduledoc false

    @type t :: %__MODULE__{actions: [Membrane.Bin.Action.t()]}
    defstruct actions: []
  end

  @type ready_or_wait :: Ready.t() | Wait.t()

  @type endpoint_module ::
          AAC
          | ElixirStream
          | H264
          | H265
          | HLS
          | IVF
          | MP3
          | MP4
          | Ogg
          | Pad
          | RTMP
          | RTP
          | RTSP
          | WAV
          | WebRTC

  @callback has_child?(Membrane.Child.name(), :input | :output) :: boolean()

  @callback endpoint_option?(InternalBin.input() | InternalBin.output()) ::
              boolean()

  @callback handle_child_notification(
              notification :: any(),
              child_name :: Membrane.ChildrenSpec.child_name(),
              ctx :: Membrane.Bin.CallbackContext.t(),
              state :: InternalBin.State.t()
            ) :: {ready_or_wait(), InternalBin.State.t()}

  @callback create_input(
              InternalBin.input(),
              Membrane.Bin.CallbackContext.t(),
              InternalBin.State.t()
            ) ::
              {ready_or_wait(), InternalBin.State.t()}

  @callback create_output(
              InternalBin.output(),
              Membrane.Bin.CallbackContext.t(),
              InternalBin.State.t()
            ) ::
              {ready_or_wait(), InternalBin.State.t()}

  @callback link_output(
              InternalBin.input() | InternalBin.output(),
              track_builders :: InternalBin.track_builders(),
              spec_builder :: Membrane.ChildrenSpec.t(),
              Membrane.Bin.CallbackContext.t(),
              InternalBin.State.t()
            ) :: {ready_or_wait(), InternalBin.State.t()}

  @spec get_option_endpoint!(InternalBin.input() | InternalBin.output()) :: endpoint_module()
  def get_option_endpoint!(option) do
    endpoints()
    |> Enum.find(fn module -> module.endpoint_option?(option) end)
    |> case do
      nil -> raise "No endpoint found for option #{inspect(option)}"
      module -> module
    end
  end

  @spec get_child_endpoint(Membrane.Child.name()) :: endpoint_module()
  def get_child_endpoint(child_name, state) do
    cond do
      state.input_endpoint.has_child?(child_name, :input) ->
        {:ok, state.input_endpoint}

      state.output_endpoint.has_child?(child_name, :output) ->
        {:ok, state.output_endpoint}

      true ->
        :error
    end
  end

  defp endpoints() do
    [
      ElixirStream,
      AAC,
      H264,
      H265,
      IVF,
      MP3,
      MP4,
      Ogg,
      WAV,
      HLS,
      RTMP,
      RTP,
      RTSP,
      WebRTC,
      Pad
    ]
  end

  @optional_callbacks [
    has_child?: 2,
    endpoint_option?: 1,
    handle_child_notification: 4,
    create_input: 3,
    create_output: 3,
    link_output: 5
  ]
end
