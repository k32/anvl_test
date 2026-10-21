-module(anvl_test_sup).

-behavior(supervisor).

%% API:
-export([start_link/0]).

%% behavior callbacks:
-export([init/1]).

%% internal exports:
-export([]).

-export_type([]).

%%================================================================================
%% API functions
%%================================================================================

-define(SUP, ?MODULE).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
  supervisor:start_link({local, ?SUP}, ?MODULE, top).

%%================================================================================
%% Internal exports
%%================================================================================

%%================================================================================
%% behavior callbacks
%%================================================================================

init(top) ->
  Children = [ anvl_test_subnet_child_spec() ],
  SupFlags = #{ strategy      => one_for_one
              , intensity     => 10
              , period        => 10
              , auto_shutdown => never
              },
  {ok, {SupFlags, Children}}.

-spec anvl_test_subnet_child_spec() -> supervisor:child_spec().
anvl_test_subnet_child_spec() ->
  #{ id       => anvl_test_subnet
   , start    => {anvl_test_subnet, start_link, []}
   , shutdown => 5_000
   , restart  => permanent
   , type     => worker
   }.

-spec worker_spec() -> supervisor:child_spec().
worker_spec() ->
  #{ id          => worker
   , start       => {worker, start_link, []}
   , shutdown    => 5_000
   , restart     => permanent
   , type        => worker
   , significant => false
   }.

%%================================================================================
%% Internal functions
%%================================================================================
