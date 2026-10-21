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
""".

%% behavior callbacks:
-export([model/0, project_model/0, init/0, init_for_project/1]).

-export_type([suite/0]).

%% API:
-export([run/1]).

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


%%--------------------------------------------------------------------------
%% anvl callbacks
%%--------------------------------------------------------------------------

-doc false.
init() ->
  anvl_resource:declare(anvl_test, 1),
  application:ensure_all_started(anvl_test).

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

run(#suite{suite = Suite, runner = Runner, tcs = TCs}) ->
  precondition([executed(Runner, Suite, TC) || TC <:- TCs]).

%%--------------------------------------------------------------------------
%% Internal exports
%%--------------------------------------------------------------------------

%%--------------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------------

?MEMO(executed, Runner, Suite, TC,
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
        try
          RpcTimeout = case Timeout of
                          infinity -> infinity;
                          _        -> Timeout + ?TIMEOUT_GRACE_PERIOD
                        end,
          familiar:call(Site, ?MODULE, run_test_with_timeout,
                        [Runner, Suite, Fun, Env, Timeout], RpcTimeout),
          Msg = anvl_logger_formatter:format(
                  success,
                  "✅ ~p:~p(~P)",
                  [Suite, Fun, Instance, 10]),
          ?LOG_NOTICE(Msg)
        catch
          exit:{exception, {test_timeout, _Suite, _Fun, TCStack}} ->
            MsgFail = anvl_logger_formatter:format(
                        error,
                        "❌ ~p:~p(~P) timed out, stack of the test process:~n~p",
                        [Suite, Fun, Instance, 10, TCStack]),
            ?UNSAT(MsgFail, []);
          EC:Err:Stack ->
            MsgFail = anvl_logger_formatter:format(
                        error,
                        "❌ ~p:~p(~P)~n~p:~p~n~p",
                        [Suite, Fun, Instance, 10, EC, Err, Stack]),
            ?UNSAT(MsgFail, [])
        end,
        true
      end).

-doc false.
%% This function is executed on the test site,
%% so the watchdog aborts the execution of the test case there:
-spec run_test_with_timeout(module(), module(), atom(), map(), timeout()) -> term().
run_test_with_timeout(Runner, Suite, Fun, Env, Timeout) ->
  Parent = self(),
  Pid = proc_lib:spawn(fun() ->
                           try Parent ! {self(), Runner:run_test(Suite, Fun, Env, Timeout)}
                           catch EC:Err:Stack ->
                               Parent ! {self(), EC, Err, Stack}
                           end
                       end),
  receive
    {Pid, Ret} ->
      Ret;
    {Pid, EC, Err, Stack} ->
      erlang:raise(EC, Err, Stack)
  after Timeout ->
      {current_stacktrace, TCStack} = process_info(Pid, current_stacktrace),
      exit(Pid, kill),
      exit({test_timeout, Suite, Fun, TCStack})
  end.

?MEMO(dist_started,
      begin
        familiar:ensure_distr(#{hidden => true, name_domain => longnames}),
        false
      end).
