%%================================================================================
%% This file is part of anvl, a parallel general-purpose task
%% execution tool.
%%
%% Copyright (C) 2026 k32
%%
%% This program is free software: you can redistribute it and/or
%% modify it under the terms of the GNU Lesser General Public License
%% version 3, as published by the Free Software Foundation
%%
%% This program is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with this program.  If not, see <https://www.gnu.org/licenses/>.
%%================================================================================

-module(anvl_test).
-moduledoc """
A plugin for running tests.

The plugin defines the following hook points:

@itemize

@item
@code{on_test_success}: called when a test case run succeeds.
The hooks are folded over an accumulator of type @erltp{ref,erlref,anvl_test,on_test_success_acc,0}:
a tuple of the argument map of type @erltp{ref,erlref,anvl_test,on_test_success_arg,0}
and an iolist.
The hooks append their log messages to the iolist,
and the plugin prints it after all hooks complete.

@item
@code{on_test_fail}: called when a test case run fails,
e.g. it crashed or timed out.
The hooks are folded over an accumulator of type @erltp{ref,erlref,anvl_test,on_test_fail_acc,0}:
a tuple of the argument map of type @erltp{ref,erlref,anvl_test,on_test_fail_arg,0},
the @code{@{Retry, Fail@}} flags and an iolist.
Setting @code{Retry} requests re-execution of the test case
(not implemented yet),
and resetting @code{Fail} prevents the condition from failing.
The hooks append their log messages to the iolist,
and the plugin prints it after all hooks complete.

@item
@code{anvl_test_discover}: called when test suites of an OTP application are being discovered.
The hooks take the profile and the application name as arguments,
and return @code{@{ok, Suites@}} or @code{@{error, Suites@}},
with the same semantics as @erlfn{ref,erlref,anvl_test_suite,discover,2}.
The plugin combines the results of all hooks into a single tuple of the same shape.
The default hooks use @erlfn{ref,erlref,anvl_test_suite,discover,2}
and @erlfn{ref,erlref,anvl_test_eunit,discover,2}.

@end itemize

The plugin itself installs default hooks that log the outcome of each test case run.
""".

%% behavior callbacks:
-export([model/0, project_model/0, init/0, init_for_project/1]).

-export_type([suite/0, run_id/0, filter_spec/0, on_test_success_arg/0, on_test_success_acc/0,
              on_test_fail_arg/0, on_test_fail_acc/0, discover_ret/0]).

%% API:
-export([run/2, run/3, run_suite/2, discover/2, code_path_fixture/3]).

%% Internal exports:
-export([run_test_with_timeout/6]).

-include("types.hrl").
-include("anvl.hrl").
-include("anvl_test_internal.hrl").

%% Timeout on the RPC performed by the parent node, added on top of the
%% test case timeout:
-define(TIMEOUT_GRACE_PERIOD, 5000).

%%--------------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------------

-type suite() :: module().

-type run_id() :: term().

-doc """
Specification of a test case filter.

A filter spec is a tuple of a fun and an arbitrary configuration value.
The fun takes the following arguments:

@enumerate
@item the runner module
@item the suite
@item the @code{#tc@{@}} record of the test case
@item the configuration value of the spec
@item the current boolean value of the accumulator
@end enumerate

It returns the next value of the accumulator.

A test case is executed when folding the filter specs of @erlfn{ref,erlref,anvl_test,run_suite,2}
over the accumulator from left to right,
starting with @code{true},
yields @code{true}.
""".
-type filter_spec() ::
        { fun(( Runner :: module()
              , Suite  :: suite()
              , TC     :: #tc{}
              , Conf   :: term()
              , Acc    :: boolean()
              ) -> boolean())
        , Conf :: term()
        }.

-type on_test_success_arg() ::
        #{ run_id  := run_id()
         , runner  := module()
         , suite   := suite()
         , tc      := #tc{}
         , workdir := file:filename_all()
         }.

%% Accumulator of the on_test_success hooks:
-type on_test_success_acc() ::
        { on_test_success_arg()
        , IO :: iolist()
        }.

-type on_test_fail_arg() ::
        #{ run_id  := run_id()
         , runner  := module()
         , suite   := suite()
         , tc      := #tc{}
         , workdir := file:filename_all()
         , result  := #tc_error{}
         }.

