defmodule Xoar.Codelets.ObstacleAvoidance do
  @moduledoc """
  Obstacle Avoidance Codelet — REACTIVE mode.

  Subscribes to :perception, filtered to {:drone, :position} and
  {:_, :obstacle} (any id with attribute :obstacle). Ignores
  target_distance, target changes, and other irrelevant WMEs.

  Perception writes obstacle → Avoidance's filter matches →
  wakes up → proposes :evade with :best preference.
  """

  use Xoar.Codelet,
    subscribe_to: [
      perception: [{:drone, :position}, {:_, :obstacle}]
    ]

  require Logger

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
            Logger.debug(
              "[xoar:avoidance] No threats within range #{@danger_range} of #{inspect({px, py})}"
            )

            []

          nearby ->
            direction = calculate_evasion({px, py}, nearby)

            Logger.debug(
              "[xoar:avoidance] THREAT! #{length(nearby)} obstacle(s) near #{inspect({px, py})}, evasion dir=#{inspect(direction)}"
            )

            [
              Operator.new(:evade, __MODULE__,
                preference: :best,
                params: %{direction: direction}
              )
            ]
        end
      else
        _ ->
          Logger.debug("[xoar:avoidance] No drone position available")
          []
      end

    {operators, %{state | evasions_proposed: state.evasions_proposed + length(operators)}}
  end

  @impl Xoar.Codelet
  def handle_apply(%Operator{name: :evade, params: %{direction: {dx, dy}}}, state) do
    case Workspace.get(:perception, :drone, :position) do
      %WME{value: {px, py}} ->
        new_pos = {px + dx, py + dy}

        Logger.debug(
          "[xoar:avoidance] APPLY :evade #{inspect({px, py})} → #{inspect(new_pos)} (dir=#{inspect({dx, dy})})"
        )

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
