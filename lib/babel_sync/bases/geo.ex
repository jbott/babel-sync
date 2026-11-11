defmodule BabelSync.Bases.Geo do
  @moduledoc """
  Coordinates as notes hold them, and the distance between two of them.

  A point is read from a `[latitude, longitude]` list, a `"latitude,
  longitude"` text, or a map with `lat`/`latitude` and
  `lng`/`lon`/`longitude` keys.
  """

  @earth_radius_km 6371.0088
  @latitudes ~w(lat latitude)
  @longitudes ~w(lng lon long longitude)

  @type point :: {float(), float()}

  @spec point(term()) :: point() | nil
  def point([latitude, longitude]), do: valid(number(latitude), number(longitude))

  def point(text) when is_binary(text) do
    case String.split(text, ",") do
      [latitude, longitude] -> valid(number(latitude), number(longitude))
      _other -> nil
    end
  end

  def point(%{} = map), do: valid(number(first(map, @latitudes)), number(first(map, @longitudes)))
  def point(_other), do: nil

  @spec of(map(), String.t() | nil) :: point() | nil
  def of(properties, nil) do
    point(properties["coordinates"]) || point(properties["location"]) || point(properties)
  end

  def of(properties, property), do: point(properties[property])

  @spec distance_km(point(), point()) :: float()
  def distance_km({latitude, longitude}, {other_latitude, other_longitude}) do
    [from, to, across] =
      Enum.map(
        [latitude, other_latitude, other_longitude - longitude],
        &(&1 * :math.pi() / 180)
      )

    half_chord =
      :math.pow(:math.sin((to - from) / 2), 2) +
        :math.cos(from) * :math.cos(to) * :math.pow(:math.sin(across / 2), 2)

    2 * @earth_radius_km * :math.asin(min(1.0, :math.sqrt(half_chord)))
  end

  defp first(map, keys), do: Enum.find_value(keys, &map[&1])

  defp number(value) when is_number(value), do: value * 1.0

  defp number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp number(_other), do: nil

  defp valid(latitude, longitude)
       when is_float(latitude) and is_float(longitude) and abs(latitude) <= 90 and
              abs(longitude) <= 180,
       do: {latitude, longitude}

  defp valid(_latitude, _longitude), do: nil
end
