defmodule Breeze.VTerm.BackBreezeCacheTest do
  use ExUnit.Case, async: false

  alias BackBreeze.PreparedContentStore
  alias Breeze.VTerm.Surface

  setup do
    BackBreeze.RenderCache.clear()
    PreparedContentStore.clear()

    on_exit(fn ->
      BackBreeze.RenderCache.clear()
      PreparedContentStore.clear()
    end)

    :ok
  end

  test "terminal virtual text rendering does not retain lazy surface snapshots" do
    surface =
      Surface.new(cols: 40, rows: 8)
      |> Surface.write(String.duplicate("line output that scrolls\r\n", 80))

    style =
      BackBreeze.Style.width(40)
      |> BackBreeze.Style.height(8)
      |> BackBreeze.Style.overflow(:hidden)

    output =
      BackBreeze.Style.render(style, Surface.virtual_text(surface),
        offset_top: Surface.line_count(surface) - surface.rows
      )

    assert output =~ "line output"
    assert PreparedContentStore.size() == 0

    render_cache_size = BackBreeze.RenderCache.size()

    surface =
      Surface.write(surface, "x")

    _output =
      BackBreeze.Style.render(style, Surface.virtual_text(surface),
        offset_top: Surface.line_count(surface) - surface.rows
      )

    assert PreparedContentStore.size() == 0
    assert BackBreeze.RenderCache.size() == render_cache_size
  end
end
