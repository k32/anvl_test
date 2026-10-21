-ifdef(TEST).
-module(att0).
-behavior(anvl_test_suite).
-moduledoc """
Test suite that doesn't have any global tags or fixtures.
""".

-include_lib("anvl_test/include/anvl_test.hrl").
-include_lib("stdlib/include/assert.hrl").

-test(foo).
foo(instances, _) ->
  [1, 2];
foo(tags, #{instance := Inst}) ->
  case Inst of
    1 -> [tag_1];
    2 -> [tag_2]
  end;
foo(timeout, #{instance := 1}) ->
  1000;
foo(run, #{instance := _}) ->
  ok.

-test(parent_node_is_hidden).
parent_node_is_hidden(run, #{instance := _}) ->
  ?assertMatch([], nodes());
parent_node_is_hidden(crash, Env) ->
  %% This branch should be unreachable
  error(Env).

-test(expected_fail).
expected_fail(run, #{instance := _}) ->
  error(expected_fail).

%% This test case is expected to time out:
-test(sleepy).
sleepy(timeout, #{instance := _}) ->
  200;
sleepy(run, #{instance := _}) ->
  receive after infinity -> ok end.

-endif.