%% Return type of the anvl_test_discover hooks. The hooks take the profile
%% and the application name as arguments:
-type discover_ret() :: {ok, [#suite{}]} | {error, [#suite{}]}.

%% Accumulator of the on_test_fail hooks:
-type on_test_fail_acc() ::
        { on_test_fail_arg()
        , Retry :: boolean()
        , Fail  :: boolean()
        , IO    :: iolist()
        }.

%%--------------------------------------------------------------------------
%% anvl callbacks
%%--------------------------------------------------------------------------

-doc false.
init() ->
  anvl_resource:declare(anvl_test, 1),
  application:ensure_all_started(anvl_test),
  install_default_hooks().

-doc false.
init_for_project(_Project) ->
  ok.

-doc false.
model() ->
  #{ anvl_test =>
       #{ max_jobs =>
            {[value, cli_param, anvl_resource],
             #{ oneliner => "Maximum number of tests running in parallel"
              , type => typerefl:range(1, 255)
              , default => 5
              , cli_operand => "j-test"
              , anvl_resource => anvl_test
              }}
        , cover =>
            {[value, cli_param],
             #{ oneliner => "Enable coverage collection and reporting"
              , type => boolean()
              , default => true
              , cli_operand => "erl-cover"
              }}
        , net =>
            {[value, cli_param, os_env],
             #{ oneliner => "Second octet of the loopback network of the test case clusters"
              , type => typerefl:range(0, 255)
              , default => 0
              , cli_operand => "test-net"
              , os_env => "TEST_NET"
              }}
        , log_level =>
            {[value, cli_param, os_env],
             #{ oneliner => "Log level of the test nodes"
              , type => typerefl:union([debug, info, notice, warning, error, critical, alert, emergency])
              , default => info
              , cli_operand => "test-log-level"
              , os_env => "TEST_LOG_LEVEL"
              }}
        , log_handler_config =>
            {[value, cli_param, os_env],
             #{ oneliner => "Logger handler configuration of the test nodes, merged over the defaults"
              , type => map()
              , default => #{}
              , cli_operand => "test-log-handler-config"
              , os_env => "TEST_LOG_HANDLER_CONFIG"
              }}
        , tests =>
            {[map, cli_action],
             #{ oneliner => "Ad-hoc test jobs"
              , cli_operand => "atest"
              , key_elements => []
              },
             #{
              }}
        , eunit =>
            #{ verbose =>
                 {[value, os_env, cli_param],
                  #{ oneliner => "Display more details about the running tests"
                   , type => boolean()
                   , default => true
                   , cli_operand => "eunit-verbose"
                   }}
             , print_depth =>
                 {[value, os_env, cli_param],
                  #{ oneliner => "Maximum depth to which EUnit prints terms in case of error"
                   , type => pos_integer()
                   , default => 100
                   , cli_operand => "eunit-print-depth"
                   }}
             , scale_timeouts =>
                 {[value, os_env, cli_param],
                  #{ oneliner => "Scale EUnit timeouts by this factor"
                   , type => float()
                   , default => 1.0
                   , cli_operand => "eunit-scale-timeouts"
                   }}
             }
        }}.

-doc false.
project_model() ->
  #{ anv_test =>
       #{ extra_apps =>
            {[value],
             #{ oneliner => "Extra applications that have to be loaded on the test nodes"
              , type => list(anvl_erlc:application())
              , default => []
              }}
        }}.

%%--------------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------------

