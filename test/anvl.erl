-include("anvl.hrl").
-include("../src/anvl_test_internal.hrl").
-include_lib("stdlib/include/assert.hrl").

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
      precondition([suite_load_test(), run_test()])).

?MEMO(suite_load_test,
      begin
        precondition(built()),
        {ok, Suite0} = anvl_test_suite:load(att0),
        #suite{ mod = att0
              , tests = Tests0
              , tags = []
              , tcs = TCs0
              } = Suite0,
        [foo, parent_node_is_hidden] = lists:sort(Tests0),
        [ #tc{name = foo, inst = 1, tags = [tag_1]}
        , #tc{name = foo, inst = 2, tags = [tag_2]}
        , #tc{name = parent_node_is_hidden, inst = default, tags = []}
        ] = lists:sort(TCs0),
        false
      end).

?MEMO(run_test,
      begin
        precondition(built()),
        {ok, Suite} = anvl_test_suite:load(att0),
        anvl_test_suite:run(Suite)
      end).

built() ->
  anvl_erlc:app_compiled(test, anvl_test_test).
