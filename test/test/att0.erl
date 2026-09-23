-ifdef(TEST).
-module(att0).
-moduledoc """
Test suite that doesn't have any global tags or fixtures.
""".

-include_lib("anvl_test/include/anvl_test.hrl").

-test(foo).
foo(instances, _) ->
  [1, 2];
foo(tags, #{instance := Inst}) ->
  case Inst of
    1 -> [tag_1];
    2 -> [tag_2]
  end;
foo(run, #{instance := _}) ->
  ok.

-test(bar).
bar(run, #{instance := _}) ->
  ok;
bar(crash, Env) ->
  %% This branch should be unreachable
  error(Env).

-endif.
