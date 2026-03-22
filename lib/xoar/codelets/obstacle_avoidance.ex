defmodule Xoar.Codelets.ObstacleAvoidance do
  @moduledoc """
  Obstacle Avoidance Codelet — REACTIVE mode.

  Subscribes to :perception. Sleeps until an obstacle WME is
  written, then wakes up and proposes :evade with :best preference.

  The competition with Navigation happens naturally:
  Perception writes obstacle → BOTH Navigation and Avoidance
  wake up from the same broadcast → both propose → DecisionCycle
  resolves preferences → :best beats :worst → evade wins.

  No coordination between codelets. Just independent processes
  reacting to the same workspace change.
  """

  use Xoar.Codelet, subscribe_to: [:perception]

  alias Xoar.{Workspace, WME, Operator}

  @danger_range 1.5

  @impl Xoar.Codelet
  def init_state(_opts) do
    %{evasions_proposed: 0, evasions_applied: 0}
  end

  @impl Xoar.Codelet
  def perceive_and_propose(state) do
    operators =
      with %WME{value: {px, py}} <- Workspace.get(:perception, :drone, :position) do
        obstacles = Workspace.query(:perception, attribute: :obstacle)

        dangerous =
          Enum.filter(obstacles, fn %WME{value: {ox, oy}} ->
            distance({px, py}, {ox, oy}) <= @danger_range
          end)

        case dangerous do
          [] ->
            []

          nearby ->
            direction = calculate_evasion({px, py}, nearby)

            [
              Operator.new(:evade, __MODULE__,
                preference: :best,
                params: %{direction: direction}
              )
            ]
        end
      else
        _ -> []
      end

    {operators, %{state | evasions_proposed: state.evasions_proposed + length(operators)}}
  end

  @impl Xoar.Codelet
  def handle_apply(%Operator{name: :evade, params: %{direction: {dx, dy}}}, state) do
    case Workspace.get(:perception, :drone, :position) do
      %WME{value: {px, py}} ->
        new_pos = {px + dx, py + dy}
        Workspace.put(:perception, WME.new(:drone, :position, new_pos))

        ts = System.monotonic_time(:millisecond)

        Workspace.put(
          :episodic,
          WME.new(:"evade_#{ts}", :action, %{
            from: {px, py},
            to: new_pos,
            source: :obstacle_avoidance,
            time: ts
          })
        )

        {:ok, %{state | evasions_applied: state.evasions_applied + 1}}

      _ ->
        {{:error, :no_position}, state}
    end
  end

  def handle_apply(_op, state), do: {:ok, state}

  defp calculate_evasion({px, py}, obstacles) do
    {avg_ox, avg_oy} =
      obstacles
      |> Enum.reduce({0.0, 0.0}, fn %WME{value: {ox, oy}}, {sx, sy} ->
        {sx + ox, sy + oy}
      end)
      |> then(fn {sx, sy} ->
        n = length(obstacles)
        {sx / n, sy / n}
      end)

    dx = sign(px - avg_ox)
    dy = sign(py - avg_oy)

    case {dx, dy} do
      {0, 0} -> {1, 0}
      dir -> dir
    end
  end

  defp distance({x1, y1}, {x2, y2}) do
    :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
  end

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0
end
