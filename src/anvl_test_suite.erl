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

A test suite is an Erlang module implementing the @erlmodref{link,anvl_test_suite} behavior.
Each test case of the suite is a function of arity 2,
with the first argument selecting the @i{method} to execute:

@itemize

@item
@code{@{Test@}(run, Env)}: execute the test case.
@code{Env} is a map with at least the @code{instance} key,
and the @code{familiar} key with the network settings of the test case:
@code{net} is the number of the @code{/24} subnet of the loopback range
dedicated to the test case,
and @code{subnet} is its prefix length.
The execution is aborted if it takes longer than the timeout of the test case.
This is the only mandatory method:
all other methods are optional and have sane defaults.

@item
@code{@{Test@}(instances, Env)}: return the list of instances of the test case.
The test case function is executed once for each instance,
with the instance value passed in @code{Env}.
Default: @code{[default]}.

@item
@code{@{Test@}(tags, Env)}: return the list of tags of the test case instance.
Tags can be used for selecting a subset of the test cases for execution.
Default: @code{[]}.

@item
@code{@{Test@}(fixtures, Env)}: return the list of fixtures of the test case instance.
Fixtures are passed to the @code{familiar} library and control the environment of the isolated node where the test case runs.
Default: global fixtures of the suite.

@item
@code{@{Test@}(timeout, Env)}: return the execution timeout of the test case instance, in milliseconds.
Default: the global timeout of the suite.

@end itemize

Suite-global values for tags, fixtures, instances and timeout can be provided by implementing the corresponding callbacks of the behavior,
e.g. @erlcb{ref,erlref,anvl_test_suite,tags,0} or @erlcb{ref,erlref,anvl_test_suite,timeout,0}.
""".

-define(DEFAULT_TC_TIMEOUT, 30000).

-behavior(anvl_test_runner).

-export([run_test/5, tc_location/2, discover/2]).
-export([invoke_method/4]).

%% For testing:
-export([load/4]).

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

-doc """
Return the default timeout for the test cases of the suite, in milliseconds.

