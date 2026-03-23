defmodule Xoar.Workspace do
  @moduledoc """
  Global Workspace backed by ETS + PubSub broadcast.

  Maps to CST's Global Workspace (Baars' Global Workspace Theory):
  when content changes, it is BROADCAST to all interested processes.

  This is the key difference from polling: codelets don't ask
  "did anything change?" — they receive a message when it does.

  ETS stores the data. Registry dispatches change notifications.
  Codelets subscribe to tables they care about and react.

      Perception writes WME to :perception ETS
          │
          ├──▶ ETS stores it
          │
          └──▶ Registry dispatches {:wme_changed, :perception, id, attr}
               │
               ├──▶ Navigation's mailbox  (subscribed to :perception)
               └──▶ Avoidance's mailbox   (subscribed to :perception)
  """

  @tables [:perception, :procedural, :episodic]

  require Logger

  # ── Lifecycle ──────────────────────────────────────────────

  def init do
    Enum.each(@tables, fn name ->
      if :ets.whereis(name) == :undefined do
        :ets.new(name, [:named_table, :set, :public, read_concurrency: true])
        Logger.debug("[xoar:workspace] ETS table created: #{name}")
      end
    end)

    :ok
  end

  def destroy do
    Enum.each(@tables, fn name ->
      if :ets.whereis(name) != :undefined, do: :ets.delete(name)
    end)

    :ok
  end

  # ── Subscribe to workspace changes ────────────────────────

  @doc """
  Subscribe the calling process to changes in a workspace table.
  The process will receive `{:wme_changed, table, id, attribute}`
  messages whenever a WME is written or deleted.

  ## Example
      Workspace.subscribe(:perception)
  """
  def subscribe(table) when table in @tables do
    Logger.debug("[xoar:workspace] #{inspect(self())} subscribed to :#{table}")
    Registry.register(Xoar.WorkspaceRegistry, table, [])
    :ok
  end

  # ── Write (with broadcast) ────────────────────────────────

  @doc """
  Insert a WME and broadcast the change to all subscribers.

  ## Example
      Workspace.put(:perception, WME.new(:drone, :position, {1, 2}))
      # → all processes subscribed to :perception receive:
      #   {:wme_changed, :perception, :drone, :position}
  """
  def put(table, %Xoar.WME{} = wme) when table in @tables do
    key = {wme.id, wme.attribute}

    changed? =
      case :ets.lookup(table, key) do
        [{^key, %Xoar.WME{value: old_value}}] -> old_value != wme.value
        [] -> true
      end

    if changed? do
      Logger.debug(
        "[xoar:workspace] PUT :#{table} #{wme.id}.#{wme.attribute} = #{inspect(wme.value)}"
      )

      :ets.insert(table, {key, wme})
      broadcast(table, wme.id, wme.attribute)
    else
      Logger.debug(
        "[xoar:workspace] PUT :#{table} #{wme.id}.#{wme.attribute} unchanged, skipping broadcast"
      )
    end

    :ok
  end

  @doc "Remove a WME and broadcast the deletion."
  def delete(table, id, attribute) when table in @tables do
    Logger.debug("[xoar:workspace] DELETE :#{table} #{id}.#{attribute}")
    :ets.delete(table, {id, attribute})
    broadcast(table, id, attribute)
    :ok
  end

  # ── Read (no broadcast, just ETS) ─────────────────────────

  def get(table, id, attribute) when table in @tables do
    case :ets.lookup(table, {id, attribute}) do
      [{_key, wme}] -> wme
      [] -> nil
    end
  end

  def get_all(table, id) when table in @tables do
    :ets.tab2list(table)
    |> Enum.filter(fn {_key, wme} -> wme.id == id end)
    |> Enum.map(fn {_key, wme} -> wme end)
  end

  def query(table, pattern) when table in @tables do
    :ets.tab2list(table)
    |> Enum.map(fn {_key, wme} -> wme end)
    |> Enum.filter(fn wme -> matches?(wme, pattern) end)
  end

  def dump(table) when table in @tables do
    :ets.tab2list(table)
    |> Enum.map(fn {_key, wme} -> wme end)
  end

  # ── Broadcast via Registry ────────────────────────────────

  defp broadcast(table, id, attribute) do
    Registry.dispatch(Xoar.WorkspaceRegistry, table, fn entries ->
      Logger.debug(
        "[xoar:workspace] BROADCAST :#{table} #{id}.#{attribute} → #{length(entries)} subscriber(s)"
      )

      for {pid, _} <- entries do
        send(pid, {:wme_changed, table, id, attribute})
      end
    end)
  end

  defp matches?(wme, pattern) do
    Enum.all?(pattern, fn
      {:id, v} -> wme.id == v
      {:attribute, v} -> wme.attribute == v
      {:value, v} -> wme.value == v
      _ -> true
    end)
  end
end
