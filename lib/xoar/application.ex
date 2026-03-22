defmodule Xoar.Application do
  @moduledoc """
  Xoar OTP Application.

      Xoar.Supervisor (rest_for_one)
      │
      ├── Xoar.CodeletRegistry       ← process name lookup
      ├── Xoar.WorkspaceRegistry     ← PubSub for ETS changes (duplicate keys)
      │
      ├── Xoar.DecisionCycle         ← collects proposals, decides
      │
      └── Xoar.CodeletSupervisor     ← one_for_one
          ├── Perception   (SENSOR  — tick 40ms, writes to ETS)
          ├── Navigation   (REACTIVE — subscribes to :perception)
          └── Avoidance    (REACTIVE — subscribes to :perception)

  Order matters:
  1. Registries first (everyone needs them)
  2. DecisionCycle (must exist before codelets send proposals)
  3. Codelets (start ticking / subscribing immediately)
  """

  use Application

  @impl true
  def start(_type, _args) do
    Xoar.Workspace.init()

    children = [
      # Process name registry (unique keys)
      {Registry, keys: :unique, name: Xoar.CodeletRegistry},

      # Workspace PubSub registry (duplicate keys — multiple subscribers per table)
      {Registry, keys: :duplicate, name: Xoar.WorkspaceRegistry},

      # DecisionCycle must be up before codelets start proposing
      {Xoar.DecisionCycle,
       cycle_interval_ms: 100,
       auto_run: false},

      # Codelet processes — each starts its own loop or subscribes
      %{
        id: Xoar.CodeletSupervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             [
               {Xoar.Codelets.Perception, []},
               {Xoar.Codelets.Navigation, []},
               {Xoar.Codelets.ObstacleAvoidance, []}
             ],
             [strategy: :one_for_one, name: Xoar.CodeletSupervisor]
           ]}
      }
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Xoar.Supervisor)
  end
end
