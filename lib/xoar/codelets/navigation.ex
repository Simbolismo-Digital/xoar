defmodule Xoar.Codelets.Navigation do
  @moduledoc """
  Navigation Codelet — REACTIVE mode.

  Subscribes to :perception table. Sleeps until Perception writes
  a WME, then wakes up, reads the workspace, proposes :move.

  No tick. No polling. Pure message-driven.

  When Perception writes drone position → this process receives
  {:wme_changed, :perception, :drone, :position} in its mailbox →
  perceive_and_propose runs → sends :move proposal to DecisionCycle.
  """

  use Xoar.Codelet, subscribe_to: [:perception]

  alias Xoar.{Workspace, WME, Operator}

  @impl Xoar.Codelet
  def init_state(_opts) do
    %{moves_proposed: 0, moves_applied: 0}
  end

  @impl Xoar.Codelet
  def perceive_and_propose(state) do
    operators =
      with %WME{value: {px, py}} <- Workspace.get(:perception, :drone, :position),
           %WME{value: {tx, ty}} <- Workspace.get(:perception, :drone, :target) do
        propose_movement({px, py}, {tx, ty})
      else
        _ -> []
      end

    {operators, %{state | moves_proposed: state.moves_proposed + length(operators)}}
  end

  @impl Xoar.Codelet
  def handle_apply(%Operator{name: :move, params: %{direction: {dx, dy}}}, state) do
    case Workspace.get(:perception, :drone, :position) do
      %WME{value: {px, py}} ->
        new_pos = {px + dx, py + dy}
        Workspace.put(:perception, WME.new(:drone, :position, new_pos))

        ts = System.monotonic_time(:millisecond)
        Workspace.put(:episodic, WME.new(:"move_#{ts}", :action, %{
          from: {px, py},
          to: new_pos,
          source: :navigation,
          time: ts
        }))

        {:ok, %{state | moves_applied: state.moves_applied + 1}}

      _ ->
        {{:error, :no_position}, state}
    end
  end

  def handle_apply(_op, state), do: {:ok, state}

  # ── Proposal logic ─────────────────────────────────────────

  defp propose_movement({px, py}, {tx, ty}) when px == tx and py == ty, do: []

  defp propose_movement({px, py}, {tx, ty}) do
    dx = sign(tx - px)
    dy = sign(ty - py)

    obstacles = Workspace.query(:perception, attribute: :obstacle)
    intended = {px + dx, py + dy}

    preference =
      if obstacle_at?(obstacles, intended), do: :worst, else: :acceptable

    [
      Operator.new(:move, __MODULE__,
        preference: preference,
        params: %{direction: {dx, dy}}
      )
    ]
  end

  defp obstacle_at?(obstacles, {x, y}) do
    Enum.any?(obstacles, fn %WME{value: {ox, oy}} -> ox == x and oy == y end)
  end

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0
end
