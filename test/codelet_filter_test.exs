defmodule Xoar.CodeletFilterTest do
  use ExUnit.Case, async: true

  alias Xoar.Codelet

  # ── parse_subscriptions ──────────────────────────────────

  describe "parse_subscriptions/1" do
    test "bare atom → whole table, :any filter" do
      {tables, filters} = Codelet.parse_subscriptions([:perception])
      assert tables == [:perception]
      assert filters == %{perception: :any}
    end

    test "keyword → table + patterns" do
      {tables, filters} =
        Codelet.parse_subscriptions(perception: [{:drone, :position}, {:_, :obstacle}])

      assert tables == [:perception]
      assert filters == %{perception: [{:drone, :position}, {:_, :obstacle}]}
    end

    test "mixed bare + keyword" do
      {tables, filters} =
        Codelet.parse_subscriptions([
          :episodic,
          {:perception, [{:drone, :position}]}
        ])

      assert tables == [:episodic, :perception]
      assert filters.episodic == :any
      assert filters.perception == [{:drone, :position}]
    end
  end

  # ── wme_matches? ─────────────────────────────────────────

  describe "wme_matches?/3" do
    test ":any matches everything" do
      assert Codelet.wme_matches?(:any, :drone, :position)
      assert Codelet.wme_matches?(:any, :obstacle_0, :obstacle)
      assert Codelet.wme_matches?(:any, :whatever, :anything)
    end

    test "exact {id, attribute} match" do
      patterns = [{:drone, :position}]
      assert Codelet.wme_matches?(patterns, :drone, :position)
      refute Codelet.wme_matches?(patterns, :drone, :target)
      refute Codelet.wme_matches?(patterns, :other, :position)
    end

    test "{:_, attribute} matches any id with that attribute" do
      patterns = [{:_, :obstacle}]
      assert Codelet.wme_matches?(patterns, :obstacle_0, :obstacle)
      assert Codelet.wme_matches?(patterns, :obstacle_99, :obstacle)
      refute Codelet.wme_matches?(patterns, :drone, :position)
    end

    test "{id, :_} matches any attribute on that id" do
      patterns = [{:drone, :_}]
      assert Codelet.wme_matches?(patterns, :drone, :position)
      assert Codelet.wme_matches?(patterns, :drone, :battery)
      refute Codelet.wme_matches?(patterns, :obstacle_0, :obstacle)
    end

    test "{:_, :_} matches everything (same as :any)" do
      patterns = [{:_, :_}]
      assert Codelet.wme_matches?(patterns, :drone, :position)
      assert Codelet.wme_matches?(patterns, :obstacle_0, :obstacle)
    end

    test "multiple patterns — OR semantics" do
      # Navigation's actual subscription
      patterns = [{:drone, :position}, {:drone, :target}]

      assert Codelet.wme_matches?(patterns, :drone, :position)
      assert Codelet.wme_matches?(patterns, :drone, :target)
      refute Codelet.wme_matches?(patterns, :drone, :target_distance)
      refute Codelet.wme_matches?(patterns, :drone, :battery)
      refute Codelet.wme_matches?(patterns, :obstacle_0, :obstacle)
    end

    test "ObstacleAvoidance pattern — position + any obstacle" do
      patterns = [{:drone, :position}, {:_, :obstacle}]

      assert Codelet.wme_matches?(patterns, :drone, :position)
      assert Codelet.wme_matches?(patterns, :obstacle_0, :obstacle)
      assert Codelet.wme_matches?(patterns, :obstacle_5, :obstacle)
      refute Codelet.wme_matches?(patterns, :drone, :target)
      refute Codelet.wme_matches?(patterns, :drone, :target_distance)
      refute Codelet.wme_matches?(patterns, :drone, :battery)
    end
  end
end
