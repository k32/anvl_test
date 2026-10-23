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

-module(anvl_test_eunit).
-moduledoc """
Runner for EUnit test modules.

Each OTP application containing EUnit test modules,
i.e. modules with exported functions of arity 0
with names ending in @code{_test} or @code{_test_},
is mapped to a suite with one test case per such module,
which executes all the EUnit tests of the module via @code{eunit:test/1} on the test site.
EUnit manages its own test structure, fixtures and timeouts.

Note: modules named like @code{foo_tests} are skipped when @code{foo} is
present in the same application, because @code{eunit:test/1} runs their
tests as part of @code{foo}.
""".

-behavior(anvl_test_runner).

%% behavior callbacks:
-export([run_test/5, discover/2]).

-include("types.hrl").
-include("anvl.hrl").
-include("anvl_test_internal.hrl").

%%--------------------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------------------

%% Name of the test case of an EUnit suite: the module with the EUnit tests:
-type test() :: module().

%%--------------------------------------------------------------------------------
%% behavior callbacks
%%--------------------------------------------------------------------------------

-doc false.
-spec run_test(list(), anvl_erlc:application(), test(), map(), timeout()) -> ok.
run_test(Options, _App, Module, _Env, _Timeout) ->
  case eunit:test(Module, Options) of
    ok             -> ok;
    error          -> error(eunit_failed);
    {error, _} = E -> error(E)
  end.

-doc """
Discover the EUnit test modules of the OTP application.
""".
-spec discover(anvl_erlc:profile(), anvl_erlc:application()) -> {ok, [#suite{}]} | {error, [#suite{}]}.
discover(Profile, App) ->
  _ = precondition(anvl_erlc:app_compiled(Profile, App)),
  Ctx = anvl_erlc:app_info(Profile, App),
  Modules = anvl_erlc:app_modules(Profile, App),
  TCs = [tc(Module) || Module <- Modules
                     , has_eunit_tests(Ctx, Module)
                     , not is_chained(Module, Modules)
                     ],
  case TCs of
    [] -> {ok, []};
    _  -> {ok, [suite(App, TCs)]}
  end.

%%--------------------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------------------

-spec suite(anvl_erlc:application(), [#tc{}]) -> #suite{}.
suite(App, TCs) ->
  Options = [ {print_depth, anvl_plugin:conf([anvl_test, eunit, print_depth])}
            , {scale_timeouts, anvl_plugin:conf([anvl_test, eunit, scale_timeouts])}
            | case anvl_plugin:conf([anvl_test, eunit, verbose]) of
                true  -> [verbose];
                false -> []
              end
            ],
  %% Timeout is infinity, because EUnit manages the timeouts internally:
  #suite{ suite           = App
        , runner          = ?MODULE
        , runner_options  = Options
        , fixtures        = []
        , tags            = []
        , tcs             = TCs
        }.

-spec tc(module()) -> #tc{}.
tc(Module) ->
  %% Timeout is infinity, because EUnit manages the timeouts internally:
  #tc{ name     = Module
     , inst     = default
     , tags     = []
     , fixtures = [{familiar_code_path, #{}}]
     , timeout  = infinity
     }.

%% Scan the beam file of the module instead of the loaded module, since
%% the latter may be compiled without the tests:
-spec has_eunit_tests(anvl_erlc:app_info(), module()) -> boolean().
has_eunit_tests(Ctx, Module) ->
  Beam = anvl_erlc:beam_file(Ctx, Module),
  case beam_lib:chunks(Beam, [exports]) of
    {ok, {Module, [{exports, Exports}]}} ->
      lists:any(fun({F, 0}) ->
                    Name = atom_to_list(F),
                    lists:suffix("_test", Name) orelse lists:suffix("_test_", Name);
                   (_) ->
                    false
                 end,
                 Exports);
    {error, beam_lib, _Reason} ->
      false
  end.

%% Return true for modules like `foo_tests', which EUnit runs as part of
%% `foo' when it's present in the same application:
-spec is_chained(module(), [module()]) -> boolean().
is_chained(Module, Modules) ->
  Name = atom_to_list(Module),
  case lists:suffix("_tests", Name) of
    true ->
      Base = list_to_atom(lists:sublist(Name, length(Name) - length("_tests"))),
      lists:member(Base, Modules);
    false ->
      false
  end.
