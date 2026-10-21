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
      precondition([suite_load_test(), run_test(), discover_test(), timeout_test()])).

?MEMO(timeout_test,
      begin
        precondition(built()),
        #tc_error{class = timeout, stack = TCStack} =
          anvl_test:run_test_with_timeout(anvl_test_suite, att0, sleepy,
                                          #{instance => default}, 100),
        %% The stack of the timed out test process must be reported:
        true = lists:any(fun({M, F, _, _}) -> M =:= att0 andalso F =:= sleepy;
                            (_) -> false
                         end,
                         TCStack),
        false
      end).

?MEMO(discover_test,
      begin
        precondition(built()),
        {ok, [#suite{ suite = att0
                     , runner = anvl_test_suite
                     , tests = Tests0
                     , tags = []
                     , tcs = TCs0
                     }]} = anvl_test_suite:discover(test, anvl_test_test),
        [foo, parent_node_is_hidden] = lists:sort(Tests0),
        [ #tc{name = foo, inst = 1, tags = [tag_1], timeout = 1000}
        , #tc{name = foo, inst = 2, tags = [tag_2], timeout = 30000}
        , #tc{name = parent_node_is_hidden, inst = default, tags = [], timeout = 30000}
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
        [foo, parent_node_is_hidden] = lists:sort(Tests0),
        [ #tc{name = foo, inst = 1, tags = [tag_1], timeout = 1000}
        , #tc{name = foo, inst = 2, tags = [tag_2], timeout = 30000}
        , #tc{name = parent_node_is_hidden, inst = default, tags = [], timeout = 30000}
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
                           fun(#{tc := #tc{}} = Arg) ->
                               ?tp(on_testcase_success, Arg),
                               false
                           end),
             anvl_hook:add(on_test_fail,
                            fun({#{result := #tc_error{}} = Arg, Retry, Fail}) ->
                                ?tp(on_testcase_fail, Arg),
                                {Arg, Retry, Fail}
                           end),
             true = anvl_test:run(make_ref(), Suite)
           end,
           fun(Trace) ->
               Successes = ?of_kind(on_testcase_success, Trace),
               [foo, foo, parent_node_is_hidden] =
                 lists:sort([Name || #{tc := #tc{name = Name}} <- Successes]),
               [] = ?of_kind(on_testcase_fail, Trace),
               ok
           end),
        ok = snabbkaffe:stop(),
        false
      end).

built() ->
  anvl_erlc:app_compiled(test, anvl_test_test).
