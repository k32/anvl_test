-include("anvl.hrl").

conf() ->
  #{ plugins => [anvl_erlc, anvl_git, anvl_rebar3, anvl_test]
   , conditions => [all]
   , [erlang, includes] => ["${src_root}/include", "${src_root}/src", anvl_plugin:includes_dir()]
   , deps =>
       #{ local =>
            [#{ kind => otp_application
              , dir => "../"
              }
           ,#{ kind => otp_application
              , dir => "../familiar"
              }]
        }
   , [erlang, overrides] =>
       [#{ profile => test
         , sources => ["src/*.erl", "test/*.erl"]
         , compile => #{options => [debug_info, {d, 'TEST'}]}
         }]
   , [anvl_test, extra_apps] => [snabbkaffe]
   }.

%% Build the test application and run the self-test conditions of the
%% anvl_test_tests module:
?MEMO(all,
      begin
        precondition(anvl_erlc:app_compiled(test, anvl_test_test)),
        Ctx = anvl_erlc:app_info(test, anvl_test_test),
        Beam = anvl_erlc:beam_file(Ctx, anvl_test_tests),
        case code:is_loaded(anvl_test_tests) of
          {file, Beam} ->
            ok;
          _ ->
            {module, anvl_test_tests} = code:load_abs(filename:rootname(Beam))
        end,
        precondition(anvl_test_tests:all())
      end).
