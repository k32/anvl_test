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

%% API:
-export([run/1]).

-include("types.hrl").
-include("anvl.hrl").
-include("anvl_test_internal.hrl").

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

run(#suite{mod = Mod, tcs = TCs}) ->
  precondition([executed(Fixtures, Mod, Name, Inst) || #tc{name = Name, inst = Inst, fixtures = Fixtures} <:- TCs]).

%%--------------------------------------------------------------------------
%% Internal exports
%%--------------------------------------------------------------------------

%%--------------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------------

?MEMO(executed, Fixtures, Mod, Fun, Instance,
      begin
        precondition(dist_started()),
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
          familiar:call(Site, Mod, Fun, [run, Env]),
          Msg = anvl_logger_formatter:format(
                  success,
                  "✅ ~p:~p(~P)",
                  [Mod, Fun, Instance, 10]),
          ?LOG_NOTICE(Msg)
        catch
          EC:Err:Stack ->
            MsgFail = anvl_logger_formatter:format(
                        error,
                        "❌ ~p:~p(~P)~n~p:~p~n~p",
                        [Mod, Fun, Instance, 10, EC, Err, Stack]),
            ?UNSAT(MsgFail, [])
        end,
        true
      end).

?MEMO(dist_started,
      begin
        familiar:ensure_distr(#{hidden => true, name_domain => longnames}),
        false
      end).