-doc """
Run the test cases of the suite selected by the filters.
A test case runs when folding over @code{Filters} yields @code{true}
(see @erltp{ref,erlref,anvl_test,filter_spec,0}).
The condition fails when a test case fails.
""".
-spec run_suite(#suite{}, [filter_spec()]) -> boolean().
run_suite(#suite{suite = Suite, runner = Runner, runner_options = RunnerOptions, tcs = TCs}, Filters) ->
  RunId = 1,
  precondition([executed(RunId, Runner, RunnerOptions, Suite, TC)
                || TC <:- TCs,
                   passes_filters(Runner, Suite, TC, Filters)]).

-doc false.
-spec passes_filters(module(), suite(), #tc{}, [filter_spec()]) -> boolean().
passes_filters(Runner, Suite, TC, Filters) ->
  lists:foldl(fun({Fun, Conf}, Acc) -> Fun(Runner, Suite, TC, Conf, Acc) end,
              true,
              Filters).

-doc """
Discover the test suites of the OTP application
and run their test cases selected by the filters
(see @code{filter_spec()}).

The suites that could not be loaded are skipped,
but the whole run fails in the end,
because the test selection is incomplete.
The run also fails when a test case fails.
""".
-spec run(anvl_erlc:profile(), anvl_erlc:application(), [filter_spec()]) -> boolean().
run(Profile, App, Filters) ->
  {Status, Suites} = discover(Profile, App),
  Changed = lists:foldl(fun(Suite, Acc) -> run_suite(Suite, Filters) orelse Acc end,
                        false,
                        Suites),
  case Status of
    ok    -> Changed;
    error -> ?UNSAT("Some test suites of the application ~p could not be loaded", [App])
  end.

-doc """
Run all test cases of the OTP application.

Equivalent to @erlfn{ref,erlref,anvl_test,run,3} with an empty filter list.
""".
-spec run(anvl_erlc:profile(), anvl_erlc:application()) -> boolean().
run(Profile, App) ->
  run(Profile, App, []).

-doc """
Discover test suites of an OTP application by running the @code{anvl_test_discover} hooks
and combining their results.
""".
-spec discover(anvl_erlc:profile(), anvl_erlc:application()) -> discover_ret().
discover(Profile, App) ->
  %% Run the hooks and combine their results in a single pass:
  {Suites, AllOk} =
    anvl_hook:traverse(
      fun(Hook, {Suites, AllOk}) ->
          case Hook(Profile, App) of
            {Status, Suites1} ->
              {true, {Suites ++ Suites1, AllOk andalso Status =:= ok}}
          end
      end,
      {[], true},
      anvl_test_discover),
  case AllOk of
    true  -> {ok, Suites};
    false -> {error, Suites}
  end.

-doc """
Create a standard fixture for loading the code.
""".
-spec code_path_fixture(anvl_project:t(), anvl_erlc:profile(), anvl_erlc:application()) -> familiar:fixture().
code_path_fixture(Project, Profile, App) ->
  Extra = anvl_project:conf(Project, [anvl_test, extra_apps]),
  precondition([anvl_erlc:anvl_compiled(Profile, I) || I <- Extra]),
  {Apps, _} = anvl_erlc:app_closure(Profile, [App, [anvl_test | Extra]]),
  [anvl_erlc:app_path(Profile, I) || I <- Apps].

%%--------------------------------------------------------------------------
%% Internal exports
%%--------------------------------------------------------------------------

%%--------------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------------

%% RunId is a dummy argument that's not used by the logic of the memo.
%% It's part of the memoization key, so a failed (e.g. flaky) test case
%% can be re-run with a different RunId, without memoization getting in
%% the way:
?MEMO(executed, RunId, Runner, RunnerOptions, Suite, TC,
      begin
        precondition(dist_started()),
        #tc{name = Fun, inst = Instance, fixtures = Fixtures0, timeout = Timeout} = TC,
        SiteId = list_to_binary(peer:random_name(atom_to_list(Fun))),
        Cluster = SiteId,
        %% Limit the number of test cases running in parallel. Note: the
        %% resource cannot be held while invoking preconditions, so the
        %% result handling is kept outside of the critical section:
        Fixtures = ensure_default_fixtures(Fixtures0),
        {Result, Workdir} =
          anvl_resource:with(
            anvl_test,
            fun() ->
                Subnet = anvl_test_subnet:take(),
                try
                  Net = anvl_plugin:conf([anvl_test, net]),
                  Env = #{ instance => Instance
                         , familiar => #{net => Subnet, subnet => 24}
                         },
                  Conf = #{ id                 => Cluster
                          , fixtures           => Fixtures
                          , peer               => #{}
                          , net                => {127, Net, Subnet, 0}
                          , subnet             => 24
                          , fixture_init_state => Env
                          },
                  ok = familiar:start_link_cluster(Conf),
                  %% Note: the cluster fixtures propagate to the sites, so
                  %% they must not be repeated in the site spec:
                  {ok, Site, _Node} = familiar:create_site(Cluster, SiteId,
                                                           #{ start => true
                                                            }),
                  #{workdir := Workdir} = FixtureState = familiar:fixture_state(Site),
                  RpcTimeout = case Timeout of
                                  infinity -> infinity;
                                  _        -> Timeout + ?TIMEOUT_GRACE_PERIOD
                                end,
                  Result =
                    familiar:call(
                      Site, ?MODULE, run_test_with_timeout,
                      [ Runner
                      , RunnerOptions
                      , Suite
                      , Fun
                      , maps:merge(FixtureState, Env)
                      , Timeout
                      ],
                      RpcTimeout),
                  familiar:stop_cluster(Cluster, Result =:= ok),
                  {Result, Workdir}
                after
                  anvl_test_subnet:release(Subnet)
                end
            end),
        case Result of
          ok ->
            Arg = #{ run_id => RunId
                   , runner => Runner
                   , suite  => Suite
                   , tc     => TC
                   , workdir => Workdir
                   },
            {_Arg, HookIO} = anvl_hook:fold(on_test_success, {Arg, []}),
            ?LOG_NOTICE("~ts", [HookIO]),
            true;
          #tc_error{} ->
            Arg = #{ run_id => RunId
                   , runner => Runner
                   , suite  => Suite
                   , tc     => TC
                   , workdir => Workdir
                   , result => Result
                   },
            {_Arg, _Retry, Fail, HookIO} = anvl_hook:fold(on_test_fail, {Arg, false, true, []}),
            ?LOG_ERROR("~ts", [HookIO]),
            %% TODO: When Retry is true, re-run the test case with a fresh RunId
            case Fail of
              true  -> ?UNSAT("Test failed", []);
              false -> true
            end
        end
      end).

