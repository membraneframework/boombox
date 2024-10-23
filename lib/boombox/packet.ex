defmodule Boombox.Packet do
  @moduledoc """
  Data structure emitted and accepted by `Boombox.run/1`
  when using `:stream` input or output.
  """

  @typedoc @moduledoc
  @type t :: %__MODULE__{
          payload: payload(),
          pts: Membrane.Time.t(),
          kind: :audio | :video,
          format: format()
        }

  @type payload :: Vix.Vips.Image.t() | binary()
  @type format ::
          %{}
          | %{
              audio_format: Membrane.RawAudio.SampleFormat.t(),
              audio_rate: pos_integer(),
              audio_channels: pos_integer()
            }

  @enforce_keys [:payload, :kind]
  defstruct @enforce_keys ++ [pts: nil, format: %{}]

  @spec update_payload(t(), (payload() -> payload())) :: t()
  def update_payload(packet, fun) do
    %__MODULE__{packet | payload: fun.(packet.payload)}
  end
end
