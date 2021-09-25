defmodule Bandit.HTTP2.Frame.Headers do
  @moduledoc false

  import Bitwise

  alias Bandit.HTTP2.{Connection, Errors, Frame, Stream}

  defstruct stream_id: nil,
            end_stream: false,
            end_headers: false,
            exclusive_dependency: false,
            stream_dependency: nil,
            weight: nil,
            fragment: nil

  @typedoc "An HTTP/2 HEADERS frame"
  @type t :: %__MODULE__{
          stream_id: Stream.stream_id(),
          end_stream: boolean(),
          end_headers: boolean(),
          exclusive_dependency: boolean(),
          stream_dependency: Stream.stream_id() | nil,
          weight: non_neg_integer() | nil,
          fragment: iodata()
        }

  @spec deserialize(Frame.flags(), Stream.stream_id(), iodata()) ::
          {:ok, t()} | {:error, Connection.error()}

  def deserialize(_flags, 0, _payload) do
    {:error,
     {:connection, Errors.protocol_error(), "HEADERS frame with zero stream_id (RFC7540§6.2)"}}
  end

  # Padding and priority
  def deserialize(
        flags,
        stream_id,
        <<padding_length::8, exclusive_dependency::1, stream_dependency::31, weight::8,
          rest::binary>>
      )
      when (flags &&& 0x28) == 0x28 and byte_size(rest) >= padding_length do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: (flags &&& 0x01) == 0x01,
       end_headers: (flags &&& 0x04) == 0x04,
       exclusive_dependency: exclusive_dependency == 0x01,
       stream_dependency: stream_dependency,
       weight: weight,
       fragment: binary_part(rest, 0, byte_size(rest) - padding_length)
     }}
  end

  # Padding but not priority
  def deserialize(flags, stream_id, <<padding_length::8, rest::binary>>)
      when (flags &&& 0x28) == 0x08 and byte_size(rest) >= padding_length do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: (flags &&& 0x01) == 0x01,
       end_headers: (flags &&& 0x04) == 0x04,
       fragment: binary_part(rest, 0, byte_size(rest) - padding_length)
     }}
  end

  # Priority but not padding
  def deserialize(
        flags,
        stream_id,
        <<exclusive_dependency::1, stream_dependency::31, weight::8, fragment::binary>>
      )
      when (flags &&& 0x28) == 0x20 do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: (flags &&& 0x01) == 0x01,
       end_headers: (flags &&& 0x04) == 0x04,
       exclusive_dependency: exclusive_dependency == 0x01,
       stream_dependency: stream_dependency,
       weight: weight,
       fragment: fragment
     }}
  end

  # Neither padding nor priority
  def deserialize(flags, stream_id, <<fragment::binary>>)
      when (flags &&& 0x28) == 0x00 do
    {:ok,
     %__MODULE__{
       stream_id: stream_id,
       end_stream: (flags &&& 0x01) == 0x01,
       end_headers: (flags &&& 0x04) == 0x04,
       fragment: fragment
     }}
  end

  def deserialize(
        flags,
        _stream_id,
        <<_padding_length::8, _exclusive_dependency::1, _stream_dependency::31, _weight::8,
          _rest::binary>>
      )
      when (flags &&& 0x28) == 0x28 do
    {:error,
     {:connection, Errors.protocol_error(),
      "HEADERS frame with invalid padding length (RFC7540§6.2)"}}
  end

  def deserialize(flags, _stream_id, <<_padding_length::8, _rest::binary>>)
      when (flags &&& 0x28) == 0x08 do
    {:error,
     {:connection, Errors.protocol_error(),
      "HEADERS frame with invalid padding length (RFC7540§6.2)"}}
  end

  defimpl Frame.Serializable do
    alias Bandit.HTTP2.Frame.{Continuation, Headers}

    def serialize(
          %Headers{exclusive_dependency: false, stream_dependency: nil, weight: nil} = frame,
          max_frame_size
        ) do
      flags = if frame.end_stream, do: 0x01, else: 0x00

      fragment_length = IO.iodata_length(frame.fragment)

      if fragment_length <= max_frame_size do
        [{0x1, flags ||| 0x04, frame.stream_id, frame.fragment}]
      else
        <<this_frame::binary-size(max_frame_size), rest::binary>> =
          IO.iodata_to_binary(frame.fragment)

        [
          {0x1, flags, frame.stream_id, this_frame}
          | Frame.Serializable.serialize(
              %Continuation{
                stream_id: frame.stream_id,
                fragment: rest
              },
              max_frame_size
            )
        ]
      end
    end
  end
end
