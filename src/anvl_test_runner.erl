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

-module(anvl_test_runner).
-moduledoc """
Behaviour for modules that execute test cases.
""".

-include("anvl_test_internal.hrl").

%%--------------------------------------------------------------------------
%% Callbacks
%%--------------------------------------------------------------------------

-doc """
Execute a single test case.

@code{Module} is the test suite module,
@code{Test} is the name of the test function,
and @code{Env} is the environment passed to the test case.
@code{Timeout} is the maximum execution time of the test case.
The callback is invoked on the test site,
so the test case runs in the isolated node.
""".
-callback run_test(
            _RunnerOptions,
            anvl_test:suite(),
            Test :: atom(),
            Env :: map(),
            Timeout :: timeout()
           ) -> ok | #tc_error{}.

-doc """
Discover test suites of an OTP application.

The callback returns @code{@{ok, Suites@}} when all discovered test suites were successfully loaded and are valid.
It returns @code{@{error, Suites@}} when some of the discovered suites could not be loaded and are therefore missing from @code{Suites}.
In the latter case the returned suites can still be run,
but the whole run must fail in the end,
because the test selection is incomplete.
""".
-callback discover(anvl_erlc:profile(), anvl_erlc:application()) ->
        {ok, [#suite{}]} | {error, [#suite{}]}.
