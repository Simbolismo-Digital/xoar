defmodule Xoar.Demo do
  @moduledoc """
  Interactive demo.

      $ cd xoar && iex -S mix
      iex> Xoar.Demo.run()

  ## Step by step

      iex> Xoar.Demo.setup()
      iex> Xoar.Demo.step()
      iex> Xoar.Demo.processes()    # see modes: sensor vs reactive
      iex> Xoar.Demo.introspect()   # see tick counts vs reaction counts

  ## Fault tolerance

      iex> Xoar.Demo.kill(Xoar.Codelets.Navigation)
      iex> Xoar.Demo.processes()
  """

  alias Xoar.{Workspace, WME, DecisionCycle}
  alias Xoar.Codelets.{Perception, Navigation, ObstacleAvoidance}

  @codelets [Perception, Navigation, ObstacleAvoidance]

  def setup(start \\ {0, 0}, target \\ {8, 8}) do
    Workspace.put(:perception, WME.new(:drone, :position, start))
    Workspace.put(:perception, WME.new(:drone, :target, target))
    Workspace.put(:perception, WME.new(:drone, :battery, 100))

    w = 55
    drone_line = "  Drone: #{inspect(start)}  Target: #{inspect(target)}"

    IO.puts("""

    ╔═══════════════════════════════════════════════════════╗
    ║               XOAR — Drone Demo                       ║
    ╠═══════════════════════════════════════════════════════╣
    ║#{String.pad_trailing(drone_line, w)}║
    ║  Obstacles: {3,3} {5,2} {7,7} {4,6}                   ║
    ╠═══════════════════════════════════════════════════════╣
    ║  HYBRID MODEL                                         ║
    ║                                                       ║
    ║  Perception   SENSOR    tick 40ms  (reads hardware)   ║
    ║  Navigation   REACTIVE  no tick    (wakes on change)  ║
    ║  Avoidance    REACTIVE  no tick    (wakes on change)  ║
    ║  DecisionCycle          tick 100ms (decides)          ║
    ║                                                       ║
    ║  Perception writes ETS → broadcast → Navigation and   ║
    ║  Avoidance wake up → propose → DecisionCycle collects ║
    ╠═══════════════════════════════════════════════════════╣
    ║  Xoar.Demo.step()       → one decision                ║
    ║  Xoar.Demo.run()        → auto-run to target          ║
    ║  Xoar.Demo.processes()  → PIDs and modes              ║
    ║  Xoar.Demo.introspect() → codelet private states      ║
    ║  Xoar.Demo.state()      → workspace                   ║
    ╚═══════════════════════════════════════════════════════╝
    """)

    :ok
  end

  def step do
    before = get_position()
    result = DecisionCycle.step()
    after_pos = get_position()
    status = DecisionCycle.status()

    decision =
      case result do
        {:ok, name} -> name
        other -> other
      end

    IO.puts(
      "[Cycle #{status.cycle_count}] " <>
        "#{inspect(before)} → #{inspect(after_pos)} " <>
        "(decision: #{inspect(decision)})"
    )

    case Workspace.get(:perception, :drone, :target) do
      %WME{value: ^after_pos} -> IO.puts("\n  ✓ ARRIVED AT TARGET!\n")
      _ -> :ok
    end

    result
  end

  def run(max_cycles \\ 50) do
    setup()

    target =
      case Workspace.get(:perception, :drone, :target) do
        %WME{value: t} -> t
        _ -> {8, 8}
      end

    IO.puts("Running...\n")

    Enum.reduce_while(1..max_cycles, nil, fn _i, _acc ->
      if get_position() == target do
        IO.puts("\n✓ Target reached in #{DecisionCycle.status().cycle_count} cycles!")
        {:halt, :arrived}
      else
        step()
        {:cont, nil}
      end
    end)
  end

  def processes do
    IO.puts("\n── Codelet Processes ──")

    @codelets
    |> Enum.each(fn module ->
      name = module |> Module.split() |> List.last()

      case module.pid() do
        nil ->
          IO.puts("  #{name}  NOT RUNNING")

        pid ->
          info = Process.info(pid, [:memory, :reductions])
          state = module.get_state()

          mode_str =
            case state.mode do
              :sensor -> "SENSOR   tick=#{state.tick_ms}ms  ticks=#{state.tick_count}"
              :reactive -> "REACTIVE reactions=#{state.reactions} skipped=#{state.skipped}"
            end

          IO.puts(
            "  #{String.pad_trailing(name, 22)}" <>
              "pid=#{inspect(pid)}  " <>
              "#{mode_str}  " <>
              "proposals=#{state.proposals_sent}  " <>
              "mem=#{info[:memory]}b"
          )
      end
    end)

    IO.puts("")
    :ok
  end

  def introspect do
    IO.puts("\n── Codelet Private States ──")

    @codelets
    |> Enum.each(fn module ->
      name = module |> Module.split() |> List.last()

      try do
        state = module.get_state()

        mode_info =
          case state.mode do
            :sensor -> "(sensor, #{state.tick_count} ticks)"
            :reactive -> "(reactive, #{state.reactions} reactions, #{state.skipped} skipped)"
          end

        IO.puts("  #{name} #{mode_info}:")

        state.codelet_state
        |> Enum.each(fn {k, v} ->
          IO.puts("    #{k}: #{inspect(v)}")
        end)
      rescue
        _ -> IO.puts("  #{name}: unavailable")
      end
    end)

    IO.puts("")
    :ok
  end

  def state do
    IO.puts("\n── Perception Workspace ──")

    Workspace.dump(:perception)
    |> Enum.each(fn wme ->
      IO.puts("  #{wme.id}.#{wme.attribute} = #{inspect(wme.value)}")
    end)

    IO.puts("\n── Episodic Memory (last 5) ──")

    Workspace.dump(:episodic)
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(5)
    |> Enum.each(fn wme ->
      case wme.value do
        %{from: from, to: to, source: src} ->
          IO.puts("  #{inspect(from)} → #{inspect(to)}  (#{src})")

        _ ->
          IO.puts("  #{inspect(wme.value)}")
      end
    end)

    IO.puts("")
    :ok
  end

  def kill(module) do
    name = module |> Module.split() |> List.last()

    case module.pid() do
      nil ->
        IO.puts("#{name} is not running")

      pid ->
        IO.puts("Killing #{name} (#{inspect(pid)})...")
        Process.exit(pid, :kill)
        Process.sleep(200)

        case module.pid() do
          nil -> IO.puts("⚠ Not yet restarted")
          new_pid -> IO.puts("✓ OTP restarted as #{inspect(new_pid)}")
        end
    end
  end

  defp get_position do
    case Workspace.get(:perception, :drone, :position) do
      %WME{value: pos} -> pos
      nil -> :unknown
    end
  end
end
