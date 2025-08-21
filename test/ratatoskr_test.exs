defmodule RatatoskrTest do
  use ExUnit.Case
  doctest Ratatoskr

  test "greets the world" do
    assert Ratatoskr.hello() == :world
  end
end
