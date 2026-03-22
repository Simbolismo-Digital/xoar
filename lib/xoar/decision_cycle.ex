defmodule Xoar.DecisionCycle do
  @moduledoc """
  The Decision Cycle — collects and decides.

  Codelets push proposals here. On its own tick, the
  DecisionCycle drains the buffer, resolves preferences,
  and sends :apply back to the winning codelet's PID.

  The DecisionCycle is the only component with a tick
  among the cognitive processes. This makes sense:
  Soar's decision cycle IS a clock — it defines the
  temporal granularity of deliberation. Codelets are
  reactive (event-driven), but decisions are periodic.
  """

  use GenServer
  require Logger

  alias Xoar.Operator

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Receive proposals from codelet processes."
  def propose(operators) when is_list(operators) do
    GenServer.cast(__MODULE__, {:proposals, operators})
  end

  def status, do: GenServer.call(__MODULE__, :status)
  def step, do: GenServer.call(__MODULE__, :step, 10_000)
  def pause, do: GenServer.cast(__MODULE__, :pause)
  def resume, do: GenServer.cast(__MODULE__, :resume)

  # ── GenServer ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :cycle_interval_ms, 100)
    auto_run = Keyword.get(opts, :auto_run, true)

    state = %{
      proposal_buffer: [],
      cycle_count: 0,
      cycle_interval_ms: interval,
      running: auto_run,
      last_decision: nil,
      impasse_count: 0
    }

    if auto_run, do: schedule_cycle(interval)

    Logger.info("[Xoar] Decision cycle started (interval: #{interval}ms)")
    {:ok, state}
  end

  @impl true
  def handle_cast({:proposals, operators}, state) do
    {:noreply, %{state | proposal_buffer: state.proposal_buffer ++ operators}}
  end

  @impl true
  def handle_cast(:pause, state) do
    Logger.info("[Xoar] Paused at cycle #{state.cycle_count}")
    {:noreply, %{state | running: false}}
  end

  @impl true
  def handle_cast(:resume, state) do
    schedule_cycle(state.cycle_interval_ms)
    {:noreply, %{state | running: true}}
  end

  @impl true
  def handle_info(:decide, %{running: false} = state), do: {:noreply, state}

  @impl true
  def handle_info(:decide, state) do
    {_result, new_state} = run_decision(state)
    schedule_cycle(state.cycle_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:step, _from, state) do
    # Give reactive codelets time to send proposals
    Process.sleep(state.cycle_interval_ms)
    {result, new_state} = run_decision(state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    info =
      state
      |> Map.take([:cycle_count, :running, :last_decision, :impasse_count])
      |> Map.put(:pending_proposals, length(state.proposal_buffer))

    {:reply, info, state}
  end

  # ── Decision ───────────────────────────────────────────────

  defp run_decision(%{proposal_buffer: []} = state) do
    new_state = %{
      state
      | cycle_count: state.cycle_count + 1,
        last_decision: :no_proposals,
        impasse_count: state.impasse_count + 1
    }

    {:no_proposals, new_state}
  end

  defp run_decision(state) do
    proposals = state.proposal_buffer

    case decide(proposals) do
      {:ok, winner} ->
        Logger.debug(
          "[Xoar] Cycle #{state.cycle_count}: #{winner.name} " <>
            "from #{inspect(winner.source)} (#{length(proposals)} in buffer)"
        )

        route_apply(winner)

        new_state = %{
          state
          | proposal_buffer: [],
            cycle_count: state.cycle_count + 1,
            last_decision: winner.name
        }

        {{:ok, winner.name}, new_state}

      :impasse ->
        Logger.debug("[Xoar] Cycle #{state.cycle_count}: IMPASSE")

        new_state = %{
          state
          | proposal_buffer: [],
            cycle_count: state.cycle_count + 1,
            last_decision: :impasse,
            impasse_count: state.impasse_count + 1
        }

        {:impasse, new_state}
    end
  end

  defp decide(proposals) do
    candidates =
      proposals
      |> Enum.reject(&(&1.preference == :reject))
      |> Enum.filter(&(&1.preference in [:acceptable, :best, :indifferent]))

    case candidates do
      [] ->
        :impasse

      [single] ->
        {:ok, single}

      multiple ->
        best = Enum.filter(multiple, &(&1.preference == :best))

        case best do
          [one] -> {:ok, one}
          [] -> {:ok, Enum.random(multiple)}
          _tie -> :impasse
        end
    end
  end

  defp route_apply(%Operator{source: source_module} = operator) do
    case source_module.pid() do
      nil -> Logger.warning("[Xoar] Cannot route: #{inspect(source_module)} not running")
      pid -> GenServer.cast(pid, {:apply_operator, operator})
    end
  end

  defp schedule_cycle(interval) do
    Process.send_after(self(), :decide, interval)
  end
end
