defmodule Xoar.Codelets.Perception do
  @moduledoc """
  Perception Codelet — sensor interface. TICK mode.

  This is the only codelet that polls, because it talks to hardware.
  In a real drone: camera frames arrive at 30fps, GPS at 10Hz,
  LIDAR at its own rate. The sensor codelet matches that rhythm.

  Every 40ms it:
  1. Reads sensors (simulated here)
  2. Writes WMEs to :perception ETS
  3. Workspace broadcasts the change to all reactive codelets

  Perception is the ORIGIN of the reactive chain:
      Perception tick → writes ETS → broadcast
          → Navigation wakes, proposes :move
          → Avoidance wakes, proposes :evade
              → DecisionCycle decides
  """

  use Xoar.Codelet, tick_ms: 40
  require Logger

  alias Xoar.{Workspace, WME}

  @obstacles [{3, 3}, {5, 2}, {7, 7}, {4, 6}]
  @detection_range 2

  @impl Xoar.Codelet
  def init_state(_opts) do
    %{scan_count: 0, last_detected: []}
  end

  @impl Xoar.Codelet
  def perceive_and_propose(state) do
    detected =
      case Workspace.get(:perception, :drone, :position) do
        %WME{value: {px, py}} ->
          # Clear old obstacles
          Workspace.query(:perception, attribute: :obstacle)
          |> Enum.each(fn wme ->
            Workspace.delete(:perception, wme.id, wme.attribute)
          end)

          # Detect nearby
          nearby =
            @obstacles
            |> Enum.filter(fn {ox, oy} ->
              distance({px, py}, {ox, oy}) <= @detection_range
            end)

          if nearby != [] do
            Logger.debug(
              "[xoar:perception] Scan at #{inspect({px, py})}: detected #{length(nearby)} obstacle(s) #{inspect(nearby)}"
            )
          else
            Logger.debug("[xoar:perception] Scan at #{inspect({px, py})}: clear")
          end

          # Write detections → triggers broadcast to reactive codelets
          nearby
          |> Enum.with_index()
          |> Enum.each(fn {{ox, oy}, idx} ->
            Workspace.put(:perception, WME.new(:"obstacle_#{idx}", :obstacle, {ox, oy}))
          end)

          # Update target distance
          case Workspace.get(:perception, :drone, :target) do
            %WME{value: target} ->
              dist = distance({px, py}, target)
              Logger.debug("[xoar:perception] Target distance: #{Float.round(dist, 2)}")

              Workspace.put(
                :perception,
                WME.new(:drone, :target_distance, dist)
              )

            _ ->
              :ok
          end

          nearby

        _ ->
          # Logger.debug("[xoar:perception] No drone position in workspace, skipping scan", xoar: :tick)
          Logger.debug("[xoar:perception] No drone position in workspace, skipping scan")
          []
      end

    {[], %{state | scan_count: state.scan_count + 1, last_detected: detected}}
  end

  @impl Xoar.Codelet
  def handle_apply(_op, state), do: {:ok, state}

  defp distance({x1, y1}, {x2, y2}) do
    :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
  end
end
