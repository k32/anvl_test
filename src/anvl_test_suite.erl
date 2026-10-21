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

-module(anvl_test_suite).
-moduledoc """
This module contains functions for interfacing with the test suites.
""".

-behavior(anvl_test_runner).

-export([load/1, run_test/3, tc_location/2, discover/2]).
-export([invoke_method/4]).

-include("types.hrl").
-include("anvl.hrl").
-include("anvl_test_internal.hrl").

-export_type([test/0]).
-reflect_type([instances/0, fixture/0, tag/0]).

%%--------------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------------

-type tag() :: atom().

-type test() :: atom().

-type instance() :: term().

-type instances() :: [instance(), ...].

-type fixture() :: {module(), term()}.

%%--------------------------------------------------------------------------
%% Types
%%--------------------------------------------------------------------------

%%--------------------------------------------------------------------------
%% Callbacks
%%--------------------------------------------------------------------------

-callback tags() -> list().

-callback fixtures() -> [fixture()].

-callback instances() -> instances().

-optional_callbacks([tags/0, fixtures/0, instances/0]).

%%--------------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------------

-spec run_test(module(), atom(), map()) -> term().
run_test(Module, Test, Env) ->
  Module:Test(run, Env).

tc_location(Module, Test) ->
  %% TODO: add a more reliable way to do this via parse transform
  try
    Result = Module:Test('$magic_get_location', '$magic_get_location...'),
    {error, {unexpected_match, Result}}
  catch
    EC:Err:Stack ->
      case Stack of
        [{Module, Test, _Args, Props} | _] when EC =:= error, Err =:= function_clause ->
          case Props of
            [{file, F}, {line, L}] -> {ok, {F, L}};
            _                      -> {error, {bad_props, Props}}
          end;
        _ ->
          {error, {unexpected_error, EC, Err, Stack}}
      end
  end.

load(Module) ->
  maybe
    {_, Tests} ?= proplists:lookup(anvl_test_tests, Module:module_info(attributes)),
    {ok, Tags} ?= opt_call(Module, tags, [], []),
    ok ?= validate_tags(Tags),
    {ok, GlobalFixtures} ?= opt_call(Module, fixtures, [], default_fixtures()),
    ok ?= validate_fixtures(GlobalFixtures),
    {ok, GlobalInstances} ?= opt_call(Module, instances, [], [default]),
    ok ?= validate_instances(GlobalInstances),
    {ok, TCs} ?= tcs(Module, GlobalFixtures, GlobalInstances, Tests, []),
    {ok, #suite{ suite = Module
               , runner = anvl_test_suite
               , tests = Tests
               , tags = Tags
               , tcs = TCs
               }}
  else
    none ->
      {error, [Module], not_a_suite};
    {error, Err} ->
      {error, [Module], Err};
    {error, _, _} = Err ->
      Err
  end.

