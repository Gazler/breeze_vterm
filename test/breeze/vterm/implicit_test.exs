defmodule Breeze.VTerm.ImplicitTest do
  use ExUnit.Case, async: true

  alias Breeze.VTerm.Implicit

  test "pins scrollback to the bottom by default" do
    assert {:ok, state, meta} =
             Implicit.init(
               [],
               %{
                 :"terminal-content-height" => 12,
                 :"terminal-scrollback-rows" => 8,
                 :"terminal-cursor-row" => 3,
                 :"terminal-cursor-col" => 2,
                 :"terminal-cursor-char" => " "
               },
               %{}
             )

    assert meta[:requires_layout_rerender] == true
    assert meta[:rerender_every] == 500
    assert meta[:captures_printable_keys] == true
    assert meta[:captures_control_keys] == true
    assert meta[:captures_focus_keys] == true
    assert meta[:captures_keys] == ["PageUp", "PageDown"]

    assert [scroll_y: 8] =
             Implicit.handle_modifiers(:root, [layout_element: viewport(4, 12)], state)
  end

  test "breeze shortcut capture can be disabled" do
    assert {:ok, _state, meta} =
             Implicit.init(
               [],
               %{:"terminal-capture-breeze-shortcuts" => false},
               %{}
             )

    refute Keyword.has_key?(meta, :captures_printable_keys)
    refute Keyword.has_key?(meta, :captures_control_keys)
    refute Keyword.has_key?(meta, :captures_focus_keys)
    refute Keyword.has_key?(meta, :captures_keys)
  end

  test "cursor-only changes do not force a layout rerender" do
    last_state = %{
      cols: 10,
      rows: 3,
      content_height: 12,
      scrollback_rows: 8,
      offset_y: 0,
      cursor: %{row: 0, col: 0, char: " "}
    }

    assert {:ok, _state, meta} =
             Implicit.init(
               [],
               %{
                 :"terminal-cols" => 10,
                 :"terminal-rows" => 3,
                 :"terminal-content-height" => 12,
                 :"terminal-scrollback-rows" => 8,
                 :"terminal-cursor-row" => 0,
                 :"terminal-cursor-col" => 1,
                 :"terminal-cursor-char" => "x"
               },
               last_state
             )

    refute Keyword.has_key?(meta, :requires_layout_rerender)
  end

  test "control and focus key capture can be released without disabling page scroll" do
    assert {:ok, _state, meta} =
             Implicit.init(
               [],
               %{
                 :"terminal-capture-control-keys" => false,
                 :"terminal-capture-focus-keys" => false
               },
               %{}
             )

    assert meta[:captures_printable_keys] == true
    assert meta[:captures_keys] == ["PageUp", "PageDown"]
    refute Keyword.has_key?(meta, :captures_control_keys)
    refute Keyword.has_key?(meta, :captures_focus_keys)
  end

  test "mouse scrolling can leave and re-pin the bottom" do
    {:ok, state, _meta} =
      Implicit.init([], %{:"terminal-content-height" => 12}, %{
        offset_y: 8,
        pinned_bottom: true
      })

    assert {:noreply, state} =
             Implicit.handle_event(
               :ignore,
               %{"mouse" => %{"button" => "wheel_up"}, "element" => viewport(4, 12)},
               state
             )

    assert state.offset_y == 5
    assert state.pinned_bottom == false

    assert [scroll_y: 5] =
             Implicit.handle_modifiers(:root, [layout_element: viewport(4, 12)], state)

    assert {:noreply, state} =
             Implicit.handle_event(
               :ignore,
               %{
                 "mouse" => %{"button" => "wheel_down", "repeat" => 2},
                 "element" => viewport(4, 12)
               },
               state
             )

    assert state.offset_y == 8
    assert state.pinned_bottom == true

    assert [scroll_y: 8] =
             Implicit.handle_modifiers(:root, [layout_element: viewport(4, 12)], state)
  end

  test "wheel step is independent of viewport height and honors coalesced repeats" do
    for height <- [4, 24, 60] do
      bottom = 200 - height

      {:ok, state, _} =
        Implicit.init([], %{:"terminal-content-height" => 200}, %{
          offset_y: bottom,
          pinned_bottom: true
        })

      assert {:noreply, state} =
               Implicit.handle_event(
                 :ignore,
                 %{
                   "mouse" => %{"button" => "wheel_up", "repeat" => 5},
                   "element" => viewport(height, 200)
                 },
                 state
               )

      assert state.offset_y == bottom - 15
      refute state.pinned_bottom
    end
  end

  test "page keys scroll the buffer without forwarding terminal input" do
    {:ok, state, _meta} =
      Implicit.init([], %{:"terminal-content-height" => 20}, %{
        offset_y: 15,
        pinned_bottom: true
      })

    assert {:noreply, state} =
             Implicit.handle_event(
               :ignore,
               %{"key" => "PageUp", "element" => viewport(5, 20)},
               state
             )

    assert state.offset_y == 11
    assert state.pinned_bottom == false

    assert [scroll_y: 11] =
             Implicit.handle_modifiers(:root, [layout_element: viewport(5, 20)], state)

    assert {:noreply, state} =
             Implicit.handle_event(
               :ignore,
               %{"key" => "PageDown", "element" => viewport(5, 20)},
               state
             )

    assert state.offset_y == 15
    assert state.pinned_bottom == true

    assert [scroll_y: 15] =
             Implicit.handle_modifiers(:root, [layout_element: viewport(5, 20)], state)
  end

  test "terminal input re-pins the viewport to the bottom" do
    {:ok, state, _meta} =
      Implicit.init([], %{:"terminal-content-height" => 12}, %{
        offset_y: 3,
        pinned_bottom: false
      })

    assert {{:change, %{input: "a"}}, state} =
             Implicit.handle_event(:ignore, %{"key" => "a", "element" => viewport(4, 12)}, state)

    assert state.offset_y == 8
    assert state.pinned_bottom == true
  end

  test "cursor animation tolerates partial render state" do
    box = %{
      style: %{
        border: %{left: false, top: false},
        padding_left: 0,
        padding_top: 0
      }
    }

    assert {:ok, ^box, overlays: [overlay]} =
             Implicit.animate(:root, box, [], %{cols: 72, rows: 18}, %{
               layout: viewport(4, 12),
               now: 0,
               last_interaction_at: 0,
               theme: Breeze.Theme.new(:system16)
             })

    assert overlay.char == " "
    assert overlay.x == 0
    assert overlay.y == 0
    assert overlay.visible? == false
  end

  defp viewport(height, content_height) do
    %{
      height: height,
      viewport_height: height,
      content_height: content_height
    }
  end
end
