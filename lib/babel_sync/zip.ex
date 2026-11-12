defmodule BabelSync.Zip do
  @moduledoc """
  Writes a ZIP archive as a stream, so a whole vault can be sent without
  holding it in memory or on disk.

  Files are stored uncompressed, since attachments are mostly already
  compressed and notes are small. Each file's CRC is worked out while
  its bytes go past and written after them, in a data descriptor. Files
  and archives past 4 GiB use the ZIP64 extensions. Erlang's `:zip`
  builds archives only in memory or from files on disk and has no
  ZIP64, so this is written here.
  """

  import Bitwise

  @max32 0xFFFFFFFF
  @max16 0xFFFF
  @utf8_and_descriptor 0x0808
  @version 45

  @type file :: {name :: String.t(), size :: non_neg_integer(), chunks :: Enumerable.t()}
  @type entry :: file() | {:folder, String.t()}

  @spec stream(Enumerable.t(), DateTime.t()) :: Enumerable.t()
  def stream(entries, at \\ DateTime.utc_now()) do
    {time, date} = dos(at)

    entries
    |> Stream.flat_map(&events/1)
    |> Stream.transform(
      fn -> %{offset: 0, central: [], current: nil, time: time, date: date} end,
      &write/2,
      &finish/1,
      fn _state -> :ok end
    )
  end

  defp events({:folder, name}),
    do: [{:start, String.trim_trailing(name, "/") <> "/", 0, :folder}, :end]

  defp events({name, size, chunks}) do
    Stream.concat([[{:start, name, size, :file}], Stream.map(chunks, &{:data, &1}), [:end]])
  end

  defp write({:start, name, size, type}, state) do
    zip64 = size >= @max32

    extra =
      if zip64,
        do: <<0x0001::16-little, 16::16-little, size::64-little, size::64-little>>,
        else: <<>>

    stored = if zip64, do: @max32, else: size

    header = [
      <<0x04034B50::32-little, @version::16-little, @utf8_and_descriptor::16-little, 0::16-little,
        state.time::16-little, state.date::16-little, 0::32-little, stored::32-little,
        stored::32-little, byte_size(name)::16-little, byte_size(extra)::16-little>>,
      name,
      extra
    ]

    current = %{
      name: name,
      size: size,
      type: type,
      zip64: zip64,
      offset: state.offset,
      crc: :erlang.crc32(<<>>),
      written: 0
    }

    {[header], %{state | current: current, offset: state.offset + IO.iodata_length(header)}}
  end

  defp write({:data, chunk}, %{current: current} = state) do
    current = %{
      current
      | crc: :erlang.crc32(current.crc, chunk),
        written: current.written + IO.iodata_length(chunk)
    }

    {[chunk], %{state | current: current, offset: state.offset + IO.iodata_length(chunk)}}
  end

  defp write(:end, %{current: %{written: written, size: size, name: name}})
       when written != size do
    raise ArgumentError, "#{name} was said to be #{size} bytes but #{written} were given"
  end

  defp write(:end, %{current: current} = state) do
    sizes =
      if current.zip64,
        do: <<current.size::64-little, current.size::64-little>>,
        else: <<current.size::32-little, current.size::32-little>>

    descriptor = <<0x08074B50::32-little, current.crc::32-little, sizes::binary>>

    {[descriptor],
     %{
       state
       | current: nil,
         central: [current | state.central],
         offset: state.offset + byte_size(descriptor)
     }}
  end

  defp finish(%{central: central, offset: start} = state) do
    records = central |> Enum.reverse() |> Enum.map(&record(&1, state))
    size = IO.iodata_length(records)
    count = length(central)
    zip64 = count >= @max16 or size >= @max32 or start >= @max32

    tail =
      if zip64 do
        located = start + size

        [
          <<0x06064B50::32-little, 44::64-little, @version::16-little, @version::16-little, 0::32,
            0::32, count::64-little, count::64-little, size::64-little, start::64-little>>,
          <<0x07064B50::32-little, 0::32, located::64-little, 1::32-little>>,
          <<0x06054B50::32-little, 0::16, 0::16, @max16::16-little, @max16::16-little,
            @max32::32-little, @max32::32-little, 0::16>>
        ]
      else
        [
          <<0x06054B50::32-little, 0::16, 0::16, count::16-little, count::16-little,
            size::32-little, start::32-little, 0::16>>
        ]
      end

    {[records, tail], state}
  end

  defp record(file, state) do
    big = file.size >= @max32
    far = file.offset >= @max32

    extra_fields =
      if(big, do: <<file.size::64-little, file.size::64-little>>, else: <<>>) <>
        if(far, do: <<file.offset::64-little>>, else: <<>>)

    extra =
      if extra_fields == <<>>,
        do: <<>>,
        else: <<0x0001::16-little, byte_size(extra_fields)::16-little, extra_fields::binary>>

    stored = if big, do: @max32, else: file.size
    offset = if far, do: @max32, else: file.offset
    mode = if file.type == :folder, do: 0o40755, else: 0o100644
    dos_attributes = if file.type == :folder, do: 0x10, else: 0

    [
      <<0x02014B50::32-little, 3 <<< 8 ||| @version::16-little, @version::16-little,
        @utf8_and_descriptor::16-little, 0::16-little, state.time::16-little,
        state.date::16-little, file.crc::32-little, stored::32-little, stored::32-little,
        byte_size(file.name)::16-little, byte_size(extra)::16-little, 0::16, 0::16, 0::16,
        mode <<< 16 ||| dos_attributes::32-little, offset::32-little>>,
      file.name,
      extra
    ]
  end

  defp dos(%DateTime{} = at) do
    time = at.hour <<< 11 ||| at.minute <<< 5 ||| div(at.second, 2)
    date = (max(at.year, 1980) - 1980) <<< 9 ||| at.month <<< 5 ||| at.day
    {time, date}
  end
end
