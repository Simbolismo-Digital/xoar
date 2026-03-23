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

  @doc """
  Default log_format to project
  """
  def log_format(level, message, _timestamp, metadata) do
    n = node()

    case {level, metadata[:pid], metadata[:file], metadata[:line]} do
      {"", p, f, l} when is_pid(p) and is_list(f) and is_integer(l) ->
        "[#{level}] #{n} pid=#{inspect(p)} #{f}:#{l} #{message}\n"

      _ ->
        "[#{level}] #{n} #{message}\n"
    end
  end

  def silence(tags),
    do:
      :logger.add_primary_filter(:xoar_filter, {
        fn
          %{meta: %{xoar: t}}, blocked -> if t in blocked, do: :stop, else: :ignore
          _, _ -> :ignore
        end,
        List.wrap(tags)
      })

  def unsilence, do: :logger.remove_primary_filter(:xoar_filter)
end
