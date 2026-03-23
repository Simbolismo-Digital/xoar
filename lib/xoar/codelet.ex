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

      use Xoar.Codelet, subscribe_to: [
        perception: [{:drone, :position}, {:drone, :target}]
      ]

  For cognitive codelets: navigation, attention, obstacle avoidance,
  learning. These react to workspace changes via PubSub.
  They sleep until their mailbox gets a {:wme_changed, ...} message
  that matches one of their declared patterns. :_ is wildcard.
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
  - In reactive mode: called when a subscribed WME matching
    the codelet's declared patterns changes

  Returns {operators, new_state}.
  """
  @callback perceive_and_propose(state :: term()) ::
              {[Xoar.Operator.t()], new_state :: term()}

  @doc "Handle an apply message from the DecisionCycle."
  @callback handle_apply(Xoar.Operator.t(), state :: term()) ::
              {:ok | {:error, term()}, new_state :: term()}

  @doc """
  Parse `subscribe_to` into {tables, filters}.

  Accepts two forms:

      # Bare atoms — entire table, no filtering (backward compat)
      subscribe_to: [:perception]
      # → tables: [:perception], filters: %{perception: :any}

      # Keyword — table + specific {id, attribute} patterns
      # :_ is wildcard
      subscribe_to: [perception: [{:drone, :position}, {:drone, :target}]]
      # → tables: [:perception],
      #   filters: %{perception: [{:drone, :position}, {:drone, :target}]}

  PubSub subscription is always at table level (that's the Registry
  granularity). Filters are checked in handle_info BEFORE calling
  perceive_and_propose — irrelevant messages never wake the codelet.
  """
  def parse_subscriptions(subscribe_to) do
    Enum.reduce(subscribe_to, {[], %{}}, fn
      # bare atom → whole table, no filter
      table, {tables, filters} when is_atom(table) ->
        {[table | tables], Map.put(filters, table, :any)}

      # keyword pair → table + patterns
      {table, patterns}, {tables, filters} when is_atom(table) and is_list(patterns) ->
        {[table | tables], Map.put(filters, table, patterns)}
    end)
    |> then(fn {tables, filters} -> {Enum.reverse(tables), filters} end)
  end

  @doc "Does {id, attribute} match any pattern for this table?"
  def wme_matches?(:any, _id, _attribute), do: true

  def wme_matches?(patterns, id, attribute) when is_list(patterns) do
    Enum.any?(patterns, fn
      {:_, :_} -> true
      {:_, attr} -> attr == attribute
      {ident, :_} -> ident == id
      {ident, attr} -> ident == id and attr == attribute
    end)
  end

  defmacro __using__(opts) do
    tick_ms = Keyword.get(opts, :tick_ms, nil)
    subscribe_to = Keyword.get(opts, :subscribe_to, [])

    mode =
      cond do
        tick_ms != nil -> :sensor
        subscribe_to != [] -> :reactive
        true -> raise "use Xoar.Codelet requires either tick_ms: N or subscribe_to: [tables]"
      end

    {tables, filters} = Xoar.Codelet.parse_subscriptions(subscribe_to)

    quote do
      @behaviour Xoar.Codelet
      use GenServer
      require Logger

      @codelet_mode unquote(mode)
      @codelet_tick_ms unquote(tick_ms)
      @codelet_tables unquote(tables)
      @codelet_filters unquote(Macro.escape(filters))

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
          tables: @codelet_tables,
          filters: @codelet_filters,
          codelet_state: init_state(opts),
          tick_count: 0,
          reactions: 0,
          skipped: 0,
          proposals_sent: 0
        }

        case @codelet_mode do
          :sensor ->
            Logger.debug(
              "[xoar:codelet] #{__MODULE__} INIT mode=sensor tick=#{@codelet_tick_ms}ms"
            )

            schedule_tick(@codelet_tick_ms)

          :reactive ->
            Logger.debug(
              "[xoar:codelet] #{__MODULE__} INIT mode=reactive tables=#{inspect(@codelet_tables)} filters=#{inspect(@codelet_filters)}"
            )

            Enum.each(@codelet_tables, fn table ->
              Xoar.Workspace.subscribe(table)
            end)
        end

        {:ok, state}
      end

      # ── Sensor mode: tick ──────────────────────────────

      @impl GenServer
      def handle_info(:tick, %{mode: :sensor} = state) do
        Logger.debug("[xoar:codelet] #{__MODULE__} TICK ##{state.tick_count + 1}", xoar: :tick)
        {operators, new_codelet_state} = perceive_and_propose(state.codelet_state)

        if operators != [] do
          Logger.debug(
            "[xoar:codelet] #{__MODULE__} proposing #{length(operators)} operator(s): #{inspect(Enum.map(operators, & &1.name))}"
          )

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
        filter = Map.get(state.filters, table, :any)

        if Xoar.Codelet.wme_matches?(filter, id, attribute) do
          Logger.debug("[xoar:codelet] #{__MODULE__} WAKEUP on :#{table} #{id}.#{attribute}")
          {operators, new_codelet_state} = perceive_and_propose(state.codelet_state)

          if operators != [] do
            Logger.debug(
              "[xoar:codelet] #{__MODULE__} proposing #{length(operators)} operator(s): #{inspect(Enum.map(operators, & &1.name))}"
            )

            Xoar.DecisionCycle.propose(operators)
          end

          new_state = %{
            state
            | codelet_state: new_codelet_state,
              reactions: state.reactions + 1,
              proposals_sent: state.proposals_sent + length(operators)
          }

          {:noreply, new_state}
        else
          Logger.debug(
            "[xoar:codelet] #{__MODULE__} SKIP :#{table} #{id}.#{attribute} (filter mismatch)"
          )

          {:noreply, %{state | skipped: state.skipped + 1}}
        end
      end

      # ── Receive apply from DecisionCycle ───────────────

      @impl GenServer
      def handle_cast({:apply_operator, operator}, state) do
        Logger.debug(
          "[xoar:codelet] #{__MODULE__} APPLY :#{operator.name} params=#{inspect(operator.params)}"
        )

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
