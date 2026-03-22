defmodule Xoar.WME do
  @moduledoc """
  Working Memory Element — the fundamental unit of cognitive state.

  In Soar, a WME is a triple: (identifier ^attribute value)
  In Xoar, it's a struct with native pattern matching.

  Example:
      Soar:   (S1 ^object ball ^color red)
      Xoar:   %WME{id: :s1, attribute: :color, value: :red}

  Pattern matching on WMEs is the Elixir equivalent of
  Soar's production rule LHS (left-hand side conditions).
  """

  @type t :: %__MODULE__{
          id: atom(),
          attribute: atom(),
          value: any(),
          timestamp: integer()
        }

  defstruct [:id, :attribute, :value, :timestamp]

  @doc "Create a new WME with automatic timestamp."
  def new(id, attribute, value) do
    %__MODULE__{
      id: id,
      attribute: attribute,
      value: value,
      timestamp: System.monotonic_time(:millisecond)
    }
  end
end
