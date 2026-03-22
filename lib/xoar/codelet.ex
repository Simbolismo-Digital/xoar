defmodule Xoar.Codelet do
  @moduledoc """
  Behaviour + GenServer for Xoar Codelets.

  Two modes — matching the hybrid nature of cognitive systems:

  ## Sensor mode (tick)

      use Xoar.Codelet, tick_ms: 40

  For codelets that interface with hardware: cameras, GPS, LIDAR,
  motor controllers. Hardware has its own rhythm — you poll it.
  The codelet wakes up every N ms, reads sensors, writes to ETS.

  ## Reactive mode (subscribe)

      use Xoar.Codelet, subscribe_to: [:perception]

  For cognitive codelets: navigation, attention, obstacle avoidance,
  learning. These react to workspace changes via PubSub.
  They sleep until their mailbox gets a {:wme_changed, ...} message.
  No tick. No polling. Pure GWT broadcast semantics.

      ┌─────────────┐                         ┌──────────────┐
      │ Perception  │── writes WME to ETS ──▶ │   Workspace  │
      │ (tick 40ms) │                         │  (ETS+PubSub)│
      └─────────────┘                         └──────┬───────┘
                                                      │
                                          broadcast {:wme_changed}
                                                      │
                                    ┌─────────────────┼─────────────────┐
                                    ▼                                   ▼
                             ┌─────────────┐                     ┌─────────────┐
                             │ Navigation  │                     │  Avoidance  │
                             │ (reactive)  │                     │  (reactive) │
                             │  wakes up!  │                     │  wakes up!  │
                             └──────┬──────┘                     └──────┬──────┘
                                    │                                   │
                              :propose                            :propose
                                    │                                   │
                                    ▼                                   ▼
                             ┌──────────────────────────────────────────┐
                             │           DecisionCycle                  │
                             │        (collects, decides)               │
                             └──────────────────────────────────────────┘

  Both modes implement the same callback: `perceive_and_propose/1`.
  The difference is what triggers it.
  """

  @doc "Return initial codelet-local state."
  @callback init_state(opts :: keyword()) :: term()

  @doc """
  Read the workspace and propose operators.

  - In sensor mode: called every tick
  - In reactive mode: called when a subscribed workspace table changes

  Returns {operators, new_state}.
  """
  @callback perceive_and_propose(state :: term()) ::
              {[Xoar.Operator.t()], new_state :: term()}

  @doc "Handle an apply message from the DecisionCycle."
  @callback handle_apply(Xoar.Operator.t(), state :: term()) ::
              {:ok | {:error, term()}, new_state :: term()}

  defmacro __using__(opts) do
    tick_ms = Keyword.get(opts, :tick_ms, nil)
    subscribe_to = Keyword.get(opts, :subscribe_to, [])

    mode =
      cond do
        tick_ms != nil -> :sensor
        subscribe_to != [] -> :reactive
        true -> raise "use Xoar.Codelet requires either tick_ms: N or subscribe_to: [tables]"
      end

    quote do
      @behaviour Xoar.Codelet
      use GenServer

      @codelet_mode unquote(mode)
      @codelet_tick_ms unquote(tick_ms)
      @codelet_subscriptions unquote(subscribe_to)

      # ── Lifecycle ──────────────────────────────────────

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: via())
      end

      def child_spec(opts) do
        %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
      end

      def get_state, do: GenServer.call(via(), :get_state)

      def pid do
        case Registry.lookup(Xoar.CodeletRegistry, __MODULE__) do
          [{pid, _}] -> pid
          [] -> nil
        end
      end

      # ── Init ───────────────────────────────────────────

      @impl GenServer
      def init(opts) do
        state = %{
          module: __MODULE__,
          mode: @codelet_mode,
          tick_ms: @codelet_tick_ms,
          subscriptions: @codelet_subscriptions,
          codelet_state: init_state(opts),
          tick_count: 0,
          reactions: 0,
          proposals_sent: 0
        }

        case @codelet_mode do
          :sensor ->
            schedule_tick(@codelet_tick_ms)

          :reactive ->
            Enum.each(@codelet_subscriptions, fn table ->
              Xoar.Workspace.subscribe(table)
            end)
        end

        {:ok, state}
      end

      # ── Sensor mode: tick ──────────────────────────────

      @impl GenServer
      def handle_info(:tick, %{mode: :sensor} = state) do
        {operators, new_codelet_state} = perceive_and_propose(state.codelet_state)

        if operators != [] do
          Xoar.DecisionCycle.propose(operators)
        end

        new_state = %{
          state
          | codelet_state: new_codelet_state,
            tick_count: state.tick_count + 1,
            proposals_sent: state.proposals_sent + length(operators)
        }

        schedule_tick(state.tick_ms)
        {:noreply, new_state}
      end

      # ── Reactive mode: workspace change ────────────────

      @impl GenServer
      def handle_info({:wme_changed, table, id, attribute}, %{mode: :reactive} = state) do
        {operators, new_codelet_state} = perceive_and_propose(state.codelet_state)

        if operators != [] do
          Xoar.DecisionCycle.propose(operators)
        end

        new_state = %{
          state
          | codelet_state: new_codelet_state,
            reactions: state.reactions + 1,
            proposals_sent: state.proposals_sent + length(operators)
        }

        {:noreply, new_state}
      end

      # ── Receive apply from DecisionCycle ───────────────

      @impl GenServer
      def handle_cast({:apply_operator, operator}, state) do
        {_result, new_codelet_state} = handle_apply(operator, state.codelet_state)
        {:noreply, %{state | codelet_state: new_codelet_state}}
      end

      @impl GenServer
      def handle_call(:get_state, _from, state) do
        {:reply, state, state}
      end

      # ── Helpers ────────────────────────────────────────

      defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)
      defp via, do: {:via, Registry, {Xoar.CodeletRegistry, __MODULE__}}
    end
  end
end
