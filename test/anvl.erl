-include("anvl.hrl").
-include("../include/anvl_test_internal.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(SNK_COLLECTOR, true).
-include("snabbkaffe.hrl").

conf() ->
  #{ plugins => [anvl_erlc, anvl_git, anvl_rebar3, anvl_test]
   , conditions => [all]
   , deps =>
       #{ git =>
            [#{ id => familiar
              , repo => "https://github.com/ieQu1/familiar.git"
              , ref => {tag, "0.1.6"}
              }]
        , local =>
            [#{ kind => otp_application
              , dir => "../"
              }]
        }
   , [erlang, overrides] =>
       [#{ profile => test
         , sources => ["src/*.erl", "test/*.erl"]
         , compile => #{options => [debug_info, {d, 'TEST'}]}
         }]
   , [anvl_test, extra_apps] => [snabbkaffe]
   }.

?MEMO(all,
      precondition([serial_tests(), suite_load_test(), run_test(), discover_test()])).

%% The peer nodes of the nested clusters flake when several test cases
%% bootstrap them at the same time, so run the test cases one by one:
?MEMO(serial_tests,
      begin
        anvl_resource:set_max(anvl_test, 1),
        false
      end).

?MEMO(discover_test,
      begin
        precondition(built()),
        %% The suites are discovered via the anvl_test_discover hooks:
        {ok, Suites0} = anvl_test:discover(test, anvl_test_test),
        [ #suite{ suite = att0
                , runner = anvl_test_suite
                , tests = Tests0
                , tags = []
                , tcs = TCs0
                }
        , #suite{ suite = att_eunit
                , runner = anvl_test_eunit
                , tests = [eunit]
                , tags = []
                , tcs = [#tc{ name = eunit
                            , inst = default
                            , timeout = infinity
                            }]
                }
        , #suite{ suite = att_eunit_fail
                , runner = anvl_test_eunit
                , tests = [eunit]
                , tags = []
                , tcs = [#tc{ name = eunit
                            , inst = default
                            , timeout = infinity
                            }]
                }
        ] = lists:keysort(#suite.suite, Suites0),
        [cluster, expected_fail, foo, multi_site_cluster, parent_node_is_hidden, sleepy] = lists:sort(Tests0),
        [ #tc{name = cluster, inst = default, tags = [], timeout = 30000}
        , #tc{name = expected_fail, inst = default, tags = [], timeout = 30000}
        , #tc{name = foo, inst = 1, tags = [tag_1], timeout = 1000}
        , #tc{name = foo, inst = 2, tags = [tag_2], timeout = 30000}
        , #tc{name = multi_site_cluster, inst = 1, tags = [], timeout = 30000}
        , #tc{name = multi_site_cluster, inst = 2, tags = [], timeout = 30000}
        , #tc{name = parent_node_is_hidden, inst = default, tags = [], timeout = 30000}
        , #tc{name = sleepy, inst = default, tags = [], timeout = 200}
        ] = lists:sort(TCs0),
        false
      end).

?MEMO(suite_load_test,
      begin
        precondition(built()),
        {ok, Suite0} = anvl_test_suite:load(anvl_project:root(), test, anvl_test_test, att0),
        #suite{ suite = att0
              , runner = anvl_test_suite
              , tests = Tests0
              , tags = []
              , tcs = TCs0
              } = Suite0,
        [cluster, expected_fail, foo, multi_site_cluster, parent_node_is_hidden, sleepy] = lists:sort(Tests0),
        [ #tc{name = cluster, inst = default, tags = [], timeout = 30000}
        , #tc{name = expected_fail, inst = default, tags = [], timeout = 30000}
        , #tc{name = foo, inst = 1, tags = [tag_1], timeout = 1000}
        , #tc{name = foo, inst = 2, tags = [tag_2], timeout = 30000}
        , #tc{name = multi_site_cluster, inst = 1, tags = [], timeout = 30000}
        , #tc{name = multi_site_cluster, inst = 2, tags = [], timeout = 30000}
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
             {ok, Suite} = anvl_test_suite:load(anvl_project:root(), test, anvl_test_test, att0),
             register_test_hooks(),
             true = anvl_test:run_suite(Suite, []),
             %% Run the EUnit suites discovered in the same application:
             {ok, Suites} = anvl_test:discover(test, anvl_test_test),
             EUnitSuites = [S || #suite{runner = anvl_test_eunit} = S <- Suites],
             AttEunit = lists:keyfind(att_eunit, #suite.suite, EUnitSuites),
             %% The filter funs must be consulted for each test case:
             Crash = fun(_, _, _, _, _) -> error(filter_crash) end,
             failed = try anvl_test:run_suite(AttEunit, [{Crash, unused}]) of
                        _ -> not_failed
                      catch
                        _:_ -> failed
                      end,
             %% Test cases excluded by the filters don't run:
             ExcludeAll = fun(_, _, _, _, _) -> false end,
             _ = anvl_test:run_suite(AttEunit, [{ExcludeAll, unused}]),
             lists:foreach(fun(S) -> true = anvl_test:run_suite(S, []) end,
                           EUnitSuites),
             %% Check the arguments passed to the filter funs:
             CheckArgs = fun(anvl_test_eunit, att_eunit, #tc{name = eunit}, config, Acc) ->
                             true = is_boolean(Acc),
                             Acc
                          end,
             _ = anvl_test:run_suite(AttEunit, [{CheckArgs, config}]),
             %% The combined discover-and-run API:
             _ = anvl_test:run(test, anvl_test_test, [{ExcludeAll, unused}]),
             _ = anvl_test:run(test, anvl_test_test)
           end,
           fun(Trace) ->
               Successes = ?of_kind(on_testcase_success, Trace),
               [cluster, foo, foo, multi_site_cluster, multi_site_cluster, parent_node_is_hidden] =
                 lists:sort([Name || #{ suite := att0
                                      , tc := #tc{name = Name}
                                      } <- Successes]),
               [att_eunit] =
                 [M || #{ suite := M
                        , tc := #tc{name = eunit}
                        } <- Successes],
               Fails = ?of_kind(on_testcase_fail, Trace),
               [expected_fail, sleepy] =
                 lists:sort([Name || #{ suite := att0
                                      , tc := #tc{name = Name}
                                      } <- Fails]),
               [att_eunit_fail] =
                 [M || #{ suite := M
                        , tc := #tc{name = eunit}
                        } <- Fails],
               %% The timeout error must carry the stack of the test process:
               [#{result := #tc_error{class = timeout, stack = Stack}}] =
                 [E || #{tc := #tc{name = sleepy}} = E <- Fails],
               true = lists:any(fun({att0, sleepy, _, _}) -> true;
                                   (_) -> false
                                end,
                                Stack),
               %% Workdirs of the failed test cases must be preserved,
               %% with the logs inside:
               lists:foreach(
                 fun(#{workdir := WD}) ->
                     true = filelib:is_dir(WD),
                     true = filelib:is_regular(filename:join(WD, "erlang.log"))
                 end,
                 Fails),
               ok
           end),
        ok = snabbkaffe:stop(),
        false
      end).

built() ->
  anvl_erlc:app_compiled(test, anvl_test_test).

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
  , {att_eunit_fail, eunit, default}
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
