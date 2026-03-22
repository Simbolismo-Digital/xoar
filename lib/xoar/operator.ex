defmodule Xoar.Operator do
  @moduledoc """
  An Operator — a proposed action in the decision cycle.

  Operators are proposed by Codelet processes during elaboration
  and resolved by the Decision Cycle's preference mechanism.

  The `source` field is the codelet MODULE that proposed it.
  When an operator wins, the DecisionCycle sends a message
  back to that codelet's process to apply it — no closures,
  pure message passing, true to the actor model.

  Soar preference semantics (simplified):
  - :acceptable  → this operator could work
  - :best        → this is the best option
  - :worst       → this is the worst option
  - :reject      → do NOT select this
  - :indifferent → no preference between this and others
  """

  @type preference :: :acceptable | :best | :worst | :reject | :indifferent

  @type t :: %__MODULE__{
          name: atom(),
          source: module(),
          preference: preference(),
          params: map()
        }

  defstruct [
    :name,
    :source,
    preference: :acceptable,
    params: %{}
  ]

  def new(name, source_module, opts \\ []) do
    %__MODULE__{
      name: name,
      source: source_module,
      preference: Keyword.get(opts, :preference, :acceptable),
      params: Keyword.get(opts, :params, %{})
    }
  end
end
