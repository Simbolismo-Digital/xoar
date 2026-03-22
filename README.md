# Xoar

**A Cognitive Architecture for Autonomous Drone Systems**

Built on Elixir/OTP. Inspired by Soar, Clarion, and CST.

## What is this?

[Xoar Thesis (draft 1)](https://drive.google.com/file/d/10U99Du5SO4W5v-CaYIBChKx1q4DCA1_R/view)

This is the **kernel** — the minimal viable cognitive architecture that implements
Soar's decision cycle in idiomatic Elixir. Everything else (Clarion's dual-process
learning, CST's full Global Workspace, distribution, drone integration) builds on top
of this foundation.

## Architecture

Two types of codelets, matching the nature of cognitive systems:

**Sensor codelets** tick — they interface with hardware that has its own rhythm.
**Cognitive codelets** react — they sleep until the workspace changes.

```
    ┌─────────────┐
    │ Perception  │ SENSOR — tick every 40ms
    │             │ reads hardware, writes WMEs to ETS
    └──────┬──────┘
           │
           │ Workspace.put → ETS write + PubSub broadcast
           │
           ▼
    ┌──────────────┐     {:wme_changed, ...}     {:wme_changed, ...}
    │   Workspace  │ ──────────────┬──────────────────────┐
    │  (ETS+PubSub)│               │                      │
    │              │               ▼                      ▼
    │  :perception │     ┌──────────────┐       ┌──────────────┐
    │  :procedural │     │  Navigation  │       │  Avoidance   │
    │  :episodic   │     │   REACTIVE   │       │   REACTIVE   │
    └──────────────┘     │  (no tick!)  │       │  (no tick!)  │
                         │ wakes, reads │       │  wakes, reads│
                         │ ETS,proposes │       │  ETS,proposes│
                         └──────┬───────┘       └──────┬───────┘
                                │                      │
                          :propose                :propose
                                │                      │
                                ▼                      ▼
                         ┌──────────────────────────────┐
                         │       DecisionCycle          │
                         │       tick: 100ms            │
                         │                              │
                         │  drains mailbox              │
                         │  resolves preferences        │
                         │  casts :apply to winner PID  │
                         └──────────────────────────────┘
```

The reactive chain: Perception tick → ETS write → broadcast →
Navigation + Avoidance wake → propose → DecisionCycle decides.
No polling in cognitive codelets. Pure GWT broadcast semantics.

## Quick Start

### Package

```bash
mix tar
```

### Run

```bash
cd xoar
iex -S mix
```

```elixir
# Run the full demo
Xoar.Demo.run()

# Or step through manually
Xoar.Demo.setup()              # drone at {0,0}, target at {8,8}
Xoar.Demo.step()               # one decision cycle
Xoar.Demo.step()               # another
Xoar.Demo.state()              # inspect workspace
Xoar.Demo.processes()          # see modes: SENSOR vs REACTIVE
Xoar.Demo.introspect()         # see ticks vs reactions per codelet

# Prove fault tolerance
Xoar.Demo.kill(Xoar.Codelets.Navigation)  # OTP restarts + re-subscribes
Xoar.Demo.processes()                       # new PID, reactive again
```

## File Map

```
lib/
├── xoar.ex                         # Module docs
├── xoar/
│   ├── wme.ex                      # Working Memory Element struct
│   ├── workspace.ex                # ETS + PubSub broadcast on write
│   ├── operator.ex                 # Operator struct (proposed actions)
│   ├── codelet.ex                  # Codelet behaviour (tick_ms OR subscribe_to)
│   ├── decision_cycle.ex           # Collects proposals, decides, routes apply
│   ├── demo.ex                     # Interactive demo
│   └── codelets/
│       ├── perception.ex           # SENSOR mode  — tick 40ms, writes ETS
│       ├── navigation.ex           # REACTIVE mode — subscribes to :perception
│       └── obstacle_avoidance.ex   # REACTIVE mode — subscribes to :perception
```

## Key Principle: Hybrid Autonomy

Cognitive systems are not uniform. Sensor processes poll hardware.
Cognitive processes react to information. Xoar models this:

- **Sensor codelets** (`use Xoar.Codelet, tick_ms: 40`) — poll hardware at a fixed rate, write WMEs to ETS
- **Reactive codelets** (`use Xoar.Codelet, subscribe_to: [:perception]`) — sleep until a workspace table changes, then wake and react
- **Workspace is ETS + PubSub** — every `put/delete` writes to ETS AND broadcasts via Registry to subscribers
- **No polling in cognitive codelets** — they receive `{:wme_changed, table, id, attr}` in their mailbox
- **DecisionCycle collects, not orchestrates** — proposals accumulate, it decides on its own tick
- **Fault tolerance is free** — kill a codelet, OTP restarts it, sensor resumes ticking, reactive re-subscribes

This maps directly to GWT: content is broadcast to the Global Workspace,
and specialized processes (codelets) react to what's relevant to them.

## Key Mappings (Soar → Xoar)

| Soar / CST                | Xoar                                                  |
|---------------------------|--------------------------------------------------------|
| WME `(S1 ^attr val)`     | `%WME{id: :s1, attribute: :attr, value: val}`          |
| Production rules          | `perceive_and_propose/1` with pattern matching         |
| Working memory            | ETS `:perception` table                                |
| Global Workspace broadcast| `Workspace.put` → ETS + Registry PubSub dispatch       |
| Codelet reacts to content | `handle_info({:wme_changed, ...})` in reactive codelet |
| Sensor codelet            | `use Xoar.Codelet, tick_ms: 40` — polls hardware       |
| Cognitive codelet         | `use Xoar.Codelet, subscribe_to: [...]` — reacts       |
| Operator proposal         | Codelet sends `%Operator{}` to DecisionCycle mailbox   |
| Preference                | `:acceptable`, `:best`, `:worst`, etc                  |
| Decision procedure        | `decide/1` drains mailbox buffer                       |
| Operator application      | DecisionCycle casts `{:apply_operator, op}` to PID     |
| Impasse → substate        | Spawn supervised child GenServer (TODO)                |

## Implementation Roadmap

### Phase 1 — Soar Kernel (this code) ✓
- [x] WME struct
- [x] ETS Workspace (perception, procedural, episodic)
- [x] Codelet behaviour
- [x] Decision Cycle GenServer
- [x] Preference resolution
- [x] Example codelets (perception, navigation, avoidance)
- [ ] Impasse → substate (spawn child GenServer)
- [ ] Tests

### Phase 2 — Soar Complete
- [ ] Chunking: observe successful operator chains, compile into
      new pattern-match rules in `:procedural` ETS
- [ ] Impasse resolution via supervised sub-cycles
- [ ] Richer preference semantics (require, prohibit, numeric)
- [ ] Cycle introspection / trace logging

### Phase 3 — CST Integration
- [ ] Attention codelets (salience-based filtering)
- [ ] Full Global Workspace broadcast semantics
- [ ] Codelet activation levels (compete for workspace access)
- [ ] Memory consolidation codelet (perception → episodic)

### Phase 4 — Clarion Dual-Process
- [ ] Implicit layer: Axon neural network as GenServer
- [ ] Online learning from operator selection outcomes
- [ ] Bottom-up rule extraction (implicit → explicit)
- [ ] Confidence threshold for crystallization

### Phase 5 — Distribution
- [ ] Nebulex for distributed ETS across nodes
- [ ] Phoenix.PubSub for cross-node operator broadcast
- [ ] Multi-drone cluster coordination
- [ ] Heterogeneous agents (drone + ground station)

### Phase 6 — Drone Integration
- [ ] ROS2 / Nerves sensor interface
- [ ] MAVLink motor commands
- [ ] Real hardware validation
- [ ] Benchmarks vs CST baseline