-spec discover(anvl_erlc:profile(), anvl_erlc:application()) -> {ok, [#suite{}]} | {error, [#suite{}]}.
discover(Profile, App) ->
  _ = precondition(anvl_erlc:app_compiled(Profile, App)),
  Modules = [Module
             || Module <- anvl_erlc:app_modules(Profile, App),
                {Key, [?MODULE]} <- Module:module_info(attributes),
                Key =:= behaviour orelse Key =:= behavior],
  load_suites(Modules, [], false).

-spec load_suites([module()], [#suite{}], boolean()) -> {ok, [#suite{}]} | {error, [#suite{}]}.
load_suites([], Acc, false) ->
  {ok, Acc};
load_suites([], Acc, true) ->
  {error, Acc};
load_suites([Module | Rest], Acc, Failed) ->
  case load(Module) of
    {ok, Suite} ->
      load_suites(Rest, [Suite | Acc], Failed);
    Error ->
      ?LOG_ERROR("Failed to load suite ~p: ~p", [Module, Error]),
      load_suites(Rest, Acc, true)
  end.

tcs(_Module, _GlobalFixtures, _GlobalInstances, [], Acc) ->
  {ok, Acc};
tcs(Module, GlobalFixtures, GlobalInstances, [Test | Rest], Acc) ->
  maybe
    {ok, Instances} ?= get_instances(Module, Test, GlobalInstances),
    {ok, TCs} ?= tcs1(Module, GlobalFixtures, Test, Instances, []),
    tcs(Module, GlobalFixtures, GlobalInstances, Rest, TCs ++ Acc)
  end.

tcs1(_Module, _GlobalFixtures, _Test, [], Acc) ->
  {ok, Acc};
tcs1(Module, GlobalFixtures, Test, [Inst | Rest], Acc) ->
  maybe
    {ok, Tags} ?= get_tags(Module, Test, Inst),
    {ok, Fixtures} ?= get_fixtures(Module, Test, Inst, GlobalFixtures),
    TC = #tc{ name = Test
            , inst = Inst
            , tags = Tags
            , fixtures = Fixtures
            },
    tcs1(Module, GlobalFixtures, Test, Rest, [TC | Acc])
  end.

get_tags(Module, Test, Instance) ->
  case ?MODULE:invoke_method(Module, Test, tags, #{instance => Instance}) of
    {ok, L} when is_list(L) ->
      {ok, L};
    {ok, Bad} ->
      {error, {bad_tags, {Module, Test, Bad}}};
    undefined ->
      {ok, []};
    Err ->
      Err
  end.

get_fixtures(Module, Test, Instance, GlobalFixtures) ->
  maybe
    {ok, Fixtures} ?= ?MODULE:invoke_method(Module, Test, fixtures, #{instance => Instance}),
    ok ?= validate_fixtures(Fixtures),
    {ok, Fixtures}
  else
    undefined ->
      {ok, GlobalFixtures};
    {error, Err} ->
      {error, [Module, Test, Instance], Err}
  end.

default_fixtures() ->
  [ {familiar_code_path, #{}}
  ].

%%--------------------------------------------------------------------------
%% Internal exports
%%--------------------------------------------------------------------------

invoke_method(Module, Test, Method, Arg) ->
  try
    {ok, Module:Test(Method, Arg)}
  catch
    EC:Err:Stack ->
      case Stack of
        [_, {?MODULE, ?FUNCTION_NAME, 4, _} | _] when Err =:= function_clause,
                                                      EC =:= error ->
          undefined;
        _ ->
          User = lists:takewhile(fun({?MODULE, ?FUNCTION_NAME, 4, _}) -> false;
                                    (_) -> true
                                 end,
                                 Stack),
          {error, {EC, Err, User}}
      end
  end.

%%--------------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------------

-spec get_instances(module(), test(), instances()) -> {ok, instances()} | {error, _}.
get_instances(Module, Test, GlobalInstances) ->
  maybe
    {ok, Inst} ?= ?MODULE:invoke_method(Module, Test, instances, #{}),
    ok ?= validate_instances(Inst),
    {ok, Inst}
  else
    undefined -> {ok, GlobalInstances};
    Err -> Err
  end.

-spec opt_call(module(), atom(), list(), Ret) -> {ok, Ret} | {error, {{module(), atom(), list()}, _}}.
opt_call(Module, Fun, Args, Default) ->
  case erlang:function_exported(Module, Fun, length(Args)) of
    true ->
      try
        {ok, apply(Module, Fun, Args)}
      catch
        EC:Err:Stack ->
          {error, [Module, Fun], {EC, Err, Stack}}
      end;
    false ->
      {ok, Default}
  end.

validate_instances(L) ->
  case typerefl:typecheck(instances(), L) of
    ok ->
      ok;
    {error, Err} ->
      {error, {bad_instances, Err}}
  end.

validate_tags(L) ->
  case typerefl:typecheck(list(tag()), L) of
    ok ->
      ok;
    {error, Err} ->
      {error, {bad_tags, Err}}
  end.

validate_fixtures(L) ->
  case typerefl:typecheck(list(fixture()), L) of
    ok ->
      ok;
    {error, Err} ->
      {error, {bad_fixtures, Err}}
  end.
