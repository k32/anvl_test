%%--------------------------------------------------------------------
%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(anvl_test_logger).

-export([install_cluster_log_handler/0]).
-export([cluster_log_filter/2]).
-export([logger_fixture/1]).

%% API:
-export([]).

%% internal exports:
-export([]).

-export_type([]).

%%================================================================================
%% Type declarations
%%================================================================================

%% Filter and handler redirecting the log events tagged with the
%% cluster and site IDs (see familiar_logger) away from the console:
-define(CLUSTER_LOG_FILTER, anvl_test_cluster_log_filter).
-define(CLUSTER_LOG_HANDLER, anvl_test_cluster_log_handler).
-define(CLUSTER_LOG_FILE, "cluster.log").

%%================================================================================
%% API functions
%%================================================================================

logger_fixture(TestId) ->
  LogLevel = anvl_plugin:conf([anvl_test, log_level]),
  {familiar_logger, #{ primary_config => #{level => LogLevel}
                     , tags => #{anvl_test_id => TestId}
                     }}.

%%================================================================================
%% Internal exports
%%================================================================================

-doc false.
-spec install_cluster_log_handler() -> ok.
install_cluster_log_handler() ->
  case anvl_plugin:conf([anvl_test, show_log]) of
    false ->
      %% Hide the log events of the test clusters from the console:
      _ = logger:remove_handler_filter(default, ?CLUSTER_LOG_FILTER),
      ok = logger:add_handler_filter(default, ?CLUSTER_LOG_FILTER, cluster_log_filter(false));
    true ->
      ok
  end,
  %% Redirect the log events of the test clusters into a dedicated file:
  LogFile = filename:join(anvl_fn:workdir([?MODULE]), ?CLUSTER_LOG_FILE),
  ok = filelib:ensure_dir(LogFile),
  _ = logger:remove_handler(?CLUSTER_LOG_HANDLER),
  ok = logger:add_handler(?CLUSTER_LOG_HANDLER, logger_std_h,
                          #{ config => #{type => {file, unicode:characters_to_list(LogFile)}}
                           , filters => [{?CLUSTER_LOG_FILTER, cluster_log_filter(true)}]
                           }),
  ok.

-doc """
Return a logger filter
that passes the log events tagged with the cluster and site IDs
and stops the rest,
or the other way around.

The filter is used to hide the log events of the test clusters
from the default console handler,
and, with the opposite flag,
to redirect them into the dedicated cluster log file.
""".
-spec cluster_log_filter(KeepTagged :: boolean()) ->
        {fun((logger:log_event(), boolean()) -> logger:log_event() | stop), boolean()}.
cluster_log_filter(KeepTagged) ->
  {fun ?MODULE:cluster_log_filter/2, KeepTagged}.

-doc false.
-spec cluster_log_filter(logger:log_event(), boolean()) -> logger:log_event() | stop.
cluster_log_filter(Event = #{meta := Meta}, KeepTagged) ->
  Tagged = maps:is_key(anvl_test_id, Meta),
  case Tagged =:= KeepTagged of
    true  -> Event;
    false -> stop
  end.

%%================================================================================
%% Internal functions
%%================================================================================
