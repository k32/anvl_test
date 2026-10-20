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

%%--------------------------------------------------------------------------
%% Callbacks
%%--------------------------------------------------------------------------

-doc """
Execute a single test case.

`Module` is the test suite module, `Test` is the name of the test function,
and `Env` is the environment passed to the test case. The callback is
invoked on the test site, so the test case runs in the isolated node.
""".
-callback run_test(Module :: module(), Test :: atom(), Env :: map()) -> term().
