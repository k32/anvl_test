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

-module(anvl_test_subnet).
-moduledoc """
Allocator of the subnet numbers used by the test case clusters.

Each test case runs on a cluster of nodes that occupy a dedicated @code{/24} subnet of the @code{127.0.0.0/8} loopback range.
This server hands out the numbers of the free subnets.
""".

-behavior(gen_server).

%% API:
-export([start_link/0, take/0, release/1]).

%% behavior callbacks:
-export([init/1, handle_call/3, handle_cast/2]).

%%================================================================================
%% Type declarations
%%================================================================================

-doc """
Number of the last octet of the subnet address.
""".
-type subnet() :: 1..255.

-export_type([subnet/0]).

%%================================================================================
%% API functions
%%================================================================================

-doc false.
-spec start_link() -> gen_server:start_ret().
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc """
Take the number of a free subnet.

Raise an exception when there are no free subnets left.
The server keeps running in this case.
""".
-spec take() -> subnet().
take() ->
  ok = ensure_started(),
  case gen_server:call(?MODULE, take) of
    {ok, Subnet}   -> Subnet;
    {error, empty} -> error(no_free_subnets)
  end.

-doc """
Return the subnet number to the pool of free subnets.
""".
-spec release(subnet()) -> ok.
release(Subnet) ->
  ok = ensure_started(),
  gen_server:cast(?MODULE, {release, Subnet}).

%% Start the server outside of the supervision tree, if it's not running
%% already. It's linked to nobody, so it outlives the condition processes:
-doc false.
-spec ensure_started() -> ok.
ensure_started() ->
  case whereis(?MODULE) of
    undefined ->
      case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
        {ok, _Pid}                       -> ok;
        {error, {already_started, _Pid}} -> ok
      end;
    _Pid ->
      ok
  end.

%%================================================================================
%% behavior callbacks
%%================================================================================

-doc false.
init([]) ->
  {ok, lists:seq(1, 255)}.

-doc false.
handle_call(take, _From, [Subnet | Rest]) ->
  {reply, {ok, Subnet}, Rest};
handle_call(take, _From, []) ->
  {reply, {error, empty}, []}.

-doc false.
handle_cast({release, Subnet}, Subnets) ->
  {noreply, Subnets ++ [Subnet]}.
