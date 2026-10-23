%% Self-tests of the anvl_test plugin, run as conditions of the test
%% project: anvl.erl builds the application, loads this module and
%% delegates to all/0.

-module(anvl_test_tests).

-include("anvl.hrl").
-include_lib("anvl_test/include/anvl_test_internal.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(SNK_COLLECTOR, true).
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

%% API:
-export([all/0]).

?MEMO(all,
      precondition([suite_load_test(), run_test(), discover_test()])).

?MEMO(discover_test,
      begin
        %% The suites are discovered via the anvl_test_discover hooks:
        {ok, Suites0} = anvl_test:discover(test, anvl_test_test),
        %% One suite per application, with one test case per EUnit test
        %% module; the test cases of the att0 suite are checked by
        %% suite_load_test:
        [ #suite{ suite = anvl_test_test
                , runner = anvl_test_eunit
                , tags = []
                , tcs = EUnitTCs
                }
        , #suite{ suite = att0
                , runner = anvl_test_suite
                , tags = []
                }
        ] = lists:keysort(#suite.suite, Suites0),
        %% One test case per EUnit test module of the application:
        CodePathFixture = anvl_test:code_path_fixture(anvl_project:root(), test, anvl_test_test),
        ?assertEqual(
           [ #tc{ name = att_eunit, inst = default, tags = []
                 , fixtures = [CodePathFixture], timeout = infinity
                 }
           , #tc{ name = att_eunit_fail, inst = default, tags = []
                 , fixtures = [CodePathFixture], timeout = infinity
                 }
           ],
           lists:sort(EUnitTCs)),
        false
      end).

?MEMO(suite_load_test,
      begin
        {ok, #suite{ tcs = TCs0 } = Suite0} = anvl_test_suite:load(anvl_project:root(), test, anvl_test_test, att0),
        ?assertEqual(att0, Suite0#suite.suite),
        ?assertEqual(anvl_test_suite, Suite0#suite.runner),
        ?assertEqual([], Suite0#suite.tags),
        ?assertEqual(expected_tcs(), lists:sort(TCs0)),
        false
      end).

?MEMO(run_test,
      begin
        ?check_trace(
           #{timetrap => 30000},
           begin
             {ok, Suite} = anvl_test_suite:load(anvl_project:root(), test, anvl_test_test, att0),
             register_test_hooks(),
             ?assert(anvl_test:run_suite(Suite, [])),
             %% Run the EUnit suite discovered in the same application:
             {ok, Suites} = anvl_test:discover(test, anvl_test_test),
             [AttEunit] = [S || #suite{runner = anvl_test_eunit} = S <- Suites],
             %% The filter funs must be consulted for each test case:
             Crash = fun(_, _, _, _, _) -> error(filter_crash) end,
             ?assertEqual(
                failed,
                try anvl_test:run_suite(AttEunit, [{Crash, unused}]) of
                  _ -> not_failed
                catch
                  _:_ -> failed
                end),
             %% Test cases excluded by the filters don't run:
             ExcludeAll = fun(_, _, _, _, _) -> false end,
             _ = anvl_test:run_suite(AttEunit, [{ExcludeAll, unused}]),
             ?assert(anvl_test:run_suite(AttEunit, [])),
             %% Check the arguments passed to the filter funs:
             CheckArgs = fun(anvl_test_eunit, anvl_test_test, #tc{}, config, Acc) ->
                             ?assert(is_boolean(Acc)),
                             Acc
                          end,
             _ = anvl_test:run_suite(AttEunit, [{CheckArgs, config}]),
             %% The combined discover-and-run API:
             _ = anvl_test:run(test, anvl_test_test, [{ExcludeAll, unused}]),
             _ = anvl_test:run(test, anvl_test_test)
           end,
           fun(Trace) ->
               Successes = ?of_kind(on_testcase_success, Trace),
               ?assertEqual(
                  [cluster, foo, foo, multi_site_cluster, multi_site_cluster, parent_node_is_hidden],
                  lists:sort([Name || #{ suite := att0
                                       , tc := #tc{name = Name}
                                       } <- Successes])),
               ?assertEqual(
                  [anvl_test_test],
                  [M || #{ suite := M
                         , tc := #tc{name = att_eunit}
                         } <- Successes]),
               Fails = ?of_kind(on_testcase_fail, Trace),
               ?assertEqual(
                  [expected_fail, sleepy],
                  lists:sort([Name || #{ suite := att0
                                       , tc := #tc{name = Name}
                                       } <- Fails])),
               ?assertEqual(
                  [anvl_test_test],
                  [M || #{ suite := M
                         , tc := #tc{name = att_eunit_fail}
                         } <- Fails]),
               %% The timeout error must carry the stack of the test process;
               %% the stack is checked below, so match it directly:
               [#{result := #tc_error{class = timeout, stack = Stack}}] =
                 [E || #{tc := #tc{name = sleepy}} = E <- Fails],
               ?assert(
                  lists:any(fun({att0, sleepy, _, _}) -> true;
                              (_) -> false
                           end,
                           Stack)),
               %% Workdirs of the failed test cases must be preserved,
               %% with the logs inside:
               lists:foreach(
                 fun(#{workdir := WD}) ->
                     ?assert(filelib:is_dir(WD)),
                     ?assert(filelib:is_regular(filename:join(WD, "erlang.log")))
                 end,
                 Fails),
               ok
           end),
        ok = snabbkaffe:stop(),
        false
      end).

%% The test cases of the att0 suite, as they must be discovered from the
%% module, sorted by name and instance:
expected_tcs() ->
  CodePathFixture = anvl_test:code_path_fixture(anvl_project:root(), test, anvl_test_test),
  ClusterFixtures = [ CodePathFixture
                    , {anvl_test_cluster, #{}}
                    ],
  GlobalFixtures = [ CodePathFixture
                   , {familiar_workdir, #{}}
                   ],
  [ #tc{ name = cluster, inst = default, tags = []
        , fixtures = ClusterFixtures
        , timeout = 30000
        }
  , #tc{ name = expected_fail, inst = default, tags = []
        , fixtures = GlobalFixtures
        , timeout = 30000
        }
  , #tc{ name = foo, inst = 1, tags = [tag_1]
        , fixtures = GlobalFixtures
        , timeout = 1000
        }
  , #tc{ name = foo, inst = 2, tags = [tag_2]
        , fixtures = GlobalFixtures
        , timeout = 30000
        }
  , #tc{ name = multi_site_cluster, inst = 1, tags = []
        , fixtures = ClusterFixtures
        , timeout = 30000
        }
  , #tc{ name = multi_site_cluster, inst = 2, tags = []
        , fixtures = ClusterFixtures
        , timeout = 30000
        }
  , #tc{ name = parent_node_is_hidden, inst = default, tags = []
        , fixtures = GlobalFixtures
        , timeout = 30000
        }
  , #tc{ name = sleepy, inst = default, tags = []
        , fixtures = GlobalFixtures
        , timeout = 200
        }
  ].

%% Install hooks that record the test case events as snabbkaffe traces,
%% plus the self-test hooks checking the expected failures:
register_test_hooks() ->
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
  anvl_hook:add(on_test_fail, fun selftest_on_fail/1).

%% Self-tests: hardcoded list of the test cases that are expected to fail:
expected_failures() ->
  [ {att0, expected_fail, default}
  , {att0, sleepy, default}
  , {anvl_test_test, att_eunit_fail, default}
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
