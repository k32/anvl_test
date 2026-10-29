-ifdef(TEST).
-module(att_eunit_fail).
-moduledoc """
EUnit test module that fails.
""".

-export([foo_test/0]).

foo_test() ->
  error(eunit_expected_fail).

-endif.