-doc false.
%% This function is executed on the test site,
%% so the watchdog aborts the execution of the test case there:
%% Errors of the test case are returned as records
%% instead of exceptions, to distinguish them from infrastructure errors:
-spec run_test_with_timeout(module(), term(), module(), atom(), map(), timeout()) ->
        ok | #tc_error{}.
run_test_with_timeout(Runner, RunnerOptions, Suite, Fun, Env, Timeout) ->
  Parent = self(),
  Pid = proc_lib:spawn(fun() ->
                           try
                             _ = Runner:run_test(RunnerOptions, Suite, Fun, Env, Timeout),
                             Parent ! {self(), ok}
                           catch Class:Reason:Stack ->
                               Parent ! {self(), #tc_error{ class = Class
                                                          , reason = Reason
                                                          , stack = Stack
                                                          }}
                           end
                       end),
  receive
    {Pid, Ret} ->
      Ret
  after Timeout ->
      {current_stacktrace, TCStack} = process_info(Pid, current_stacktrace),
      exit(Pid, kill),
      #tc_error{class = timeout, reason = Timeout, stack = TCStack}
  end.

%% Default hooks installed by the plugin. They report the outcome of the
%% test case runs:
-spec install_default_hooks() -> ok.
install_default_hooks() ->
  anvl_hook:add(on_test_success, fun log_test_success/1),
  anvl_hook:add(on_test_fail, fun log_test_fail/1),
  anvl_hook:add(anvl_test_discover, fun anvl_test_suite:discover/2),
  anvl_hook:add(anvl_test_discover, fun anvl_test_eunit:discover/2),
  ok.

-spec log_test_success(on_test_success_acc()) -> on_test_success_acc().
log_test_success({#{ suite := Suite
                   , tc := #tc{name = Fun, inst = Instance}
                   } = Arg,
                  HookIO}) ->
  Msg = anvl_logger_formatter:format(
          success,
          "✅ ~p:~p(~P)",
          [Suite, Fun, Instance, 10]),
  {Arg, [HookIO, Msg]}.

-spec log_test_fail(on_test_fail_acc()) -> on_test_fail_acc().
log_test_fail({#{ suite := Suite
                , tc := #tc{name = Fun, inst = Instance}
                , workdir := Workdir
                , result := Result
                } = Arg,
               Retry,
               Fail,
               HookIO}) ->
  MsgFail =
    case Result of
      #tc_error{class = timeout, stack = TCStack} ->
        anvl_logger_formatter:format(
          error,
          "❌ ~p:~p(~P)~nworkdir: ~s~ntimed out, stack of the test process:~n~p",
          [Suite, Fun, Instance, 10, Workdir, TCStack]);
      #tc_error{class = Class, reason = Reason, stack = Stack} ->
        anvl_logger_formatter:format(
          error,
          "❌ ~p:~p(~P)~nworkdir: ~s~n~p:~p~n~p",
          [Suite, Fun, Instance, 10, Workdir, Class, Reason, Stack])
    end,
  {Arg, Retry, Fail, [HookIO, MsgFail]}.

%% Each test case cluster runs in a dedicated working directory created by
%% the familiar_workdir fixture, and familiar_logger writes the node logs
%% there. These fixtures are mandatory: the user cannot override them:
-spec ensure_default_fixtures([familiar:fixture()]) -> [familiar:fixture()].
ensure_default_fixtures(Fixtures0) ->
  LogLevel = anvl_plugin:conf([anvl_test, log_level]),
  RootDir = anvl_fn:workdir([?MODULE]),
  HandlerConfig =
    maps:merge(#{level => LogLevel}, anvl_plugin:conf([anvl_test, log_handler_config])),
  Defaults = [ {familiar_workdir, #{root => RootDir}}
             , {familiar_logger, #{ primary_config => #{level => LogLevel}
                                  , handler_config => HandlerConfig
                                  }}
             ],
  Overrides = [F || {F, _} <- Fixtures0, lists:keymember(F, 1, Defaults)],
  case Overrides of
    [] ->
      ok;
    _ ->
      ?LOG_WARNING("~p fixtures are mandatory and cannot be overridden", [Overrides])
  end,
  Fixtures = [Fix || {F, _} = Fix <- Fixtures0, not lists:keymember(F, 1, Defaults)],
  Defaults ++ Fixtures.

?MEMO(dist_started,
      begin
        familiar:ensure_distr(#{hidden => true, name_domain => longnames}),
        false
      end).
