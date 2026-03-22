defmodule Xoar do
  @moduledoc """
  Xoar — A Cognitive Architecture for Autonomous Drone Systems.

  Built on Elixir/OTP. Inspired by Soar, Clarion, and CST.

  ## Core concepts

  | Cognitive Concept     | Xoar Implementation              |
  |-----------------------|----------------------------------|
  | Working Memory (WME)  | `Xoar.WME` structs in ETS       |
  | Global Workspace      | `Xoar.Workspace` (ETS + PubSub) |
  | GWT Broadcast         | Registry dispatch on write       |
  | Production Rules      | Pattern matching in Codelets     |
  | Sensor Codelets       | GenServer with tick (hardware)   |
  | Cognitive Codelets    | GenServer reactive (subscribes)  |
  | Decision Cycle        | `Xoar.DecisionCycle`             |
  | Operator Preferences  | `Xoar.Operator` structs          |
  | Fault Tolerance       | OTP Supervision trees            |
  | Distribution          | Erlang clustering (future)       |

  ## Quick start

      iex -S mix
      iex> Xoar.Demo.run()
  """
end