This value is used for the test cases that don't override the timeout individually.
""".
-callback timeout() -> timeout().

-optional_callbacks([tags/0, fixtures/0, instances/0, timeout/0]).

%%--------------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------------

-doc false.
-spec run_test(_, module(), atom(), map(), timeout()) -> term().
run_test(_Options, Module, Test, Env, _Timeout) ->
  Module:Test(run, Env).

-doc false.
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

-doc """
Discover the test suites of the OTP application:
the modules implementing the @erlmodref{link,anvl_test_suite} behavior.
""".
-spec discover(anvl_erlc:profile(), anvl_erlc:application()) ->
        {ok, [#suite{}]} | {error, [#suite{}]}.
discover(Profile, App) ->
  _ = precondition(anvl_erlc:app_compiled(Profile, App)),
  Ctx = anvl_erlc:app_info(Profile, App),
  Modules = [Module
             || Module <- anvl_erlc:app_modules(Profile, App),
                is_suite(Ctx, Module)],
  load_suites(Profile, App, Modules, [], false).

-spec load_suites(
        anvl_erlc:profile(),
        anvl_erlc:application(),
        [module()],
        [#suite{}],
        boolean()
       ) -> {ok, [#suite{}]} | {error, [#suite{}]}.
load_suites(_Profile, _App, [], Acc, false) ->
  {ok, Acc};
load_suites(_Profile, _App, [], Acc, true) ->
  {error, Acc};
load_suites(Profile, App, [Module | Rest], Acc, Failed) ->
  %% FIXME:
  Project = anvl_project:root(),
  case load(Project, Profile, App, Module) of
    {ok, Suite} ->
      load_suites(Profile, App, Rest, [Suite | Acc], Failed);
    Error ->
      ?LOG_ERROR("Failed to load suite ~p: ~p", [Module, Error]),
      load_suites(Profile, App, Rest, Acc, true)
  end.

tcs(_Module, _GlobalFixtures, _GlobalInstances, _GlobalTimeout, [], Acc) ->
  {ok, Acc};
tcs(Module, GlobalFixtures, GlobalInstances, GlobalTimeout, [Test | Rest], Acc) ->
  maybe
    {ok, Instances} ?= get_instances(Module, Test, GlobalInstances),
    {ok, TCs} ?= tcs1(Module, GlobalFixtures, GlobalTimeout, Test, Instances, []),
    tcs(Module, GlobalFixtures, GlobalInstances, GlobalTimeout, Rest, TCs ++ Acc)
  end.

tcs1(_Module, _GlobalFixtures, _GlobalTimeout, _Test, [], Acc) ->
  {ok, Acc};
tcs1(Module, GlobalFixtures, GlobalTimeout, Test, [Inst | Rest], Acc) ->
  maybe
    {ok, Tags} ?= get_tags(Module, Test, Inst),
    {ok, Fixtures} ?= get_fixtures(Module, Test, Inst, GlobalFixtures),
    {ok, Timeout} ?= get_timeout(Module, Test, Inst, GlobalTimeout),
    TC = #tc{ name = Test
            , inst = Inst
            , tags = Tags
            , fixtures = Fixtures
            , timeout = Timeout
            },
    tcs1(Module, GlobalFixtures, GlobalTimeout, Test, Rest, [TC | Acc])
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

get_timeout(Module, Test, Instance, GlobalTimeout) ->
  maybe
    {ok, Timeout} ?= ?MODULE:invoke_method(Module, Test, timeout, #{instance => Instance}),
    ok ?= validate_timeout(Timeout),
    {ok, Timeout}
  else
    undefined ->
      {ok, GlobalTimeout};
    {error, Err} ->
      {error, [Module, Test, Instance], Err}
  end.

default_fixtures(Project, Profile, App) ->
  [anvl_test:code_path_fixture(Project, Profile, App)].

%%--------------------------------------------------------------------------
%% Internal exports
%%--------------------------------------------------------------------------

-doc false.
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

-doc false.
load(Project, Profile, App, Module) ->
  Ctx = anvl_erlc:app_info(Profile, App),
  maybe
    ok ?= ensure_loaded(Ctx, Module),
    {_, Tests} ?= proplists:lookup(anvl_test_tests, Module:module_info(attributes)),
    {ok, Tags} ?= opt_call(Module, tags, [], []),
    ok ?= validate_tags(Tags),
    {ok, GlobalFixtures} ?= maybe_add_code_path(
                              Project,
                              Profile,
                              App,
                              opt_call(Module, fixtures, [], default_fixtures(Project, Profile, App))),
    ok ?= validate_fixtures(GlobalFixtures),
    {ok, GlobalInstances} ?= opt_call(Module, instances, [], [default]),
    ok ?= validate_instances(GlobalInstances),
    {ok, GlobalTimeout} ?= opt_call(Module, timeout, [], ?DEFAULT_TC_TIMEOUT),
    ok ?= validate_timeout(GlobalTimeout),
    {ok, TCs} ?= tcs(Module, GlobalFixtures, GlobalInstances, GlobalTimeout, Tests, []),
    {ok, #suite{ suite = Module
               , runner = anvl_test_suite
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

%% Make sure the module is loaded from the beam file of the profile, since
%% the loaded module may come from a different profile:
-spec ensure_loaded(anvl_erlc:app_info(), module()) -> ok | {error, _}.
ensure_loaded(Ctx, Module) ->
  Beam = anvl_erlc:beam_file(Ctx, Module),
  case code:is_loaded(Module) of
    {file, Beam} ->
      ok;
    _ ->
      load_beam(Beam, Module)
  end.

-spec load_beam(file:filename(), module()) -> ok | {error, _}.
load_beam(Beam, Module) ->
  %% Note: load_abs expects the filename without the extension:
  case code:load_abs(filename:rootname(Beam)) of
    {module, Module} ->
      ok;
    {error, not_purged} ->
      %% The error can be ignored when the current version of the module is
      %% loaded from the right beam file, e.g. by another discoverer running
      %% in parallel:
      case code:is_loaded(Module) of
        {file, Beam} -> ok;
        _            -> {error, not_purged}
      end;
    {error, Reason} ->
      {error, Reason}
  end.

%% Select modules implementing the suite behavior, by scanning the
%% attributes chunk of the beam files of the profile:
-spec is_suite(anvl_erlc:app_info(), module()) -> boolean().
is_suite(Ctx, Module) ->
  Beam = anvl_erlc:beam_file(Ctx, Module),
  case beam_lib:chunks(Beam, [attributes]) of
    {ok, {Module, [{attributes, Attributes}]}} ->
      lists:any(fun({behavior,  [?MODULE]}) -> true;
                   ({behaviour, [?MODULE]}) -> true;
                   (_)                        -> false
                end,
                Attributes);
    {error, beam_lib, _Reason} ->
      false
  end.

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

validate_timeout(T) when is_integer(T), T >= 0; T =:= infinity ->
  ok;
validate_timeout(T) ->
  {error, {bad_timeout, T}}.

maybe_add_code_path(Project, Profile, App, {ok, Fixtures}) ->
  case lists:keyfind(familiar_code_path, 1, Fixtures) of
    false ->
      {ok, [anvl_test:code_path_fixture(Project, Profile, App) | Fixtures]};
    _ ->
      {ok, Fixtures}
  end;
maybe_add_code_path(_, _, _, Other) ->
  Other.
