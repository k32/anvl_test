-include("anvl.hrl").
-include("../include/anvl_test_internal.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(SNK_COLLECTOR, true).
-include("snabbkaffe.hrl").

conf() ->
  #{ plugins => [anvl_erlc, anvl_git, anvl_rebar3, anvl_test]
   , conditions => [all]
   , [deps, git] =>
       [#{ id => familiar
         , repo => "https://github.com/ieQu1/familiar.git"
         , ref => {tag, "0.1.4"}
         }]
   , [deps, local] =>
       [#{ kind => otp_application
         , dir => "../"
         }]
   , [erlang, overrides] =>
       [#{ profile => test
         , sources => ["src/*.erl", "test/*.erl"]
         , compile => #{options => [debug_info, {d, 'TEST'}]}
         }]
   }.

?MEMO(all,
      precondition([suite_load_test(), run_test(), discover_test()])).

?MEMO(discover_test,
      begin
        precondition(built()),
        {ok, [#suite{ suite = att0
                     , runner = anvl_test_suite
                     , tests = Tests0
                     , tags = []
                     , tcs = TCs0
                     }]} = anvl_test_suite:discover(test, anvl_test_test),
        [expected_fail, foo, parent_node_is_hidden, sleepy] = lists:sort(Tests0),
        [ #tc{name = expected_fail, inst = default, tags = [], timeout = 30000}
        , #tc{name = foo, inst = 1, tags = [tag_1], timeout = 1000}
        , #tc{name = foo, inst = 2, tags = [tag_2], timeout = 30000}
        , #tc{name = parent_node_is_hidden, inst = default, tags = [], timeout = 30000}
        , #tc{name = sleepy, inst = default, tags = [], timeout = 200}
        ] = lists:sort(TCs0),
        false
      end).

?MEMO(suite_load_test,
      begin
        precondition(built()),
        {ok, Suite0} = anvl_test_suite:load(att0),
        #suite{ suite = att0
              , runner = anvl_test_suite
              , tests = Tests0
              , tags = []
              , tcs = TCs0
              } = Suite0,
        [expected_fail, foo, parent_node_is_hidden, sleepy] = lists:sort(Tests0),
        [ #tc{name = expected_fail, inst = default, tags = [], timeout = 30000}
        , #tc{name = foo, inst = 1, tags = [tag_1], timeout = 1000}
        , #tc{name = foo, inst = 2, tags = [tag_2], timeout = 30000}
        , #tc{name = parent_node_is_hidden, inst = default, tags = [], timeout = 30000}
        , #tc{name = sleepy, inst = default, tags = [], timeout = 200}
        ] = lists:sort(TCs0),
        false
      end).

?MEMO(run_test,
      begin
        ?check_trace(
           #{timetrap => 30000},
           begin
             precondition(built()),
             {ok, Suite} = anvl_test_suite:load(att0),
             anvl_hook:add(on_test_success,
                           fun({#{tc := #tc{}, workdir := _} = Arg, HookIO}) ->
                               ?tp(on_testcase_success, Arg),
                               {Arg, HookIO}
                           end),
             anvl_hook:add(on_test_fail,
                            fun({#{result := #tc_error{}, workdir := _} = Arg, Retry, Fail, HookIO}) ->
                                ?tp(on_testcase_fail, Arg),
                                {Arg, Retry, Fail, HookIO}
                           end),
             anvl_hook:add(on_test_success, fun selftest_on_success/1),
             anvl_hook:add(on_test_fail, fun selftest_on_fail/1),
             true = anvl_test:run(make_ref(), Suite)
           end,
           fun(Trace) ->
               Successes = ?of_kind(on_testcase_success, Trace),
               [foo, foo, parent_node_is_hidden] =
                 lists:sort([Name || #{tc := #tc{name = Name}} <- Successes]),
               Fails = ?of_kind(on_testcase_fail, Trace),
               [expected_fail, sleepy] =
                 lists:sort([Name || #{tc := #tc{name = Name}} <- Fails]),
               %% The timeout error must carry the stack of the test process:
               [#{result := #tc_error{class = timeout, stack = Stack}}] =
                 [E || #{tc := #tc{name = sleepy}} = E <- Fails],
               true = lists:any(fun({att0, sleepy, _, _}) -> true;
                                   (_) -> false
                                end,
                                Stack),
               ok
           end),
        ok = snabbkaffe:stop(),
        false
      end).

built() ->
  anvl_erlc:app_compiled(test, anvl_test_test).

%% Self-tests: hardcoded list of the test cases that are expected to fail:
expected_failures() ->
  [ {att0, expected_fail, default}
  , {att0, sleepy, default}
  ].

selftest_on_success({#{ suite := Suite
                        , tc := #tc{name = Name, inst = Inst}
                        } = Arg,
                       HookIO}) ->
  case lists:member({Suite, Name, Inst}, expected_failures()) of
    true  -> error({testcase_unexpectedly_passed, Suite, Name, Inst});
    false -> {Arg, HookIO}
  end.

selftest_on_fail({#{ suite := Suite
                   , tc := #tc{name = Name, inst = Inst}
                   } = Arg,
                  Retry,
                  Fail,
                  HookIO}) ->
  case lists:member({Suite, Name, Inst}, expected_failures()) of
    true ->
      logger:notice("~p:~p(~p): this failure is expected", [Suite, Name, Inst]),
      {Arg, Retry, false, HookIO};
    false ->
      {Arg, Retry, Fail, HookIO}
  end.
