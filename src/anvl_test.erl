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
The hooks take a map of type @code{anvl_test:on_test_success_arg()}.

@item
@code{on_test_fail}: called when a test case run fails,
e.g. it crashed or timed out.
The hooks are folded over an accumulator of type @code{anvl_test:on_test_fail_acc()}:
a tuple of the argument map of type @code{anvl_test:on_test_fail_arg()}
and the @code{@{Retry, Fail@}} flags.
Setting @code{Retry} requests re-execution of the test case,
and resetting @code{Fail} prevents the condition from failing.

@end itemize

The plugin itself installs default hooks that log the outcome of each test case run.
""".

%% behavior callbacks:
-export([model/0, project_model/0, init/0, init_for_project/1]).

-export_type([suite/0, run_id/0, on_test_success_arg/0, on_test_fail_arg/0, on_test_fail_acc/0]).

%% API:
-export([run/2]).

%% Internal exports:
-export([run_test_with_timeout/5]).

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

-type on_test_success_arg() ::
        #{ run_id := run_id()
         , runner := module()
         , suite  := suite()
         , tc     := #tc{}
         }.

-type on_test_fail_arg() ::
        #{ run_id := run_id()
         , runner := module()
         , suite  := suite()
         , tc     := #tc{}
         , result := #tc_error{}
         }.

%% Accumulator of the on_test_fail hooks:
-type on_test_fail_acc() ::
        { on_test_fail_arg()
        , Retry :: boolean()
        , Fail  :: boolean()
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
              , type => non_neg_integer()
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
        , tests =>
            {[map, cli_action],
             #{ oneliner => "Ad-hoc test jobs"
              , cli_operand => "atest"
              , key_elements => []
              },
             #{
              }}
        }}.

-doc false.
project_model() ->
  #{ anv_test =>
       #{}}.

%%--------------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------------

-spec run(run_id(), #suite{}) -> boolean().
run(RunId, #suite{suite = Suite, runner = Runner, tcs = TCs}) ->
  precondition([executed(RunId, Runner, Suite, TC) || TC <:- TCs]).

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
?MEMO(executed, RunId, Runner, Suite, TC,
      begin
        precondition(dist_started()),
        #tc{name = Fun, inst = Instance, fixtures = Fixtures, timeout = Timeout} = TC,
        SiteId = list_to_binary(peer:random_name(atom_to_list(Fun))),
        Cluster = SiteId,
        %% FIXME:
        N1 = rand:uniform(256) - 1,
        N2 = rand:uniform(256) - 1,
        Conf = #{ id       => Cluster
                , fixtures => Fixtures
                , peer     => #{}
                , net      => {127, N1, N2, 0}
                , subnet   => 24
                },
        ok = familiar:start_link_cluster(Conf),
        {ok, Site, _Node} = familiar:create_site(Cluster, SiteId,
                                                 #{ start => true
                                                  , fixtures => Fixtures
                                                  }),
        Env = #{instance => Instance},
        RpcTimeout = case Timeout of
                        infinity -> infinity;
                        _        -> Timeout + ?TIMEOUT_GRACE_PERIOD
                      end,
        case familiar:call(Site, ?MODULE, run_test_with_timeout,
                           [Runner, Suite, Fun, Env, Timeout], RpcTimeout) of
          ok ->
            _ = anvl_hook:foreach(on_test_success, #{ run_id => RunId
                                                   , runner => Runner
                                                   , suite  => Suite
                                                   , tc     => TC
                                                   }),
            true;
          #tc_error{} = Result ->
            Arg = #{ run_id => RunId
                   , runner => Runner
                   , suite  => Suite
                   , tc     => TC
                   , result => Result
                   },
            {_Arg, _Retry, Fail} = anvl_hook:fold(on_test_fail, {Arg, false, true}),
            %% TODO: When Retry is true, re-run the test case with a fresh RunId
            case Fail of
              true  -> exit(unsat);
              false -> true
            end
        end,
        true
      end).

-doc false.
%% This function is executed on the test site,
%% so the watchdog aborts the execution of the test case there:
%% Errors of the test case are returned as records
%% instead of exceptions, to distinguish them from infrastructure errors:
-spec run_test_with_timeout(module(), module(), atom(), map(), timeout()) ->
        ok | #tc_error{}.
run_test_with_timeout(Runner, Suite, Fun, Env, Timeout) ->
  Parent = self(),
  Pid = proc_lib:spawn(fun() ->
                           try
                             _ = Runner:run_test(Suite, Fun, Env, Timeout),
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
  ok.

-spec log_test_success(on_test_success_arg()) -> false.
log_test_success(#{ suite := Suite
                  , tc := #tc{name = Fun, inst = Instance}
                  }) ->
  Msg = anvl_logger_formatter:format(
          success,
          "✅ ~p:~p(~P)",
          [Suite, Fun, Instance, 10]),
  ?LOG_NOTICE(Msg),
  false.

-spec log_test_fail(on_test_fail_acc()) -> on_test_fail_acc().
log_test_fail({#{ suite := Suite
                , tc := #tc{name = Fun, inst = Instance}
                , result := Result
                } = Arg,
               Retry,
               Fail}) ->
  MsgFail =
    case Result of
      #tc_error{class = timeout, stack = TCStack} ->
        anvl_logger_formatter:format(
          error,
          "❌ ~p:~p(~P) timed out, stack of the test process:~n~p",
          [Suite, Fun, Instance, 10, TCStack]);
      #tc_error{class = Class, reason = Reason, stack = Stack} ->
        anvl_logger_formatter:format(
          error,
          "❌ ~p:~p(~P)~n~p:~p~n~p",
          [Suite, Fun, Instance, 10, Class, Reason, Stack])
    end,
  ?LOG_CRITICAL(MsgFail),
  {Arg, Retry, Fail}.

?MEMO(dist_started,
      begin
        familiar:ensure_distr(#{hidden => true, name_domain => longnames}),
        false
      end).
