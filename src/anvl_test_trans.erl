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

-module(anvl_test_trans).

-export([parse_transform/2]).

-ifdef(debug).
-define(log(A, B), io:format(user, A "~n", B)).
-else.
-define(log(A, B), ok).
-endif.

-define(test_nparam, 2).

parse_transform(Forms0, _Options) ->
  ?log("Dump of the module AST:~n~p~n", [Forms0]),
  {TestsWithLoc, Exports, Forms1} = scan_forms(Forms0),
  RequiredExports = [{I, ?test_nparam} || {_Loc, I} <- TestsWithLoc],
  Forms2 = add_missing_exports(RequiredExports, Exports, Forms1),
  ?log("With exports:~n~p~n", [Forms2]),
  Tests = [I || {_Loc, I} <- TestsWithLoc],
  add_tests_attr(Forms2, Tests).

scan_forms(Forms) ->
  scan_forms(Forms, [], [], []).

scan_forms([], Tests, Exports, Forms) ->
  {lists:reverse(Tests), Exports, lists:reverse(Forms)};
scan_forms([{attribute, _, export, Exp} = F | Rest], Tests, Exports, Forms) ->
  %% Collect exported functions to avoid re-exporting stuff.
  %% Exp = [{foo, 2}, ...]
  scan_forms(Rest, Tests, Exp ++ Exports, [F | Forms]);
scan_forms([{attribute, Loc, test, Name} | Rest], Tests, Exports, Forms) ->
  scan_forms(Rest, [{Loc, Name} | Tests], Exports, Forms);
scan_forms([F | Rest], Tests, Exports, Forms) ->
  scan_forms(Rest, Tests, Exports, [F | Forms]).

add_tests_attr([{attribute, Loc, module, _} = Mod | Rest], Tests) ->
  [Mod, {attribute, Loc, anvl_test_tests, Tests} | Rest];
add_tests_attr([Other | Rest], Tests) ->
  [Other | add_tests_attr(Rest, Tests)].

add_missing_exports(Required, Exports, Forms) ->
  Missing = Required -- Exports,
  case Missing of
    [] ->
      Forms;
    _ ->
      add_exports(Forms, Missing)
  end.

add_exports([{attribute, Loc, module, _} = Mod | Rest], Missing) ->
  %% Add missing exports immediately after the module attribute:
  Exports = {attribute, Loc, export, Missing},
  [Mod, Exports | Rest];
add_exports([Other | Rest], Missing) ->
  [Other | add_exports(Rest, Missing)].
