-ifdef(TEST).
-module(attt).

%% Fixme: do it via parse transform:
-export([tags/0]).

-include_lib("anvl_test/include/anvl_test.hrl").

tags() ->
  [tag_a, tag_b].

-test(foo).
foo(instances, _) ->
  [1, 2];
foo(tags, #{instance := Inst}) ->
  case Inst of
    1 -> [tag_1];
    2 -> [tag_2]
  end;
foo(run, Env) ->
  ok.

-test(bar).
bar(run, Env) ->
  ok;
bar(crash, Env) ->
  error(Env).

-endif.
